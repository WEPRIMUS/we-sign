# frozen_string_literal: true

module Desk
  # The client register: list, card, add by hand, confirm a client the desk created, archive (never delete).
  class ClientsController < BaseController
    before_action :load_client, only: %i[show edit update confirm archive]

    def index
      scope = clients_scope.order(:legal_name)
      scope = params[:status] == 'archived' ? scope.where.not(archived_at: nil) : scope.active
      scope = scope.where(status: 'new_please_confirm') if params[:status] == 'new_please_confirm'

      @clients = scope
      @document_counts = documents_scope.active.where(client_id: @clients.map(&:id)).group(:client_id).count
    end

    def show
      @documents = documents_scope.where(client_id: @client.id).order(updated_at: :desc)
      @events = Desk::Event.where(account_id: current_account.id, client_id: @client.id, document_id: nil)
                           .order(created_at: :desc)
    end

    def new
      @client = Desk::Client.new(signers: [{}])
    end

    def edit; end

    def create
      @client = Desk::Client.new(client_params.merge(account_id: current_account.id, status: 'confirmed',
                                                     source: 'Added by hand', created_by_user_id: current_user.id,
                                                     confirmed_by_user_id: current_user.id,
                                                     confirmed_at: Time.current))

      if @client.save
        Desk::Event.log!(account_id: current_account.id, client: @client, action: 'client added by hand',
                         actor: 'person', user: current_user)
        redirect_to desk_client_path(@client), notice: 'Client added.'
      else
        render :new, status: :unprocessable_content
      end
    rescue ActiveRecord::RecordNotUnique
      @client.errors.add(:base, 'This client is already in the register.')
      render :new, status: :unprocessable_content
    end

    def update
      if @client.update(client_params)
        Desk::Event.log!(account_id: current_account.id, client: @client, action: 'client changed', actor: 'person',
                         user: current_user, data: { changed: @client.previous_changes.keys - %w[updated_at] })
        redirect_to desk_client_path(@client), notice: 'Saved.'
      else
        render :edit, status: :unprocessable_content
      end
    end

    def confirm
      if @client.new_please_confirm?
        @client.update!(status: 'confirmed', confirmed_by_user_id: current_user.id, confirmed_at: Time.current)
        Desk::Event.log!(account_id: current_account.id, client: @client, action: 'client confirmed', actor: 'person',
                         user: current_user)

        questions_scope.open.where(kind: 'confirm_client').select { |q| q.context['client_id'] == @client.id }
                       .each { |q| Desk::Questions.answer!(q, 'Yes', current_user) }
      end

      redirect_to desk_client_path(@client), notice: 'Confirmed.'
    end

    def archive
      @client.update!(archived_at: Time.current)
      Desk::Event.log!(account_id: current_account.id, client: @client, action: 'client archived', actor: 'person',
                       user: current_user)

      redirect_to desk_clients_path, notice: 'Archived. Nothing was deleted.'
    end

    private

    def load_client
      @client = clients_scope.find(params[:id])
    end

    def client_params
      permitted = params.require(:client).permit(:legal_name, :trading_name, :country, :address, :tax_number,
                                                 :default_currency, :payment_terms,
                                                 signers: %i[name role email])
      permitted[:signers] = permitted[:signers].to_h.values if permitted[:signers].is_a?(ActionController::Parameters)
      permitted[:country] = permitted[:country].to_s.upcase.presence if permitted.key?(:country)

      permitted
    end
  end
end

# frozen_string_literal: true

module Desk
  class DocumentsController < BaseController
    FILTER_STATES = {
      'waiting_for_you' => %w[waiting_for_you], 'preparing' => %w[preparing], 'ready_to_send' => %w[ready_to_send],
      'out' => %w[sent opened], 'signed' => %w[signed], 'declined' => %w[declined], 'expired' => %w[expired],
      'archived' => %w[archived]
    }.freeze

    before_action :load_document, except: :index

    def index
      scope = documents_scope.includes(:client).order(updated_at: :desc)
      scope = params[:state].present? ? scope.where(state: FILTER_STATES.fetch(params[:state], [])) : scope.active
      scope = scope.where(client_id: params[:client_id]) if params[:client_id].present?
      scope = scope.where(doc_type: params[:doc_type]) if params[:doc_type].present?

      if params[:q].present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].downcase)}%"
        scope = scope.where('LOWER(title) LIKE :term OR LOWER(number) LIKE :term OR LOWER(filename) LIKE :term', term:)
      end

      @pagy, @documents = pagy(scope, limit: 25)
      @clients = clients_scope.active.order(:legal_name)
      @doc_types = documents_scope.where.not(doc_type: nil).distinct.pluck(:doc_type).sort
    end

    def show
      @events = @document.events.order(created_at: :desc, id: :desc).includes(:user)
      @facts = @document.facts.current.order(:id)
      @open_questions = @document.questions.open.order(:position)
    end

    def review
      return redirect_to(desk_document_path(@document)) unless @document.state == 'ready_to_send'

      @facts = @document.facts.current.order(:id)
      @template = @document.template
      @submission = @document.submission
      @notes = @document.events.where(action: 'boxes placed').order(:id).last&.data&.dig('notes').to_a +
               @document.facts.current.where(key: 'wording_note').map { |f| f.value['note'] } +
               Desk::OwnCheck.notes(@document)
      @own_slot = Desk::Signers.plan(@document, desk_settings).find(&:own)
      @own = @submission.submitters.find { |s| s.uuid == @own_slot&.uuid }
      @signs_now = desk_settings.sender_signs_on_approval && @own_slot&.signed_by?(current_user)
      @blockers = send_blockers
    end

    # "Yes, send": the one path that sends. Desk::Approval checks the person; Desk::Sender does the rest.
    def approve
      approval = Desk::Approval.from_request!(request:, user: current_user, true_user:)
      Desk::Sender.call(@document, approval, title: params[:signer_title])

      redirect_to desk_document_path(@document), notice: 'Sent. The desk follows it up and tells you when it is signed.'
    rescue Desk::Approval::NotAllowed, Submitters::SubmitValues::ValidationError,
           Desk::SigningBuild::DocumentChanged => e
      @document.log!('send refused', actor: 'person', user: current_user, data: { reason: e.message })
      redirect_to review_desk_document_path(@document), alert: e.message
    end

    # "No": the document is not sent. It is archived with its unsent WE Sign document, never deleted.
    def decline
      archive_document!('not sent: the person said No')

      redirect_to desk_root_path, notice: 'Not sent. The document is archived; nothing was deleted.'
    end

    def archive
      if @document.out_for_signature?
        return redirect_to(desk_document_path(@document),
                           alert: 'This document is out for signature: it can be archived once it is signed, ' \
                                  'declined or expired.')
      end

      archive_document!('archived')

      redirect_to desk_document_path(@document), notice: 'Archived. Nothing was deleted.'
    end

    def retry
      return redirect_to(desk_document_path(@document)) unless @document.state == 'waiting_for_you' &&
                                                               @document.questions.open.none?

      if Desk::Signers.parties(@document).none?
        @document.facts.current.where(origin: 'ai').update_all(status: 'superseded', updated_at: Time.current)
      end

      @document.update!(last_error: nil, last_error_at: nil)
      @document.transition!('preparing', actor: 'person', user: current_user, data: { retry: true })
      Desk::ProcessDocumentJob.perform_async('document_id' => @document.id)

      redirect_to desk_document_path(@document), notice: 'Trying again.'
    end

    def download
      attachment = { 'source' => @document.source_file, 'signed' => @document.signed_pdf,
                     'audit' => @document.audit_log }.fetch(params[:kind])

      return redirect_to(desk_document_path(@document), alert: 'Not available yet.') unless attachment.attached?

      suffix = { 'source' => '', 'signed' => ' - signed', 'audit' => ' - audit record' }.fetch(params[:kind])
      @document.log!("downloaded: #{params[:kind]}", actor: 'person', user: current_user)

      send_data attachment.download, filename: "#{@document.name}#{suffix}.pdf", type: 'application/pdf',
                                     disposition: 'attachment'
    end

    private

    def load_document
      @document = documents_scope.find_by!(uuid: params[:id])
    end

    def archive_document!(reason)
      return if @document.state == 'archived'

      unsent = @document.submission && !@document.out_for_signature?
      @document.submission.update!(archived_at: Time.current) if unsent &&
                                                                 !@document.submission.archived_at?
      @document.transition!('archived', actor: 'person', user: current_user, archived_at: Time.current,
                                        data: { reason:, state_before: @document.state })
    end

    def send_blockers
      blockers = []
      unless current_user.otp_required_for_login?
        blockers << 'Turn on two-factor sign-in in your Profile: sending needs it.'
      end
      unless desk_settings.may_send?(current_user)
        blockers << 'A manager approves before sending, and you are not on the list of approvers.'
      end

      if @signs_now && !UserConfigs.load_signature(current_user)
        blockers << 'Save your signature in your Profile: it is applied for your company when you approve.'
      end

      blockers
    end
  end
end

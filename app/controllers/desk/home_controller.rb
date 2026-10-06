# frozen_string_literal: true

module Desk
  class HomeController < BaseController
    def index
      @questions = questions_scope.open.joins(:document).merge(documents_scope.where(state: 'waiting_for_you'))
                                  .group(:document_id).count
      @waiting = documents_scope.where(state: 'waiting_for_you').includes(:client).order(updated_at: :desc)
      @ready = documents_scope.where(state: 'ready_to_send').includes(:client).order(updated_at: :desc)
      @preparing = documents_scope.where(state: 'preparing').order(created_at: :desc)
      @new_clients = clients_scope.active.where(status: 'new_please_confirm').order(created_at: :desc)
      @counts = { clients: clients_scope.active.count, documents: documents_scope.active.count }
    end
  end
end

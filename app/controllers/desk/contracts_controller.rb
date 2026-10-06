# frozen_string_literal: true

module Desk
  # "New contract": the document is written from the answers to the question box (one type for now: a quotation
  # and variation to an existing agreement, Desk::Variation).
  class ContractsController < BaseController
    def new; end

    def create
      document = Desk::Variation.start!(account: current_account, user: current_user)

      redirect_to desk_question_path(document.questions.order(:position).first)
    end
  end
end

# frozen_string_literal: true

module Desk
  # The question box: one question at a time, each with a short example.
  class QuestionsController < BaseController
    # The boxes of the form questions (Desk::Variation::QUESTIONS); rows are the lines a person adds and removes.
    FORM_FIELDS = [:title, :reference, :date, :clauses, :share, :label, :times, :current, :last,
                   { rows: %i[name one_time currency monthly note what status acceptance percent when kind label
                              text] }].freeze

    def index
      question = next_open_question

      return redirect_to(desk_question_path(question)) if question

      redirect_to desk_root_path, notice: 'No questions are waiting for you.'
    end

    def show
      load_question(questions_scope.find(params[:id]))
    end

    def update
      question = questions_scope.open.find(params[:id])

      Desk::Questions.answer!(question, answer_param, current_user)

      following = next_open_question(question.document) # then back to this document's card, not another's questions

      if following
        redirect_to desk_question_path(following), notice: 'Thank you.'
      else
        redirect_to desk_document_path(question.document), notice: 'Thank you. The desk carries on with the document.'
      end
    rescue Desk::Questions::Invalid => e
      return redirect_to(desk_question_path(question), alert: e.message) unless question.kind == 'form'

      # The form again, as it was filled in, with the reason under the box it is about.
      @error = e
      @given = Desk::Variation.clean(answer_param)
      load_question(question)
      render :show, status: :unprocessable_content
    end

    private

    def answer_param
      answer = params[:answer]

      answer.is_a?(ActionController::Parameters) ? answer.permit(*FORM_FIELDS).to_h : answer
    end

    def load_question(question)
      @question = question
      @document = question.document
      @siblings = @document.questions.order(:position, :id).to_a
      @client = Desk::Client.find_by(id: @question.context['client_id'], account_id: current_account.id)
    end

    def next_open_question(document = nil)
      scope = questions_scope.open.joins(:document).merge(documents_scope.where(state: 'waiting_for_you'))
      scope = scope.where(document_id: document.id) if document

      scope.order('desk_documents.created_at', :position, :id).first
    end
  end
end

# frozen_string_literal: true

module Desk
  # Runs the desk's preparation of one document (Desk::Pipeline). Automated: it cannot send (Desk::Automation).
  # Not retried by Sidekiq: a failure is shown on the document for a person, who can retry it.
  class ProcessDocumentJob
    include Sidekiq::Job

    sidekiq_options retry: false

    def perform(params = {})
      document = Desk::Document.find_by(id: params['document_id'])

      Desk::Automation.run { Desk::Pipeline.call(document) } if document
    end
  end
end

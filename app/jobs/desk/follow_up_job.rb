# frozen_string_literal: true

module Desk
  # Follows one sent document every few minutes until it is signed, declined, expired or archived
  # (Desk::FollowUp). One chain per document: a run whose token is not the document's current one stops.
  # Automated: it can remind, never send (Desk::Automation).
  class FollowUpJob
    include Sidekiq::Job

    sidekiq_options retry: false

    def perform(params = {})
      document = Desk::Document.find_by(id: params['document_id'])

      return unless document && document.follow_up_token == params['token'] && document.out_for_signature?

      begin
        Desk::Automation.run { Desk::FollowUp.call(document) }
      rescue StandardError => e
        document.log!('follow-up failed, tried again later', actor: 'system', data: { error: e.message.truncate(300) })
      end

      return unless document.reload.out_for_signature?

      self.class.perform_in(Desk::FollowUp::INTERVAL, 'document_id' => document.id, 'token' => params['token'])
    end
  end
end

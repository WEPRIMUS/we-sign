# frozen_string_literal: true

module Desk
  # Once a night (Desk::ReconcileJob): every open document is brought back in step with WE Sign, and anything that
  # drifted is repaired. Idempotent: a second run the same night finds nothing to do and logs nothing.
  #   sent / opened:  state read again (Desk::FollowUp); a follow-up chain that stopped is started again
  #   preparing:      a preparation that stopped (no claim, nothing for a while) is queued again
  #   ready to send:  an unsent WE Sign document that disappeared is reported on the document
  #   signed:         a signed PDF or audit record not yet fetched is fetched; the signed pages are drawn
  module Reconcile
    STALE_PREPARING = 30.minutes

    module_function

    def call(now: Time.current)
      counts = Hash.new(0)

      Document.where(state: Document::OUT_FOR_SIGNATURE).find_each { |d| counts[:followed] += 1 if out!(d, now) }
      Document.where(state: 'preparing', processing_started_at: nil).where(updated_at: ...STALE_PREPARING.ago)
              .find_each { |d| counts[:requeued] += 1 if requeue!(d) }
      Document.where(state: 'ready_to_send').find_each { |d| counts[:ready_drift] += 1 if ready!(d) }
      Document.where(state: 'signed').find_each { |d| counts[:signed_repaired] += 1 if signed!(d) }

      counts
    end

    def out!(document, now)
      stale = document.checked_at.nil? || document.checked_at < (FollowUp::INTERVAL * 3).ago

      FollowUp.call(document, now:)

      return false unless stale && document.reload.out_for_signature?

      token = SecureRandom.hex(8)
      document.update!(follow_up_token: token)
      FollowUpJob.perform_in(FollowUp::INTERVAL, 'document_id' => document.id, 'token' => token)
      document.log!('follow-up started again by the nightly check', actor: 'system')

      true
    end

    def requeue!(document)
      ProcessDocumentJob.perform_async('document_id' => document.id)
      document.log!('preparation queued again by the nightly check', actor: 'system')

      true
    end

    def ready!(document)
      submission = document.submission
      return false if submission && submission.archived_at.nil? && document.template&.archived_at.nil?
      return false if document.last_error.present?

      document.update!(last_error: 'The unsent WE Sign document was archived or removed outside the desk: ' \
                                   'archive this document and prepare it again',
                       last_error_at: Time.current)
      document.log!('drift found by the nightly check', actor: 'system', data: { error: document.last_error })

      true
    end

    def signed!(document)
      repaired = false

      unless document.signed_pdf.attached? && document.audit_log.attached?
        FollowUp.fetch_signed!(document, document.submission)
        repaired = true
      end

      repaired = true if FollowUp.signed_pages!(document)
      document.log!('signed copy repaired by the nightly check', actor: 'system') if repaired

      repaired
    end
  end
end

# frozen_string_literal: true

module Desk
  # The back end of one document, run by Desk::ProcessDocumentJob: read and understand, match the client, ask what
  # is missing, then build the WE Sign document without sending it. Each step is skipped when already done, so the
  # job can run again after answers or a retry. A failure is shown on the document; nothing fake replaces it.
  module Pipeline
    STALE_CLAIM = 15.minutes

    module_function

    def call(document)
      return unless claim(document)

      run(document.reload)
    rescue AiClient::Error, SigningBuild::DocumentChanged, Templates::CreateAttachments::PdfEncrypted,
           Questions::Invalid => e
      document.reload.fail!(e.message, actor: e.is_a?(AiClient::Error) ? 'ai' : 'system')
    rescue StandardError => e
      Rails.logger.error(["Contract Desk #{document.uuid}: #{e.class}: #{e.message}",
                          *e.backtrace&.first(15)].join("\n"))
      document.reload.fail!("Preparing stopped on an unexpected error (#{e.class}: #{e.message.truncate(200)})")
    ensure
      Document.where(id: document.id).update_all(processing_started_at: nil)
    end

    # Duplicate-action guard: one run per document at a time.
    def claim(document)
      Document.where(id: document.id, state: 'preparing')
              .where('processing_started_at IS NULL OR processing_started_at < ?', STALE_CLAIM.ago)
              .update_all(processing_started_at: Time.current) == 1
    end

    def run(document)
      settings = Setting.for(document.account)

      if document.source == 'generated'
        Variation.render!(document, settings) unless document.source_file.attached?
      else
        Reader.call(document, settings:) unless document.facts.current.exists?(origin: 'ai')

        if Signers.parties(document).none?
          return document.fail!('The desk could not tell who the parties of this document are: check that it is ' \
                                'the right file, or prepare it in the editor')
        end

        ClientMatch.call(document) unless document.client
      end

      OwnCheck.call(document, settings)

      slots = signing_order(Signers.plan(document, settings))
      problems = Signers.own_problems(slots)
      return document.fail!(problems.join('. ')) if problems.any?

      Questions.build!(document, slots)

      return document.transition!('waiting_for_you', actor: 'system') if document.questions.open.exists?

      result = SigningBuild.call(document, slots)

      if result.problems.any?
        Questions.ask_to_fix!(document, result.problems)
        return document.transition!('waiting_for_you', actor: 'system')
      end

      document.transition!('ready_to_send', actor: 'system', data: { notes: result.notes })
    end

    # Our side signs first (at the moment of approval, or first by e-mail); everyone else in the document's order.
    def signing_order(slots)
      own, others = slots.partition(&:own)

      own + others
    end
  end
end

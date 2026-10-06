# frozen_string_literal: true

module Desk
  # Follow-up of a sent document, run by Desk::FollowUpJob: keeps the desk's state in step with WE Sign (read from
  # the database, no webhook needed), sends the reminders of the schedule, warns the sender before the signing links
  # expire, and on completion fetches the signed PDF and the audit record into the register and tells the sender.
  # It only follows up what a person has sent: it never sends a document.
  module FollowUp
    INTERVAL = 5.minutes

    module_function

    def call(document, now: Time.current)
      return unless document.out_for_signature?

      submission = document.submission.reload
      settings = Setting.for(document.account)

      if submission.completed_at?
        complete!(document, submission)
      elsif submission.submitters.any?(&:declined_at?)
        document.transition!('declined', actor: 'system',
                                         declined_at: submission.submitters.filter_map(&:declined_at).min)
      elsif submission.expired?
        document.transition!('expired', actor: 'system', expired_at: submission.expire_at)
      else
        mark_opened(document, submission)
        remind(document, submission, settings, now)
        warn_expiry(document, submission, settings, now)
      end

      document.update!(checked_at: now)
    end

    def mark_opened(document, submission)
      opened_at = submission.submitters.reject { |s| s.uuid == own_uuid(document) }.filter_map(&:opened_at).min

      document.transition!('opened', actor: 'system', opened_at:) if opened_at && document.state == 'sent'
    end

    def own_uuid(document)
      Signers.uuid(document, 'own-1')
    end

    # The reminder days that have come and not been sent. When several have come at once (the job was stopped),
    # only one reminder goes out and the others are marked done: people are not sent three e-mails in a row.
    def due_days(document, schedule, now)
      return [] unless document.sent_at

      days = ((now - document.sent_at) / 1.day).floor

      schedule.select { |day| days >= day } - document.reminders_sent.map(&:to_i)
    end

    def remind(document, submission, settings, now)
      due = due_days(document, settings.reminder_schedule, now)
      return if due.empty?

      waiting = submission.submitters.select do |s|
        s.sent_at? && !s.completed_at? && !s.declined_at? && s.email.present? && !s.viewer?
      end

      waiting.each do |submitter|
        mail = SubmitterMailer.invitation_email(submitter)
        mail.subject = "Reminder: #{mail.subject}"
        mail.deliver_now!
        SubmissionEvent.create!(submitter:, event_type: 'send_reminder_email')
      end

      document.update!(reminders_sent: (document.reminders_sent + due).uniq)
      document.log!("reminder sent (day #{due.max})", actor: 'system', data: { to: waiting.map(&:email), days: due })
    end

    def warn_expiry(document, submission, settings, now)
      return if document.expiry_warned_at || submission.expire_at.blank?
      return if submission.expire_at - now > settings.expiry_warning_days.days

      DeskMailer.expiry_warning_email(document).deliver_now!
      document.update!(expiry_warned_at: now)
      document.log!('expiry warning sent', actor: 'system', data: { expire_at: submission.expire_at })
    end

    def complete!(document, submission)
      return document.log!('waiting for the signed PDF', actor: 'system') unless fetch_signed!(document, submission)

      document.transition!('signed', actor: 'system', signed_at: submission.completed_at)
      document.log!('signed PDF and audit record fetched', actor: 'system',
                                                           data: { signed_sha256: document.signed_pdf.blob.checksum,
                                                                   audit_sha256: document.audit_log.blob.checksum })
      signed_pages!(document)

      DeskMailer.completed_email(document).deliver_later!
      document.log!('sender notified', actor: 'system', data: { to: document.sent_by_user&.email })
    end

    # The signed PDF and the audit record, from WE Sign into the register (each once).
    def fetch_signed!(document, submission)
      audit = Submissions::EnsureAuditGenerated.call(submission)
      last = submission.submitters.reject(&:viewer?).max_by { |s| s.completed_at || Time.zone.at(0) }
      signed = Submissions::EnsureResultGenerated.call(last).first

      return false unless audit && signed

      document.signed_pdf.attach(signed.blob) unless document.signed_pdf.attached?
      document.audit_log.attach(audit.blob) unless document.audit_log.attached?

      true
    end

    # Page images of the signed PDF, for the document card (made once). True when they were made now.
    def signed_pages!(document)
      attachment = document.signed_pdf.attachment
      return false if attachment.nil? || attachment.preview_images.exists?

      data = attachment.download
      pdf = Pdfium::Document.open_bytes(data)
      Templates::ProcessDocument.generate_pdf_preview_images(attachment, data, doc: pdf)

      true
    ensure
      pdf&.close
    end
  end
end

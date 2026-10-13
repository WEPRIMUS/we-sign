# frozen_string_literal: true

# Contract Desk e-mails to the sender: the signing links are about to expire, and the document is signed; and to the
# "Keep informed" list: the document was sent (the signed copy is WE Sign's own, see Desk::FollowUp).
# (Reminders to signers reuse WE Sign's own invitation e-mail, see Desk::FollowUp.)
class DeskMailer < ApplicationMailer
  def expiry_warning_email(document)
    @document = document
    @account = document.account
    @waiting = document.submission.submitters.reject { |s| s.completed_at? || s.declined_at? }

    assign_message_metadata('desk_expiry_warning', document.submission)

    I18n.with_locale(@account.locale) do
      mail(to: document.sent_by_user.friendly_name,
           subject: "Signing links expire soon: #{document.name}")
    end
  end

  # To an address on the "Keep informed" list (Desk settings): the document was sent. The people invited are every
  # signer but our side when the sender signed it at that moment. For a "Copy for information" (attach: true), the
  # PDF as it stands is attached: signed on our side when our side has signed, otherwise the original.
  def sent_email(document, to, attach: false)
    @document = document
    @account = document.account
    @sender = document.sent_by_user
    @signers = document.submission.submitters.reject do |s|
      s.viewer? || (s.completed_at? && s.completed_at <= document.sent_at)
    end
    @for_information = attach # an outside reader: the PDF, not a link into the desk
    @attached = attach_pdf(document) if attach

    assign_message_metadata('desk_sent', document.submission)

    I18n.with_locale(@account.locale) do
      mail(to:, subject: "Sent: #{document.name}")
    end
  end

  # The PDF for a copy for information. Returns what was attached, or nil when it is too large to attach.
  def attach_pdf(document)
    own = document.submission.submitters.find { |s| s.uuid == Desk::Signers.uuid(document, 'own-1') }
    signed = own&.completed_at?
    blobs = signed ? Submissions::EnsureResultGenerated.call(own).map(&:blob) : [document.source_file.blob]
    return if blobs.sum(&:byte_size) > SubmitterMailer::MAX_ATTACHMENTS_SIZE

    blobs.each { |blob| attachments[blob.filename.to_s] = blob.download }

    signed ? 'as sent, signed on our side' : 'the document as sent'
  end

  def completed_email(document)
    @document = document
    @account = document.account

    assign_message_metadata('desk_completed', document.submission)

    I18n.with_locale(@account.locale) do
      mail(to: document.sent_by_user.friendly_name, subject: "Signed: #{document.name}")
    end
  end
end

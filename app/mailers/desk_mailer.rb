# frozen_string_literal: true

# Contract Desk e-mails to the sender: the signing links are about to expire, and the document is signed.
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

  def completed_email(document)
    @document = document
    @account = document.account

    assign_message_metadata('desk_completed', document.submission)

    I18n.with_locale(@account.locale) do
      mail(to: document.sent_by_user.friendly_name, subject: "Signed: #{document.name}")
    end
  end
end

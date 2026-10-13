# frozen_string_literal: true

module Desk
  # E-mail that does not go out must not go unnoticed: the app does not raise delivery errors (a failed send looks
  # like a sent one), so every SMTP delivery records here whether it went out. A failure is kept as the time of the
  # first one and the class of the last error, never the message, an address or a credential. The Contract Desk home
  # shows it until the next delivery that goes out. (Outside the app, a daily login check alerts by Telegram.)
  module MailHealth
    module_function

    def failed!(error)
      Setting.where(mail_failed_at: nil).update_all(mail_failed_at: Time.current)
      Setting.update_all(mail_error: error.class.name.truncate(100))
    rescue StandardError => e
      Rails.logger.error("Contract Desk: mail failure not recorded (#{e.class})")
    end

    def delivered!
      Setting.where.not(mail_failed_at: nil).update_all(mail_failed_at: nil, mail_error: nil)
    rescue StandardError => e
      Rails.logger.error("Contract Desk: mail delivery not recorded (#{e.class})")
    end

    # Prepended to Mail::SMTP (config/initializers/desk.rb). It records the outcome and changes nothing else: the
    # error is raised again, for Mail to handle as before.
    module Delivery
      def deliver!(mail)
        result = super
        MailHealth.delivered!
        result
      rescue StandardError => e
        MailHealth.failed!(e)
        raise
      end
    end
  end
end

# frozen_string_literal: true

# Contract Desk: the nightly check starts with the background jobs (embedded Sidekiq) of each application start.
ActiveSupport.on_load(:sidekiq_config) do |config|
  config.on(:startup) { Desk::ReconcileJob.start! }
end

# Contract Desk: every SMTP delivery records whether it went out, for the desk home's warning (Desk::MailHealth).
Rails.application.config.after_initialize do
  require 'mail'
  Mail::SMTP.prepend(Desk::MailHealth::Delivery)
end

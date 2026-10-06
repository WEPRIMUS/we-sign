# frozen_string_literal: true

# Contract Desk: the nightly check starts with the background jobs (embedded Sidekiq) of each application start.
ActiveSupport.on_load(:sidekiq_config) do |config|
  config.on(:startup) { Desk::ReconcileJob.start! }
end

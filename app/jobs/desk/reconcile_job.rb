# frozen_string_literal: true

module Desk
  # The nightly check (Desk::Reconcile), at RUN_HOUR_UTC. One chain only: each start of the application writes a new
  # token, and a run whose token is not the current one stops without rescheduling. One run per night, whatever
  # happens (a key kept for most of a day). Automated: it can follow up, never send.
  class ReconcileJob
    include Sidekiq::Job

    sidekiq_options retry: false

    RUN_HOUR_UTC = 23 # 02:00 in Riyadh
    TOKEN_KEY = 'desk:reconcile:token'

    def self.start!
      token = SecureRandom.hex(8)
      Sidekiq.redis { |redis| redis.call('SET', TOKEN_KEY, token) }
      perform_at(next_run, 'token' => token)
    end

    def self.next_run(now = Time.current.utc)
      run = now.change(hour: RUN_HOUR_UTC, min: 0, sec: 0)

      run > now ? run : run + 1.day
    end

    def perform(params = {})
      return unless Sidekiq.redis { |redis| redis.call('GET', TOKEN_KEY) } == params['token']

      night = "desk:reconcile:done:#{Time.current.utc.to_date}"
      first = Sidekiq.redis { |redis| redis.call('SET', night, '1', 'NX', 'EX', 20 * 3600) }

      if first
        counts = Desk::Automation.run { Desk::Reconcile.call }
        Rails.logger.info("Contract Desk nightly check: #{counts.to_h.to_json}")
      end

      self.class.perform_at(self.class.next_run, 'token' => params['token'])
    end
  end
end

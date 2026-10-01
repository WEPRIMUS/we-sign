# frozen_string_literal: true

module RateLimit
  LimitApproached = Class.new(StandardError)

  module_function

  # WE Sign: the counters live in the database, so they survive a restart and are shared by every process.
  def call(key, limit:, ttl:, enabled: Docuseal.multitenant?)
    return true unless enabled

    now = Time.current

    RateLimitCounter.where(expires_at: ..now).delete_all

    counter = RateLimitCounter.create_or_find_by!(key:) { |c| c.expires_at = now + ttl }

    RateLimitCounter.where(id: counter.id).update_all('count = count + 1')

    raise LimitApproached if RateLimitCounter.where(id: counter.id).pick(:count).to_i > limit

    true
  end
end

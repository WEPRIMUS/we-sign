# frozen_string_literal: true

# == Schema Information
#
# Table name: rate_limit_counters
#
#  id         :bigint           not null, primary key
#  count      :integer          default(0), not null
#  expires_at :datetime         not null
#  key        :string           not null
#
# Indexes
#
#  index_rate_limit_counters_on_expires_at  (expires_at)
#  index_rate_limit_counters_on_key         (key) UNIQUE
#
class RateLimitCounter < ApplicationRecord
end

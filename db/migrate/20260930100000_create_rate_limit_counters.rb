# frozen_string_literal: true

class CreateRateLimitCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :rate_limit_counters do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.string :key, null: false, index: { unique: true }
      t.integer :count, null: false, default: 0
      t.datetime :expires_at, null: false, index: true
    end
  end
end

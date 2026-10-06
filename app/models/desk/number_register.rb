# frozen_string_literal: true

module Desk
  # The numbering register: one row per account, prefix and year, holding the last number issued.
  class NumberRegister < ApplicationRecord
    belongs_to :account

    before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Issued numbers are never removed' }

    # The next number of a series, e.g. "SP-VAR-2026-002": computed by code under a row lock, never by the AI.
    # The series row is made if missing (insert, or nothing when another request made it first), then locked, so
    # two requests at the same moment get two consecutive numbers: no gap, no duplicate.
    def self.next!(account_id:, prefix:, year:)
      transaction(requires_new: true) do
        now = Time.current
        insert_all([{ account_id:, prefix:, year:, last_number: 0, created_at: now, updated_at: now }],
                   unique_by: :index_desk_number_registers_one_per_series)
        row = lock.find_by!(account_id:, prefix:, year:)
        row.update!(last_number: row.last_number + 1)

        format('%<prefix>s-%<year>d-%<number>03d', prefix:, year:, number: row.last_number)
      end
    end
  end
end

# frozen_string_literal: true

# Real concurrency needs real transactions: this example commits, and removes what it made.
RSpec.describe 'Contract Desk numbering under concurrency' do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false

  it 'gives every request its own number, in sequence, with no gap and no duplicate' do
    account = Account.create!(name: 'Numbering test', locale: 'en-US', timezone: 'UTC')

    numbers = Array.new(8) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Array.new(5) { Desk::NumberRegister.next!(account_id: account.id, prefix: 'CONC-VAR', year: 2026) }
        end
      end
    end.flat_map(&:value)

    expect(numbers.size).to eq(40)
    expect(numbers.uniq.size).to eq(40)
    expect(numbers.sort).to eq((1..40).map { |n| format('CONC-VAR-2026-%03d', n) })
  ensure
    Desk::NumberRegister.where(account_id: account&.id).delete_all
    account&.delete
  end
end

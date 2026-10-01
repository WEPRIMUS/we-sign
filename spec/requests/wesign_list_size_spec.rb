# frozen_string_literal: true

# WE Sign (SEC-PRF-04): no list answers with more than 200 rows, whatever the client says it is.
describe 'WE Sign list size' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  it 'returns at most 200 users to a request that says it is the mobile app' do
    now = Time.current
    rows = Array.new(205) do |i|
      { account_id: account.id, email: "member-#{i}@example.com", encrypted_password: 'x', role: 'admin',
        uuid: SecureRandom.uuid, created_at: now, updated_at: now }
    end
    User.insert_all(rows)

    sign_in(user)
    get settings_users_path, headers: { 'User-Agent' => 'Hotwire Native iOS' }

    expect(response).to have_http_status(:ok)
    expect(response.body.scan(/member-\d+@example\.com/).uniq.size).to be_between(1, 200)
  end
end

# frozen_string_literal: true

# WE Sign must-fix 4: staff login to the numbers of the Security and Safety Standard
# (SEC-APP-09, -10, -11, -13, -14, -15, SEC-PRF-03).
describe 'WE Sign staff login' do
  let(:account) { create(:account) }
  let(:password) { 'correct-horse-battery' }
  let!(:user) { create(:user, account:, email: 'staff@example.com', password:) }
  let(:staff_page) { settings_users_path }

  def log_in(email: user.email, password: self.password, **extra)
    post user_session_path, params: { user: { email:, password:, **extra } }
  end

  def expect_signed_out
    get staff_page # an expired session is first sent back to the page it asked for, now signed out
    get staff_page

    expect(response).to redirect_to(new_user_session_path)
  end

  describe 'the password' do
    it 'must be at least 12 characters (SEC-APP-11)' do
      expect(build(:user, account:, password: 'a' * 11)).not_to be_valid
      expect(build(:user, account:, password: 'a' * 12)).to be_valid
    end

    it 'is hashed with bcrypt cost 12 outside the test environment (SEC-APP-09)' do
      devise_config = Rails.root.join('config/initializers/devise.rb').read

      expect(devise_config.include?('config.stretches = Rails.env.test? ? 1 : 12')).to be(true)
    end
  end

  describe 'the session (SEC-APP-10)' do
    it 'ends after 30 minutes without a request' do
      log_in
      get staff_page

      expect(response).to have_http_status(:ok)

      travel_to(31.minutes.from_now) { expect_signed_out }
    end

    it 'ends 24 hours after sign-in, however active it is' do
      log_in

      start = Time.current

      71.times do |i|
        travel_to(start + ((i + 1) * 20.minutes)) { get staff_page }

        expect(response).to have_http_status(:ok)
      end

      travel_to(start + 24.hours + 1.minute) { expect_signed_out }
    end

    it 'is not kept alive by a remember-me cookie' do
      log_in(remember_me: '1')

      expect(response.headers['Set-Cookie'].to_s.include?('remember_user_token')).to be(false)

      travel_to(31.minutes.from_now) { expect_signed_out }
    end

    it 'has no remember-me module that could set or read such a cookie' do
      expect(User.devise_modules).not_to include(:rememberable)
      expect(User.new).not_to respond_to(:remember_me)
    end
  end

  describe 'the lockout (SEC-APP-13)' do
    it 'refuses the right password after 5 failures, for 15 minutes, and does not say the account is locked' do
      5.times { log_in(password: 'wrong-password-1') }

      expect(user.reload.access_locked?).to be(true)

      log_in

      expect(response.body.include?('locked')).to be(false)
      expect_signed_out

      travel_to(16.minutes.from_now) do
        log_in
        get staff_page

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'the 2FA prompt (SEC-APP-10)' do
    before { user.update!(otp_required_for_login: true, otp_secret: User.generate_otp_secret) }

    it 'answers a wrong password on a 2FA account exactly as it answers an unknown address' do
      log_in(password: 'wrong-password-1')
      known = [response.status, response.body.include?('otp_attempt')]

      log_in(email: 'nobody@example.com', password: 'wrong-password-1')

      expect(known).to eq([response.status, response.body.include?('otp_attempt')])
      expect(known.last).to be(false)
    end

    it 'is shown once the password is right' do
      log_in

      expect(response.body.include?('otp_attempt')).to be(true)
    end

    it 'counts wrong passwords towards the lockout' do
      5.times { log_in(password: 'wrong-password-1') }

      expect(user.reload.access_locked?).to be(true)

      log_in

      expect(response.body.include?('otp_attempt')).to be(false)
    end
  end

  describe 'the password reset link (SEC-APP-15)' do
    let(:new_password) { { password: 'a-brand-new-password', password_confirmation: 'a-brand-new-password' } }

    it 'is refused 31 minutes after it was sent' do
      token = user.send_reset_password_instructions

      travel_to(31.minutes.from_now) do
        put user_password_path, params: { user: { reset_password_token: token, **new_password } }
      end

      expect(user.reload.valid_password?('a-brand-new-password')).to be(false)
    end

    it 'works 29 minutes after it was sent' do
      token = user.send_reset_password_instructions

      travel_to(29.minutes.from_now) do
        put user_password_path, params: { user: { reset_password_token: token, **new_password } }
      end

      expect(user.reload.valid_password?('a-brand-new-password')).to be(true)
    end
  end

  describe 'the per-IP limit (SEC-APP-13, SEC-PRF-03)' do
    it 'answers 429 to the 11th login attempt in a minute from one address' do
      10.times { |i| log_in(email: "nobody#{i}@example.com") }

      expect(response).not_to have_http_status(:too_many_requests)

      log_in

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers['Retry-After']).to be_present
      expect_signed_out
    end

    it 'answers 429 to the 11th password reset request in a minute from one address' do
      11.times { |i| post user_password_path, params: { user: { email: "nobody#{i}@example.com" } } }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe 'the account switch that forces 2FA (SEC-APP-14)' do
    let(:token) { { 'x-auth-token': user.access_token.token } }

    before { create(:account_config, account:, key: AccountConfig::FORCE_MFA, value: true) }

    it 'sends a user without 2FA to the setup page from every staff page' do
      sign_in(user)

      [staff_page, settings_esign_path, template_path(create(:template, account:, author: user))].each do |path|
        get path

        expect(response).to redirect_to(mfa_setup_path)
      end

      get mfa_setup_path

      expect(response).to have_http_status(:ok)
    end

    it 'refuses the API to a user without 2FA, by session cookie and by token' do
      get '/api/templates', headers: token

      expect(response).to have_http_status(:forbidden)

      sign_in(user)
      get '/api/templates'

      expect(response).to have_http_status(:forbidden)
    end

    it 'lets a user with 2FA through' do
      user.update!(otp_required_for_login: true, otp_secret: User.generate_otp_secret)
      sign_in(user)

      get staff_page

      expect(response).to have_http_status(:ok)

      get '/api/templates', headers: token

      expect(response).to have_http_status(:ok)
    end
  end
end

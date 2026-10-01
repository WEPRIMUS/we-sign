# frozen_string_literal: true

# WE Sign: absolute lifetime of a staff session (SEC-APP-10: 24 hours at most), next to Devise's idle
# timeout (config.timeout_in). The sign-in time is kept in the session itself, so it is per session.
WESIGN_SESSION_MAX_AGE = 24.hours

Warden::Manager.after_set_user do |_record, warden, options|
  scope = options[:scope]

  next unless warden.authenticated?(scope) && options[:store] != false

  session = warden.session(scope)
  session['signed_in_at'] = Time.now.to_i if options[:event] != :fetch || session['signed_in_at'].nil?

  next if session['signed_in_at'] > WESIGN_SESSION_MAX_AGE.ago.to_i

  warden.logout(scope)

  throw :warden, scope:, message: :timeout
end

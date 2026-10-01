# frozen_string_literal: true

module EmailVerificationCodes
  DRIFT_BEHIND = 5.minutes

  module_function

  def generate(value)
    totp = ROTP::TOTP.new(build_totp_secret(value))

    totp.at(Time.current)
  end

  def verify(code, value)
    totp = ROTP::TOTP.new(build_totp_secret(value))

    return false unless totp.verify(code, drift_behind: DRIFT_BEHIND)

    # WE Sign: a code is used up when accepted; a second use inside its validity window is refused
    RateLimit.call("used-code-#{Digest::SHA256.hexdigest([value, code].join(':'))}",
                   limit: 1, ttl: DRIFT_BEHIND + 1.minute, enabled: true)
  rescue RateLimit::LimitApproached
    false
  end

  def build_totp_secret(value)
    ROTP::Base32.encode(
      Digest::SHA1.digest(
        [Rails.application.secret_key_base, 'form_email_2fa', value].join(':')
      )
    )
  end
end

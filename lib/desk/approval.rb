# frozen_string_literal: true

module Desk
  # A person's "Yes, send": made only from a signed-in staff request (POST, the person's own session, not an
  # impersonation, two-factor sign-in turned on). Desk::Sender and Desk::Document#transition!('sent') require one.
  class Approval
    NotAllowed = Class.new(StandardError)

    attr_reader :user, :request

    def self.from_request!(request:, user:, true_user:)
      raise NotAllowed, 'Only a signed-in person can send' unless user && request.post?
      raise NotAllowed, 'Only a signed-in person can send' unless request.env['warden']&.user(:user) == true_user
      raise NotAllowed, 'Send from your own sign-in, not while viewing as someone else' if true_user != user
      raise NotAllowed, 'Turn on two-factor sign-in (Profile) before you send' unless user.otp_required_for_login?

      new(user:, request:)
    end

    def initialize(user:, request:)
      @user = user
      @request = request
    end

    private_class_method :new
  end
end

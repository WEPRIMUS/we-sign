# frozen_string_literal: true

module Desk
  # Every desk page: a signed-in person of the account (ApplicationController signs in and applies "force 2FA").
  # In this edition every user is an administrator, so the desk enforces its own rules in its code: every record is
  # looked up within the person's account, and only Desk::Sender can send.
  class BaseController < ApplicationController
    skip_authorization_check

    helper_method :desk_settings

    private

    def documents_scope = Desk::Document.where(account_id: current_account.id)

    def clients_scope = Desk::Client.where(account_id: current_account.id)

    def questions_scope = Desk::Question.where(account_id: current_account.id)

    def desk_settings = @desk_settings ||= Desk::Setting.for(current_account)
  end
end

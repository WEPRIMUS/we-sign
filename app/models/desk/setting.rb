# frozen_string_literal: true

module Desk
  # The desk's settings for one account. The AI provider is not here: it is one setting per installation
  # (DESK_AI_ENDPOINT, DESK_AI_MODEL, DESK_AI_API_KEY in the environment), so the key never enters the database.
  #
  # own_profile is our own company: the desk fills our side of every document from it, never asks a question about
  # it, and only flags where a document says something different.
  class Setting < ApplicationRecord
    PROFILE_KEYS = %w[legal_name address place country licence_number licence_expiry tax_number signer_name
                      signer_title signer_email document_prefix vat_rate].freeze

    belongs_to :account

    attribute :approver_user_ids, default: -> { [] }
    attribute :reminder_days, default: -> { [3, 7, 14] }
    attribute :own_party_names, default: -> { [] }
    attribute :signer_titles, default: -> { {} }
    attribute :own_profile, default: -> { {} }

    validates :expiry_warning_days, numericality: { only_integer: true, in: 0..29 }
    validate :reminder_days_in_range
    validate :profile_values

    def self.for(account)
      find_or_create_by!(account_id: account.id) do |setting|
        setting.own_party_names = [Brand.legal_name, Brand.public_name, account.name].compact_blank.uniq
        setting.own_profile = { 'legal_name' => Brand.legal_name, 'country' => Brand.legal_country }.compact
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def profile = own_profile.to_h.slice(*PROFILE_KEYS).transform_values { |v| v.to_s.strip }.compact_blank

    # The names our company appears under: the list set here and the legal name of the profile.
    def own_names = (own_party_names + [profile['legal_name']]).compact_blank.uniq

    def own_party?(name)
      normalized = Normalize.name(name)

      normalized.present? && own_names.any? { |own| Normalize.same_company?(Normalize.name(own), normalized) }
    end

    # The default signer of the profile, when the given printed name is that person (or no name is printed).
    def profile_signer_for(name)
      return if profile['signer_name'].blank?
      return if name.present? && Normalize.person(name) != Normalize.person(profile['signer_name'])

      { 'name' => profile['signer_name'], 'title' => profile['signer_title'], 'email' => profile['signer_email'] }
    end

    def vat_rate = BigDecimal(profile['vat_rate'].presence || '0')

    # With "approval required" off, every signed-in person of the account may say "Yes, send".
    def may_send?(user)
      !approval_required || approver_user_ids.map(&:to_i).include?(user.id)
    end

    def reminder_schedule = reminder_days.map(&:to_i).uniq.sort

    private

    def reminder_days_in_range
      return if reminder_days.is_a?(Array) && reminder_days.all? do |d|
        d.to_i.between?(1, 29)
      end && reminder_days.size <= 6

      errors.add(:reminder_days, 'must be up to six days between 1 and 29')
    end

    def profile_values
      values = profile

      if values['vat_rate'].present? && !values['vat_rate'].match?(/\A\d{1,2}(\.\d{1,2})?\z/)
        errors.add(:base, 'The VAT rate is a percentage, such as 5')
      end
      if values['signer_email'].present? && !values['signer_email'].match?(URI::MailTo::EMAIL_REGEXP)
        errors.add(:base, "The signer's e-mail address is not valid")
      end
      if values['licence_expiry'].present? && !values['licence_expiry'].match?(/\A\d{4}-\d{2}-\d{2}\z/)
        errors.add(:base, 'Write the licence expiry as YYYY-MM-DD')
      end
      return unless values['country'].present? && !values['country'].match?(/\A[A-Z]{2}\z/)

      errors.add(:base, 'The country is a two-letter code, such as AE')
    end
  end
end

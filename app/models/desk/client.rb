# frozen_string_literal: true

module Desk
  # The client register. One client per legal name and per tax number (the database enforces both, see the
  # migration). A client read from a document is created as "new: please confirm", with its source.
  class Client < ApplicationRecord
    STATUSES = %w[confirmed new_please_confirm].freeze

    belongs_to :account
    has_many :documents, class_name: 'Desk::Document', dependent: nil

    attribute :signers, default: -> { [] }

    before_validation :normalize_keys

    validates :legal_name, :normalized_name, :source, presence: true
    validates :status, inclusion: STATUSES
    validate :one_client_per_name_and_tax_number, if: -> { archived_at.nil? }

    scope :active, -> { where(archived_at: nil) }

    before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Clients are archived, never deleted' }

    # The same tax number, or the same legal name (legal suffixes and punctuation ignored), is the same client.
    def self.match(account_id, legal_name:, tax_number: nil, except_id: nil)
      scope = active.where(account_id:).where.not(id: except_id)
      tax = Normalize.tax(tax_number)
      name = Normalize.name(legal_name)

      (tax && scope.find_by(normalized_tax_number: tax)) || (name.present? && scope.find_by(normalized_name: name))
    end

    def new_please_confirm? = status == 'new_please_confirm'

    def signer_named(name)
      key = Normalize.person(name)

      signers.find { |s| key.present? && Normalize.person(s['name']) == key }
    end

    # Adds or updates one signer (matched by name); the register learns from the answers people give.
    def remember_signer!(name:, role: nil, email: nil)
      list = signers.map(&:dup)
      entry = list.find { |s| Normalize.person(s['name']) == Normalize.person(name) }
      entry ||= { 'name' => name }.tap { |e| list << e }
      entry['role'] = role if role.present?
      entry['email'] = email if email.present?
      update!(signers: list)
    end

    private

    def normalize_keys
      self.normalized_name = Normalize.name(legal_name)
      self.normalized_tax_number = Normalize.tax(tax_number)
      self.signers = Array(signers).map { |s| s.to_h.stringify_keys.slice('name', 'role', 'email').compact_blank }
                                   .reject { |s| s['name'].blank? }
    end

    def one_client_per_name_and_tax_number
      existing = self.class.match(account_id, legal_name:, tax_number:, except_id: id)

      errors.add(:base, "This client is already in the register: #{existing.legal_name}") if existing
    end
  end
end

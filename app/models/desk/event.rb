# frozen_string_literal: true

module Desk
  # The append-only log of every step: who or what (a person, the system, the AI), when, and what.
  # Rows are never changed or removed: here (read-only once saved) and in the database (trigger, see the migration).
  class Event < ApplicationRecord
    ACTORS = %w[person system ai].freeze

    belongs_to :account
    belongs_to :document, class_name: 'Desk::Document', optional: true
    belongs_to :client, class_name: 'Desk::Client', optional: true
    belongs_to :user, optional: true

    attribute :data, default: -> { {} }

    validates :actor, inclusion: ACTORS
    validates :action, presence: true

    def readonly? = persisted?

    def self.log!(account_id:, action:, actor:, document: nil, client: nil, user: nil, data: {})
      create!(account_id:, action:, actor:, document:, client:, user:, data:)
    end
  end
end

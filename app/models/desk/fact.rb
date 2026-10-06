# frozen_string_literal: true

module Desk
  # Interpreted truth: one thing read from a document (or given by a person, or taken from the register), with where
  # it came from, how sure it is and its status. A new reading supersedes the old rows; nothing is overwritten.
  #   validated:  read by the AI and found by code in the document's own text
  #   candidate:  read from a page image, where there is no text to check it against
  #   unverified: the AI's quote is not in the document; treated as unknown
  #   confirmed:  given or confirmed by a person, or taken from the client register
  class Fact < ApplicationRecord
    STATUSES = %w[validated candidate unverified confirmed superseded].freeze
    ORIGINS = %w[ai rule register person].freeze
    USABLE = %w[validated candidate confirmed].freeze

    belongs_to :account
    belongs_to :document, class_name: 'Desk::Document'

    attribute :value, default: -> { {} }
    attribute :source_ref, default: -> { {} }

    validates :key, presence: true
    validates :status, inclusion: STATUSES
    validates :origin, inclusion: ORIGINS

    scope :current, -> { where.not(status: 'superseded') }
    scope :usable, -> { where(status: USABLE) }

    before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Facts are superseded, never deleted' }
  end
end

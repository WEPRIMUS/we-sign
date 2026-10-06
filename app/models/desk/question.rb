# frozen_string_literal: true

module Desk
  # A question in the box: something the system could not establish itself. The document waits for the answer.
  class Question < ApplicationRecord
    KINDS = %w[email signer confirm_client acknowledge fix_fields choose_client text form].freeze

    belongs_to :account
    belongs_to :document, class_name: 'Desk::Document'
    belongs_to :answered_by_user, class_name: 'User', optional: true

    attribute :context, default: -> { {} }

    validates :kind, inclusion: KINDS
    validates :prompt, :key, presence: true

    scope :open, -> { where(status: 'open') }
    scope :answered, -> { where(status: 'answered') }

    before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Questions are kept with their answers' }

    def open? = status == 'open'
  end
end

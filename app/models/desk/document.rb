# frozen_string_literal: true

module Desk
  # A document on the desk, from intake to the signed copy. The state changes only through #transition!, which
  # refuses any step not in TRANSITIONS and writes every change to the event log.
  class Document < ApplicationRecord
    TRANSITIONS = {
      'preparing' => %w[waiting_for_you ready_to_send archived],
      'waiting_for_you' => %w[preparing archived],
      'ready_to_send' => %w[sent preparing waiting_for_you archived],
      'sent' => %w[opened signed declined expired archived],
      'opened' => %w[signed declined expired archived],
      'signed' => %w[archived],
      'declined' => %w[archived],
      'expired' => %w[archived],
      'archived' => []
    }.freeze

    STATES = TRANSITIONS.keys.freeze
    OUT_FOR_SIGNATURE = %w[sent opened].freeze

    InvalidTransition = Class.new(StandardError)

    belongs_to :account
    belongs_to :client, class_name: 'Desk::Client', optional: true
    belongs_to :template, class_name: '::Template', optional: true
    belongs_to :submission, class_name: '::Submission', optional: true
    belongs_to :created_by_user, class_name: 'User'
    belongs_to :sent_by_user, class_name: 'User', optional: true
    belongs_to :approved_by_user, class_name: 'User', optional: true

    has_many :facts, class_name: 'Desk::Fact', dependent: nil
    has_many :questions, class_name: 'Desk::Question', dependent: nil
    has_many :events, class_name: 'Desk::Event', dependent: nil

    has_one_attached :source_file
    has_one_attached :signed_pdf
    has_one_attached :audit_log

    attribute :uuid, :string, default: -> { SecureRandom.uuid }
    attribute :reminders_sent, default: -> { [] }

    validates :state, inclusion: STATES
    validates :file_sha256, presence: true

    before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Documents are archived, never deleted' }

    scope :active, -> { where.not(state: 'archived') }

    def to_param = uuid

    def name = title.presence || filename.presence || "Document #{id}"

    def out_for_signature? = OUT_FOR_SIGNATURE.include?(state)

    # Only Desk::Sender moves a document to "sent", and only with a person's approval (Desk::Approval).
    def transition!(to, actor:, user: nil, approval: nil, data: {}, **attrs)
      to = to.to_s

      unless TRANSITIONS.fetch(state).include?(to)
        raise InvalidTransition,
              "#{state} -> #{to} is not a step of the desk"
      end

      if to == 'sent' && !(approval.is_a?(Desk::Approval) && approval.user == user)
        raise Desk::Approval::NotAllowed, 'Only a person can send'
      end

      from = state
      update!(state: to, **attrs)
      log!("state #{from} -> #{to}", actor:, user:, data:)

      self
    end

    def log!(action, actor:, user: nil, data: {})
      Desk::Event.log!(account_id:, document: self, client:, action:, actor:, user:, data:)
    end

    def fail!(message, actor: 'system')
      update!(last_error: message.to_s.truncate(500), last_error_at: Time.current)
      transition!('waiting_for_you', actor:, data: { error: last_error }) if state == 'preparing'
      log!('failed', actor:, data: { error: last_error })
    end
  end
end

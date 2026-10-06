# frozen_string_literal: true

# rubocop:disable Metrics
module Desk
  # Turns what is missing into questions in the box, and applies the answers. A question already answered is not
  # asked again; an answer is kept as a person's fact and, for a client's signer, in the client register.
  module Questions
    # A refused answer. For a form, field names the box it is about ("date", "rows.1.one_time").
    class Invalid < StandardError
      attr_reader :field

      def initialize(message = nil, field: nil)
        super(message)
        @field = field
      end
    end

    module_function

    def build!(document, slots)
      wanted = []
      client = document.client

      if client&.new_please_confirm?
        wanted << ['confirm_client', 'confirm_client',
                   "This document names a client who is not in the register yet: #{client.legal_name}. " \
                   'Add it to the register?',
                   'Check the name, country, address and tax number read from the document, shown below.',
                   { 'client_id' => client.id }]
      end

      slots.each do |slot|
        next if slot.own # our own side is never asked about: it comes from the own profile

        if slot.name.blank?
          wanted << ["signer:#{slot.key}", 'signer',
                     "Who signs for #{slot.party_name}? Write the name, the title and the e-mail address.",
                     'Layla Haddad, Operations Director, layla@example.com', { 'slot' => slot.key }]
        elsif slot.email.blank?
          title = ", #{slot.title}," if slot.title.present?
          wanted << ["email:#{slot.key}", 'email',
                     "What is the e-mail address of #{slot.name}#{title} who signs for #{slot.party_name}?",
                     'name@company.com', { 'slot' => slot.key }]
        end
      end

      document.facts.current.where(key: 'gap').order(:id).each do |gap|
        wanted << ["gap:#{gap.value['key'].presence || gap.id}", 'acknowledge',
                   "#{gap.value['question']} (The uploaded document is sent as it is: the desk never changes it.)",
                   nil, { 'fact_id' => gap.id, 'page' => gap.source_ref['page'] }]
      end

      wanted.each_with_index do |(key, kind, prompt, example, context), index|
        document.questions.create_with(account_id: document.account_id, kind:, prompt:, example:, context:,
                                       position: index).find_or_create_by!(key:)
      end
    end

    def ask_to_fix!(document, problems)
      document.questions.create_with(
        account_id: document.account_id, kind: 'fix_fields', position: 90, context: { 'problems' => problems },
        prompt: "#{problems.join('. ')}. Open the editor with Fix something, place the box, save, then answer here."
      ).find_or_create_by!(key: "fix_fields:#{Digest::SHA1.hexdigest(problems.sort.join)[0, 10]}")
    end

    def answer!(question, answer, user)
      document = question.document
      answer = answer.to_s.strip unless question.kind == 'form'

      case question.kind
      when 'email'
        email = answer.downcase
        raise Invalid, 'Write one e-mail address, such as name@company.com' unless email.match?(email_regexp)

        remember!(document, question.context['slot'], email:)
      when 'signer'
        email = answer[/[^\s,;<>]+@[^\s,;<>]+/].to_s.downcase
        name, title = answer.sub(/[^\s,;<>]+@[^\s,;<>]+/, '').split(/[,;]/).map(&:squish).compact_blank

        unless name && email.match?(email_regexp)
          raise Invalid, 'Write the name, the title and the e-mail address, separated by commas'
        end

        remember!(document, question.context['slot'], name:, title:, email:)
      when 'confirm_client'
        confirm_client!(document, question, user)
        answer = 'Yes'
      when 'choose_client', 'text', 'form'
        answer = Variation.answer!(question, answer, user)
      end

      question.update!(status: 'answered', answer: answer.presence || 'Noted', answered_by_user: user,
                       answered_at: Time.current)
      document.log!("answered: #{question.key}", actor: 'person', user:)

      resume!(document, user)
    end

    def confirm_client!(document, question, user)
      client = Client.find_by!(id: question.context['client_id'], account_id: document.account_id)
      return unless client.new_please_confirm?

      client.update!(status: 'confirmed', confirmed_by_user_id: user.id, confirmed_at: Time.current)
      Event.log!(account_id: document.account_id, client:, document:, action: 'client confirmed', actor: 'person',
                 user:)
    end

    def remember!(document, slot_key, **values)
      slot = Signers.plan(document, Setting.for(document.account)).find { |s| s.key == slot_key }

      Fact.create!(account_id: document.account_id, document:, key: 'answer', origin: 'person', status: 'confirmed',
                   run_id: 'person', value: { 'slot' => slot_key, **values.transform_keys(&:to_s) }.compact_blank)

      client = document.client
      return unless slot && !slot.own && client &&
                    Normalize.same_company?(client.normalized_name, Normalize.name(slot.party_name))

      client.remember_signer!(name: values[:name] || slot.name, role: values[:title] || slot.title,
                              email: values[:email])
    end

    # With the last question answered, the document goes back to preparing and the job continues.
    def resume!(document, user)
      return unless document.state == 'waiting_for_you' && document.questions.open.none?

      document.update!(last_error: nil, last_error_at: nil)
      document.transition!('preparing', actor: 'person', user:)
      ProcessDocumentJob.perform_async('document_id' => document.id)
    end

    def email_regexp = URI::MailTo::EMAIL_REGEXP
  end
end
# rubocop:enable Metrics

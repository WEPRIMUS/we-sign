# frozen_string_literal: true

module Desk
  # Who signs, in which order, with which e-mail: one slot per signature line of each party, filled from what the
  # document says, then the client register, then the answers people gave. A value nobody gave stays blank (and
  # becomes a question); it is never made up.
  module Signers
    # approver: the own party's signer signs at the moment of "Yes, send": anyone who approves when no name is printed
    # (signer_user_id nil), otherwise only the WE Sign user the document names (signer_user_id).
    Slot = Struct.new(:key, :party_key, :party_name, :own, :approver, :name, :title, :email, :uuid,
                      :signer_user_id) do
      def description = name.present? ? "#{name} (#{party_name})" : "the signer for #{party_name}"

      # Does this person's "Yes, send" sign for the own party?
      def signed_by?(user) = approver && (signer_user_id.nil? || signer_user_id == user.id)

      # The name of the signing party in WE Sign.
      def label = own ? party_name : [party_name, title.presence || name].compact_blank.join(' - ')
    end

    module_function

    def parties(document)
      document.facts.current.where(key: 'party').where.not(status: 'unverified').order(:id).map(&:value)
    end

    def plan(document, settings)
      signers = document.facts.current.where(key: 'signer').where.not(status: 'unverified').order(:id).map(&:value)
      answers = document.facts.current.where(key: 'answer').order(:id).each_with_object({}) do |fact, acc|
        (acc[fact.value['slot']] ||= {}).merge!(fact.value.compact_blank)
      end

      parties(document).flat_map do |party|
        lines = signers.select { |s| s['party_key'] == party['key'] }

        if party['own']
          [own_slot(document, party, lines.first || {}, answers, settings)]
        else
          (lines.presence || [{}]).each_with_index.map do |line, index|
            client_slot(document, party, line, index, answers)
          end
        end
      end
    end

    def client_slot(document, party, line, index, answers)
      key = "#{party['key']}-#{index + 1}"
      answer = answers[key] || {}
      client = document.client if document.client &&
                                  Normalize.same_company?(document.client.normalized_name,
                                                          Normalize.name(party['legal_name']))

      name = answer['name'].presence || line['name'].presence
      name ||= client.signers.dig(index, 'name') if client
      known = client&.signer_named(name) || {}

      Slot.new(key:, party_key: party['key'], party_name: party['legal_name'], own: false, approver: false, name:,
               title: answer['title'].presence || line['title'].presence || known['role'],
               email: answer['email'].presence || line['email'].presence || known['email'],
               uuid: uuid(document, key))
    end

    # The installation's own party (never a question: what is not in the document comes from the own profile).
    # With "sender signs on approval": no printed name, whoever says "Yes, send" signs; a printed name that is a
    # WE Sign user, only that person signs on approval; a printed name that is not a user is invited by e-mail.
    def own_slot(document, party, line, _answers, settings)
      key = 'own-1'
      printed = line['name'].presence
      profile = settings.profile_signer_for(printed) || {}
      user = user_named(document, printed)
      base = { key:, party_key: party['key'], party_name: party['legal_name'], own: true, uuid: uuid(document, key) }

      if settings.sender_signs_on_approval && (printed.nil? || user)
        return Slot.new(**base, approver: true, signer_user_id: user&.id, name: printed,
                                title: line['title'].presence || profile['title'], email: user&.email)
      end

      Slot.new(**base, approver: false, name: printed || profile['name'],
                       title: line['title'].presence || profile['title'],
                       email: user&.email || profile['email'] || user_named(document, profile['name'])&.email)
    end

    def user_named(document, name)
      return if name.blank?

      User.active.where(account_id: document.account_id).find do |u|
        Normalize.person(u.full_name) == Normalize.person(name)
      end
    end

    # Our own signer must be reachable: a WE Sign user or the profile's e-mail. Not asked: it is configuration.
    def own_problems(slots)
      slots.filter_map do |slot|
        next unless slot.own && !slot.approver && slot.email.blank?

        "#{slot.name.presence || 'Our signer'} signs for #{slot.party_name} but has no e-mail address: give that " \
          'person a WE Sign account, or add the e-mail in Desk settings, Our company'
      end
    end

    def uuid(document, key) = Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE, "#{document.uuid}:#{key}")
  end
end

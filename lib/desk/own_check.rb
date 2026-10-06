# frozen_string_literal: true

module Desk
  # Our own company in a document, checked against the own profile (Desk::Setting#profile). Never a question: where
  # the document says something different from the profile, or is dated after our licence expires, it is flagged
  # for the person to see on the review ("Please check").
  module OwnCheck
    COUNTRY_WORDS = { 'uae' => 'united arab emirates', 'ksa' => 'kingdom of saudi arabia' }.freeze

    module_function

    def call(document, settings)
      profile = settings.profile
      own = Signers.parties(document).find { |p| p['own'] }
      flags = []

      if own
        flags << address_flag(own, profile)
        flags << tax_flag(own, profile)
      end
      flags << licence_flag(document, profile)
      flags.compact!

      ApplicationRecord.transaction do
        document.facts.current.where(key: 'own_check').update_all(status: 'superseded', updated_at: Time.current)
        flags.each do |flag|
          Fact.create!(account_id: document.account_id, document:, key: 'own_check', value: flag, origin: 'rule',
                       status: 'confirmed', run_id: 'own_check', method: 'own profile')
        end
      end

      flags
    end

    def notes(document) = document.facts.current.where(key: 'own_check').order(:id).map { |f| f.value['note'] }

    # The address the document gives for us shares too few words with the profile's.
    def address_flag(own, profile)
      return if own['address'].blank? || profile['address'].blank?

      words = words(own['address'])
      known = words(profile['address'])
      return if words.empty? || (words & known).size >= (words.size * 0.6)

      { 'field' => 'address', 'note' => "The document gives our address as \"#{own['address']}\"; the profile " \
                                        "says \"#{profile['address']}\"." }
    end

    def tax_flag(own, profile)
      return if own['tax_number'].blank?
      return if Normalize.tax(own['tax_number']) == Normalize.tax(profile['tax_number'])

      { 'field' => 'tax_number',
        'note' => "The document gives our tax number as #{own['tax_number']}; the profile has " \
                  "#{profile['tax_number'].presence || 'none'}." }
    end

    DOCUMENT_DATE = /\A(?:document|letter|agreement|contract|quotation|variation|issue)?\s*date\z|\Adated\z/i

    # A document dated (or signed today) after our licence expires. Only the document's own date counts, not a term
    # or end date written in it.
    def licence_flag(document, profile)
      expiry = Date.parse(profile['licence_expiry']) if profile['licence_expiry'].present?
      return unless expiry

      own_dates = document.facts.current.where(key: 'date').filter_map do |f|
        Date.parse(f.value['iso']) if f.value['iso'] && f.value['label'].to_s.strip.match?(DOCUMENT_DATE)
      end
      dated = [own_dates.max, Time.zone.today].compact.max
      return if dated <= expiry

      { 'field' => 'licence', 'note' => "Our licence expires on #{expiry.strftime('%-d %B %Y')}; this document " \
                                        "is dated #{dated.strftime('%-d %B %Y')}." }
    end

    def words(text)
      text = Normalize.person(text).to_s
      COUNTRY_WORDS.each { |short, long| text = text.gsub(/\b#{short}\b/, long) }

      text.split.reject { |w| w.size < 3 }.uniq
    end
  end
end

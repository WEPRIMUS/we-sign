# frozen_string_literal: true

# rubocop:disable Metrics
module Desk
  # "New contract": a quotation and variation to an existing agreement, from eight answers in the question box.
  # Code does every number (prices, totals, VAT, the payment shares, the change to existing instalments, rounding),
  # the reference (from the numbering register) and the dates. The AI only words the scope of each item from the
  # person's notes (Desk::VariationWording). Our side comes from the own profile; the client from the register.
  module Variation
    Invalid = Questions::Invalid

    Item = Struct.new(:name, :one_time, :monthly, :note, :what, :status, :acceptance) do
      # The one line about the item in the opening list: the first sentence of what it does, kept short.
      def note_summary = what.to_s.split(/(?<=[.!?])\s/).first.to_s.truncate_words(16, omission: '...')
    end
    Share = Struct.new(:percent, :when, :amount)
    Spread = Struct.new(:share, :label, :times, :current, :current_last, :per, :per_last, :new_amount, :new_last)
    Answers = Struct.new(:parent, :items, :currency, :monthly, :shares, :spread, :terms, :exclusions)

    # A 'form' question is asked in labelled boxes (app/views/desk/questions/_form.html.erb); its answer is kept as
    # it was given (a hash, with 'rows' where there are rows) and checked here, field by field.
    QUESTIONS = [
      ['variation:client', 'choose_client', 'Which client is it for?',
       'The client must be in the register: add a new one there first.'],
      ['variation:parent', 'form', 'Which agreement does it vary?', nil],
      ['variation:items', 'form', 'What does it add?', nil],
      ['variation:scope', 'form',
       'For each item, a few words: what it does, where it stands, and how it is accepted.', nil],
      ['variation:monthly', 'text',
       'When does the monthly charge start, and what does it cover? Write "none" if nothing is charged monthly.',
       'It covers hosting, backups, updates and support. It starts on the first day of the month after go-live.'],
      ['variation:payment', 'form', 'How is the one-time total paid?', nil],
      ['variation:instalments', 'form', 'Is one of those shares spread over instalments of the agreement?', nil],
      ['variation:terms', 'form', 'What is not included, and any special terms?', nil]
    ].freeze

    NONE = %r{\A(?:none|no|n/a|-|nil)?\.?\z}i
    NUMBER_WORDS = %w[zero one two three four five six seven eight nine ten eleven twelve].freeze

    module_function

    # A new contract: the document and its eight questions, waiting for the person.
    def start!(account:, user:)
      document = Document.create!(account_id: account.id, created_by_user: user, source: 'generated',
                                  doc_type: 'variation', title: 'New variation', state: 'waiting_for_you',
                                  file_sha256: "pending:#{SecureRandom.uuid}")

      QUESTIONS.each_with_index do |(key, kind, prompt, example), index|
        document.questions.create!(account_id: account.id, key:, kind:, prompt:, example:, position: index)
      end
      document.log!('intake: new contract (variation)', actor: 'person', user:)

      document
    end

    # Checks one answer by code and keeps it as it was given. The client answer names a client of the register.
    def answer!(question, answer, _user)
      document = question.document
      key = question.key.delete_prefix('variation:')

      if key == 'client'
        client = Client.active.find_by(account_id: document.account_id, id: answer.presence)
        raise Invalid, 'Choose a client from the register' unless client

        document.update!(client:)
        answer = client.legal_name
      else
        answer = clean(answer) if question.kind == 'form'
        answer = {} if key == 'instalments' && answer['share'].blank? # "No": the boxes below it do not count
        parse(key, answer, document)
      end

      text = key == 'instalments' && answer.empty? ? 'No' : summary(answer)
      Fact.create!(account_id: document.account_id, document:, key: 'answer', origin: 'person', status: 'confirmed',
                   run_id: 'person', value: { 'question' => question.key, 'given' => answer, 'text' => text })
      text
    end

    # A form as code reads it: string keys, each value squished, and the rows the person left empty dropped (a
    # select alone, the currency or the kind of line, does not make a row).
    def clean(answer)
      return {} unless answer.is_a?(Hash)

      answer = answer.to_h { |k, v| [k.to_s, k.to_s == 'rows' ? v : v.to_s.squish] }
      return answer unless answer.key?('rows')

      rows = Array(answer['rows']).map { |row| row.to_h { |k, v| [k.to_s, v.to_s.squish] } }
      answer.merge('rows' => rows.reject { |row| row.except('currency', 'kind').values.all?(&:blank?) })
    end

    # What the question box shows as the answer once it is given.
    def summary(answer)
      return answer unless answer.is_a?(Hash)

      parts = [answer.except('rows').values.compact_blank.join(', ')]
      parts += Array(answer['rows']).map { |row| row.values.compact_blank.join(', ') }
      parts.compact_blank.join('; ').presence || 'None'
    end

    def given(document)
      document.facts.current.where(key: 'answer').order(:id).each_with_object({}) do |fact, acc|
        acc[fact.value['question'].delete_prefix('variation:')] = fact.value['given'] if fact.value['question']
      end
    end

    # Every answer checked again from what was kept (the same checks as when it was given).
    def answers(document)
      t = given(document)
      items, currency = parse_items(t['items'])
      parse_scope(t['scope'], items)
      shares = parse_payment(t['payment'])
      monthly = parse_monthly(t['monthly'], items)
      exclusions, terms = parse_terms(t['terms'], items)

      Answers.new(parse_parent(t['parent']), items, currency, monthly, shares, parse_spread(t['instalments'], shares),
                  terms, exclusions)
    end

    def given_items(document) = parse_items(given(document)['items']).first

    def given_shares(document) = parse_payment(given(document)['payment'])

    def parse(key, answer, document)
      case key
      when 'parent' then parse_parent(answer)
      when 'items' then parse_items(answer)
      when 'scope' then parse_scope(answer, given_items(document))
      when 'monthly' then parse_monthly(answer, given_items(document))
      when 'payment' then parse_payment(answer)
      when 'instalments' then parse_spread(answer, given_shares(document))
      when 'terms' then parse_terms(answer, given_items(document))
      end
    end

    # A refusal names the box it is about: "title", or "rows.1.one_time" for the second row's one-time price.
    def invalid!(message, field = nil) = raise(Invalid.new(message, field:))

    def rows(answer) = Array(answer.to_h['rows'])

    def parse_parent(answer)
      answer = answer.to_h
      invalid!('Write the title of the agreement', 'title') if answer['title'].blank?
      invalid!('Write its reference', 'reference') if answer['reference'].blank?
      iso = Reader.parse_date(answer['date'])
      invalid!('Write the date, such as 4 August 2026', 'date') unless iso
      invalid!('Write the clauses that allow a variation', 'clauses') if answer['clauses'].blank?

      answer.slice('title', 'reference', 'date', 'clauses').merge('iso' => iso)
    end

    MONEY = /\A(?:([A-Z]{3})\s*)?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?\z/

    def money(text, field = nil)
      text = text.to_s.strip
      return [BigDecimal('0'), nil] if text.match?(NONE)

      match = text.delete(' ').match(MONEY) || text.match(MONEY)
      invalid!("\"#{text}\" is not a price: write it like AUD 10000 or 10,000.00", field) unless match

      [BigDecimal("#{match[2].delete(',')}.#{match[3] || '0'}"), match[1]]
    end

    # One currency for the whole variation: the currency box of each row, or one written with a price.
    def parse_items(answer)
      rows = rows(answer)
      invalid!('Write at least one item', 'rows') if rows.empty?
      currency = nil

      items = rows.each_with_index.map do |row, i|
        at = "rows.#{i}"
        invalid!('Write the name of the item', "#{at}.name") if row['name'].blank?
        if rows[0...i].any? { |r| r['name'].to_s.casecmp?(row['name']) }
          invalid!('Two items have the same name', "#{at}.name")
        end
        invalid!('Write the one-time price, or 0', "#{at}.one_time") if row['one_time'].blank?
        invalid!('Write the monthly price, or 0', "#{at}.monthly") if row['monthly'].blank?

        one_time, c1 = money(row['one_time'], "#{at}.one_time")
        monthly, c2 = money(row['monthly'], "#{at}.monthly")
        written = [c1, c2, row['currency'].presence, currency].compact.uniq
        invalid!("One currency only, please (#{written.join(', ')})", "#{at}.currency") if written.size > 1
        invalid!('Choose the currency', "#{at}.currency") if written.empty?

        currency = written.first
        Item.new(row['name'], one_time, monthly, row['note'].presence)
      end

      [items, currency]
    end

    def parse_scope(answer, items)
      given = rows(answer).index_by { |row| row['name'].to_s.downcase }

      items.each_with_index do |item, i|
        row = given.delete(item.name.downcase).to_h
        invalid!("Write what #{item.name} does", "rows.#{i}.what") if row['what'].blank?

        item.what = row['what']
        item.status = row['status'].presence
        item.acceptance = row['acceptance'].presence
      end
      invalid!("No item is called #{given.keys.first}", 'rows') if given.any?

      items
    end

    def parse_monthly(text, items)
      return if items.sum(&:monthly).zero?
      if text.to_s.match?(NONE)
        raise Invalid,
              'An item has a monthly price: say when the charge starts and what it covers'
      end

      text.to_s.squish
    end

    def parse_payment(answer)
      shares = rows(answer).each_with_index.map do |row, i|
        percent = row['percent'].to_s.delete(' ')
        unless percent.match?(/\A\d+(\.\d+)?%?\z/)
          invalid!('Write the share as a percentage, such as 25', "rows.#{i}.percent")
        end
        invalid!('Write when it is paid', "rows.#{i}.when") if row['when'].blank?

        Share.new(BigDecimal(percent.delete('%')), row['when'])
      end

      total = shares.sum(&:percent)
      invalid!("The shares add up to #{total.to_s('F').delete_suffix('.0')}%, not 100%", 'rows') unless total == 100

      shares
    end

    def parse_spread(answer, shares)
      answer = answer.to_h
      return if answer['share'].blank?

      share = answer['share'].to_s
      unless share.match?(/\A\d+\z/) && share.to_i.positive? && shares[share.to_i - 1]
        invalid!('Choose one of the shares', 'share')
      end
      invalid!('Write what the agreement calls them', 'label') if answer['label'].blank?
      unless answer['times'].to_s.match?(/\A\d+\z/) && answer['times'].to_i.positive?
        invalid!('Write how many there are, such as 6', 'times')
      end
      invalid!('Write their amount now', 'current') if answer['current'].blank?

      Spread.new(share.to_i, answer['label'], answer['times'].to_i, money(answer['current'], 'current').first,
                 answer['last'].present? ? money(answer['last'], 'last').first : nil)
    end

    # Each line is a term (with a label if given), or something not included: in the whole variation, or in one item.
    def parse_terms(answer, items)
      exclusions = {}
      terms = []

      rows(answer).each_with_index do |row, i|
        invalid!('Write the text, or remove the line', "rows.#{i}.text") if row['text'].blank?
        next if row['text'].match?(NONE)

        case row['kind']
        when 'term'
          terms << { 'label' => row['label'].presence, 'text' => row['text'] }
        when 'not_included'
          (exclusions[nil] ||= []) << row['text']
        when /\Anot_included:(.+)\z/
          name = Regexp.last_match(1)
          item = items.find { |candidate| candidate.name.casecmp?(name) }
          invalid!("No item is called #{name}", "rows.#{i}.kind") unless item

          (exclusions[item.name] ||= []) << row['text']
        else
          invalid!('Choose what the line is', "rows.#{i}.kind")
        end
      end

      [exclusions, terms]
    end

    # The arithmetic: totals, VAT, the payment shares (the rounding remainder on the last share), and the change to
    # the existing instalments a share is spread over (the remainder on the last instalment). Round half up to cents.
    def calculate(answers, vat_rate:)
      cents = ->(value) { value.round(2, BigDecimal::ROUND_HALF_UP) }
      one_time = answers.items.sum(&:one_time)
      monthly = answers.items.sum(&:monthly)

      amounts = answers.shares.map { |share| cents.call(one_time * share.percent / 100) }
      amounts[-1] = one_time - amounts[0..-2].sum if amounts.any?
      answers.shares.each_with_index { |share, index| share.amount = amounts[index] }

      if (spread = answers.spread)
        amount = answers.shares[spread.share - 1].amount
        spread.per = cents.call(amount / spread.times)
        spread.per_last = amount - (spread.per * (spread.times - 1))
        spread.new_amount = spread.current + spread.per
        spread.new_last = (spread.current_last || spread.current) + spread.per_last
      end

      { one_time:, monthly:, vat_rate:, vat_one_time: cents.call(one_time * vat_rate / 100),
        vat_monthly: cents.call(monthly * vat_rate / 100) }
    end

    # VAT is charged at the own profile's rate when the client is in our country, and not otherwise.
    def vat_rate(settings, client)
      own = settings.profile['country']
      own.present? && client.country == own ? settings.vat_rate : BigDecimal('0')
    end

    def monthly_vat(calc, cur)
      calc[:monthly].positive? ? " and #{fmt(calc[:vat_monthly], cur, cents: true)} a month" : ''
    end

    def fmt(amount, currency, cents: false)
      whole = amount.round(2, BigDecimal::ROUND_HALF_UP)
      text = cents || whole.frac.nonzero? ? format('%.2f', whole) : whole.to_i.to_s
      int, dec = text.split('.')

      "#{currency} #{int.reverse.scan(/\d{1,3}/).join(',').reverse}#{".#{dec}" if dec}"
    end

    def percent_text(value) = "#{value.to_s('F').delete_suffix('.0')}%"

    def count_word(number) = NUMBER_WORDS[number] || number.to_s

    def title_case(name) = name.to_s.split.map { |w| w.match?(/\A[a-z]/) ? w.capitalize : w }.join(' ')

    def join_names(names) = names.size > 1 ? "#{names[0..-2].join(', ')} and #{names.last}" : names.first.to_s

    def cover_title(names) = join_names(names.map { |n| title_case(n) })

    # A name that already ends with a full stop ("L.L.C.") ends the sentence itself.
    def stop(text) = text.to_s.end_with?('.') ? text.to_s : "#{text}."

    # Render once: the number, the wording, the PDF, and the facts the rest of the desk works from.
    def render!(document, settings)
      client = document.client
      raise Invalid, 'Choose the client of this variation' unless client

      profile = settings.profile
      answers = answers(document)
      calc = calculate(answers, vat_rate: vat_rate(settings, client))
      today = Time.current.in_time_zone(document.account.timezone).to_date

      document.with_lock do
        if document.number.blank?
          prefix = [profile['document_prefix'], 'VAR'].compact_blank.join('-')
          document.update!(number: NumberRegister.next!(account_id: document.account_id, prefix:, year: today.year),
                           revision: 'R0')
          document.log!("number issued: #{document.number}", actor: 'system')
        end
      end

      notes = VariationWording.call(answers, client:)
      variation_no = format('%02d', sequence(document, answers.parent['reference']))
      reference = "#{document.number}-#{document.revision}"
      names = answers.items.map(&:name)
      title = "Variation #{variation_no} · #{cover_title(names)}"

      data = pdf_data(document, settings, client, answers, calc, reference:, variation_no:, today:, title:)
      pdf, fields = VariationPdf.call(data)

      ApplicationRecord.transaction do
        filename = "#{reference} #{cover_title(names)}.pdf".tr('/', '-')
        document.update!(title:, filename:, file_sha256: Digest::SHA256.hexdigest(pdf))
        document.source_file.attach(io: StringIO.new(pdf), filename:, content_type: 'application/pdf')
        store_facts!(document, settings, client, answers, calc, reference:, today:, title:, fields:, notes:,
                                                                data:)
      end

      document.log!('document written from the answers', actor: 'system',
                                                         data: { reference:, pages: Pdfium::Document.open_bytes(pdf)
                                                                                                     .page_count })
      document
    end

    # The number of this variation under its agreement: the variations made here for the same agreement, plus one.
    def sequence(document, parent_reference)
      earlier = Document.where(account_id: document.account_id, source: 'generated', doc_type: 'variation')
                        .where.not(state: 'archived').where(id: ...document.id)

      earlier.count { |d| given(d)['parent'].to_h['reference'].to_s.casecmp?(parent_reference) } + 1
    end

    def place(name, place) = place.present? ? "#{name} (#{place})" : name

    def pdf_data(_document, settings, client, answers, calc, reference:, variation_no:, today:, title:)
      profile = settings.profile
      own_name = profile['legal_name'] || settings.own_names.first
      cur = answers.currency
      parent = answers.parent
      names = answers.items.map(&:name)
      count = answers.items.size
      licence = " (licence #{profile['licence_number']})" if profile['licence_number'].present?

      sections = []
      sections << { title: "#{count_word(count).capitalize} addition#{'s' if count > 1} to our agreement",
                    blocks: [{ type: :para, text: "This document adds #{count_word(count)} item#{'s' if count > 1} " \
                                                  "to Agreement #{parent['reference']} of #{parent['date']}:" },
                             { type: :bullets, items: answers.items.map { |i| "#{i.name}: #{i.note_summary}" } },
                             (if count > 1
                                { type: :para,
                                  text: "They are paid together, on the terms in section #{count + 3}." }
                              end)].compact }

      answers.items.each do |item|
        blocks = [{ type: :para, text: item.what }]
        blocks << { type: :para, label: 'Where it stands.', text: item.status } if item.status.present?
        blocks << { type: :para, label: 'Acceptance.', text: item.acceptance } if item.acceptance.present?
        Array(answers.exclusions[item.name]).each do |text|
          blocks << { type: :para, label: 'Not included.', text: text.upcase_first }
        end
        sections << { title: item.name, blocks: }
      end

      price_rows = answers.items.map do |item|
        monthly = item.monthly.zero? ? (item.note || '-') : fmt(item.monthly, cur)
        monthly = "#{fmt(item.monthly, cur)}. #{item.note}" if item.note.present? && !item.monthly.zero?
        [item.name, fmt(item.one_time, cur), monthly]
      end
      price_rows << ['Total', fmt(calc[:one_time], cur), fmt(calc[:monthly], cur)]
      price_blocks = [{ type: :table, header: ['Item', 'One-time', 'Per month'], rows: price_rows,
                        widths: [118, 84, -1], total: true }]
      if calc[:vat_rate].positive?
        price_blocks << { type: :para, text: "VAT at #{percent_text(calc[:vat_rate])} is added: " \
                                             "#{fmt(calc[:vat_one_time], cur, cents: true)} on the one-time total" \
                                             "#{monthly_vat(calc, cur)}." }
      end
      if answers.monthly
        text = answers.monthly
        text = "The #{fmt(calc[:monthly], cur)} per month #{text}" if text.match?(/\A[a-z]/)
        price_blocks << { type: :para, text: }
      end
      sections << { title: 'Price', blocks: price_blocks }

      unless answers.shares.empty? || calc[:one_time].zero?
        rows = answers.shares.map do |share|
          amount = fmt(share.amount, cur, cents: true)
          spread = answers.spread if answers.spread && answers.shares[answers.spread.share - 1] == share
          if spread && spread.per == spread.per_last
            amount = "#{amount} (#{fmt(spread.per, cur,
                                       cents: true)} with each)"
          end
          [share.when, percent_text(share.percent), amount]
        end
        blocks = [{ type: :para, text: "The #{fmt(calc[:one_time], cur)} is paid in #{count_word(rows.size)} " \
                                       "part#{'s' if rows.size > 1}:" },
                  { type: :table, header: %w[When Share Amount], rows:, widths: [-1, 60, 150], total: false }]
        if (s = answers.spread)
          last = s.new_last == s.new_amount ? '' : " (the last one #{fmt(s.new_last, cur, cents: true)})"
          blocks << { type: :para, text: "Each #{s.label} therefore goes from #{fmt(s.current, cur, cents: true)} " \
                                         "to #{fmt(s.new_amount, cur, cents: true)}#{last}. Nothing else in the " \
                                         'payment schedule changes.' }
        end
        sections << { title: 'Payment', blocks: }
      end

      term_blocks = [{ type: :para, text: "This variation forms part of Agreement #{parent['reference']}. " \
                                          'Everything else in the agreement stays the same.' }]
      answers.terms.each do |t|
        term_blocks << { type: :para, label: t['label'] && "#{t['label']}.", text: t['text'].upcase_first }
      end
      Array(answers.exclusions[nil]).each do |text|
        term_blocks << { type: :para, label: 'Not included.', text: text.upcase_first }
      end
      sections << { title: 'Terms', blocks: term_blocks }

      {
        eyebrow: 'Quotation and variation', title_line: "Variation #{variation_no}",
        title_lines: wrap_title(cover_title(names)),
        subtitle: "Quotation and written variation to the #{parent['title']} #{parent['reference']} of " \
                  "#{parent['date']}",
        prepared_for: place(client.legal_name, client.address), prepared_by: place(own_name, profile['place']),
        reference:, date_text: today.strftime('%-d %B %Y'), status: 'Quotation, for signature',
        running_title: title, footer_left: "#{own_name} · Private & Confidential",
        opening: "This variation is made under #{parent['clauses']} of Agreement #{parent['reference']} between " \
                 "#{own_name}#{licence} and #{stop(client.legal_name)} It adds #{count_word(count)} " \
                 "item#{'s' if count > 1} to the agreement and sets #{count > 1 ? 'their' : 'its'} price and payment.",
        sections:,
        signature: signature_data(settings, client, own_name)
      }
    end

    # Two lines at most on the cover, broken at a word near the middle.
    def wrap_title(text)
      return [text] if text.size <= 28

      words = text.split
      best = (1...words.size).min_by { |i| (words[0...i].join(' ').size - (text.size / 2)).abs }
      [words[0...best].join(' '), words[best..].join(' ')]
    end

    # Australia: execution by the company under s127 (two directors, or a director and the secretary).
    def signature_data(settings, client, own_name)
      profile = settings.profile
      signers = client_signers(client)
      execution =
        if client.country == 'AU'
          "Executed by #{client.legal_name} under section 127 of the Corporations Act 2001 (Cth) by two directors, " \
            'or a director and company secretary. Electronic signatures are accepted.'
        else
          'Signed by the authorised representatives of the Parties. Electronic signatures are accepted.'
        end

      { heading: 'Signed for and on behalf of the Parties', execution:,
        own: { party: own_name,
               signers: [{ name: profile['signer_name'], title: profile['signer_title'], slot: 'own-1' }] },
        client: { party: client.legal_name,
                  signers: signers.each_with_index.map do |s, i|
                    { name: s['name'], title: s['role'], slot: "p2-#{i + 1}" }
                  end } }
    end

    def client_signers(client)
      known = client.signers.first(client.country == 'AU' ? 2 : 1)
      return known if known.size == (client.country == 'AU' ? 2 : 1)

      wanted = client.country == 'AU' ? 2 : 1
      known + Array.new(wanted - known.size) { { 'name' => nil, 'role' => client.country == 'AU' ? 'Director' : nil } }
    end

    # What the desk works from afterwards: the parties and signers (for Desk::Signers), the reference and dates, every
    # computed amount (origin rule), the wording (origin ai), and where the signing boxes are.
    def store_facts!(document, settings, client, answers, calc, reference:, today:, title:, fields:, notes:, data:)
      profile = settings.profile
      run_id = SecureRandom.uuid
      cur = answers.currency
      add = lambda do |key, value, origin: 'rule', status: 'confirmed'|
        Fact.create!(account_id: document.account_id, document:, key:, value:, origin:, status:, run_id:,
                     method: origin == 'ai' ? AiClient.model : 'variation')
      end

      document.facts.current.where.not(key: 'answer').update_all(status: 'superseded', updated_at: Time.current)

      add.call('document_type', { 'value' => 'variation' })
      add.call('title', { 'value' => title })
      add.call('reference', { 'value' => reference })
      add.call('date', { 'label' => 'Document date', 'as_written' => data[:date_text], 'iso' => today.iso8601 })
      add.call('party', { 'key' => 'p1', 'legal_name' => profile['legal_name'] || settings.own_names.first,
                          'role' => 'Our company', 'country' => profile['country'], 'address' => profile['address'],
                          'tax_number' => profile['tax_number'], 'own' => true }.compact, origin: 'register')
      add.call('party', { 'key' => 'p2', 'legal_name' => client.legal_name, 'role' => 'Client',
                          'country' => client.country, 'address' => client.address,
                          'tax_number' => client.tax_number, 'own' => false }.compact, origin: 'register')
      add.call('signer', { 'party_key' => 'p1', 'name' => profile['signer_name'],
                           'title' => profile['signer_title'] }.compact, origin: 'register')
      data[:signature][:client][:signers].each do |s|
        add.call('signer', { 'party_key' => 'p2', 'name' => s[:name], 'title' => s[:title] }.compact,
                 origin: 'register')
      end

      answers.items.each do |item|
        add.call('amount', { 'label' => "#{item.name}, one-time", 'as_written' => fmt(item.one_time, cur),
                             'amount' => item.one_time.to_s('F'), 'currency' => cur })
        next if item.monthly.zero?

        add.call('amount', { 'label' => "#{item.name}, per month", 'as_written' => fmt(item.monthly, cur),
                             'amount' => item.monthly.to_s('F'), 'currency' => cur })
      end
      add.call('amount', { 'label' => 'Total one-time', 'as_written' => fmt(calc[:one_time], cur),
                           'amount' => calc[:one_time].to_s('F'), 'currency' => cur })
      add.call('amount', { 'label' => 'Total per month', 'as_written' => fmt(calc[:monthly], cur),
                           'amount' => calc[:monthly].to_s('F'), 'currency' => cur })
      add.call('amount', { 'label' => "VAT at #{percent_text(calc[:vat_rate])} on the one-time total",
                           'as_written' => fmt(calc[:vat_one_time], cur, cents: true),
                           'amount' => calc[:vat_one_time].to_s('F'), 'currency' => cur })
      answers.shares.each do |share|
        add.call('amount', { 'label' => "Payment: #{share.when} (#{percent_text(share.percent)})",
                             'as_written' => fmt(share.amount, cur, cents: true), 'amount' => share.amount.to_s('F'),
                             'currency' => cur })
      end
      if (s = answers.spread)
        add.call('amount', { 'label' => "Each #{s.label}, new amount",
                             'as_written' => fmt(s.new_amount, cur, cents: true),
                             'amount' => s.new_amount.to_s('F'), 'currency' => cur })
        add.call('amount', { 'label' => "Last #{s.label}, new amount",
                             'as_written' => fmt(s.new_last, cur, cents: true),
                             'amount' => s.new_last.to_s('F'), 'currency' => cur })
      end

      answers.items.each do |item|
        add.call('wording', { 'item' => item.name, 'what' => item.what, 'status' => item.status,
                              'acceptance' => item.acceptance }.compact, origin: 'ai', status: 'candidate')
      end
      notes.each { |note| add.call('wording_note', { 'note' => note }) }
      add.call('layout', { 'fields' => fields })
    end
  end
end
# rubocop:enable Metrics

# frozen_string_literal: true

# Contract Desk, phase 1b: the numbering register, the arithmetic of a variation, a variation written from its answers,
# our own company (profile and the own-signer rule), and the nightly check. The AI is never called (fixtures).
RSpec.describe 'Contract Desk contracts', :desk do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before do
    desk_ai_configured!
    desk_settings_for(account)
  end

  def answer_variation(document, client, answers = DeskSpecHelpers::VARIATION_ANSWERS)
    document.questions.order(:position).each do |question|
      text = question.key == 'variation:client' ? client.id.to_s : answers.fetch(question.key)
      Desk::Questions.answer!(question.reload, text, user)
    end
  end

  def pdf_text(data)
    pdf = Pdfium::Document.open_bytes(data)
    Array.new(pdf.page_count) { |i| pdf.get_page(i).text }.join(' ').gsub(/[[:space:]]+/, ' ')
  ensure
    pdf&.close
  end

  describe 'the arithmetic of a variation (code, never the AI)' do
    let(:client) { Desk::Client.new(legal_name: 'Client Co', country: 'AU', default_currency: 'AUD') }

    # The rows as the form sends them: items [name, one-time, monthly(, currency)], shares [percent, when].
    def items(*rows)
      { 'rows' => rows.map do |name, one_time, monthly, currency = 'AUD'|
        { 'name' => name, 'one_time' => one_time, 'currency' => currency, 'monthly' => monthly }
      end }
    end

    def shares(*rows) = { 'rows' => rows.map { |percent, said| { 'percent' => percent, 'when' => said } } }

    def answers(items:, payment:, spread: {})
      parsed, currency = Desk::Variation.parse_items(items)
      shares = Desk::Variation.parse_payment(payment)
      Desk::Variation::Answers.new(nil, parsed, currency, nil, shares, Desk::Variation.parse_spread(spread, shares),
                                   [], {})
    end

    it 'adds the items, puts the rounding remainder on the last share, and spreads a share over instalments' do
      a = answers(items: items(['One', 'AUD 10,000', '0'], ['Two', '2001', '99.50']),
                  payment: shares(['33', 'On signature'], %w[33 Mid-way], ['34', 'At the end']),
                  spread: { 'share' => '3', 'label' => 'monthly instalment', 'times' => '7', 'current' => '1000.00',
                            'last' => '999.99' })
      calc = Desk::Variation.calculate(a, vat_rate: BigDecimal('0'))

      expect([calc[:one_time], calc[:monthly]]).to eq([BigDecimal('12001'), BigDecimal('99.5')])
      expect(a.shares.map(&:amount)).to eq([BigDecimal('3960.33'), BigDecimal('3960.33'), BigDecimal('4080.34')])
      expect(a.shares.sum(&:amount)).to eq(calc[:one_time])

      spread = a.spread
      expect([spread.per, spread.per_last]).to eq([BigDecimal('582.91'), BigDecimal('582.88')])
      expect((spread.per * 6) + spread.per_last).to eq(a.shares.last.amount)
      expect([spread.new_amount, spread.new_last]).to eq([BigDecimal('1582.91'), BigDecimal('1582.87')])
    end

    it 'charges VAT at the profile rate only for a client in our country, rounded to the cent' do
      settings = Desk::Setting.new(own_profile: { 'country' => 'AE', 'vat_rate' => '5' })
      domestic = Desk::Client.new(country: 'AE')

      expect(Desk::Variation.vat_rate(settings, domestic)).to eq(5)
      expect(Desk::Variation.vat_rate(settings, client)).to eq(0)

      a = answers(items: items(%w[One 1234.57 10.01]), payment: shares(['100', 'On signature']))
      calc = Desk::Variation.calculate(a, vat_rate: BigDecimal('5'))
      expect([calc[:vat_one_time], calc[:vat_monthly]]).to eq([BigDecimal('61.73'), BigDecimal('0.5')])
    end

    it 'refuses answers that do not add up or do not say enough, naming the box' do
      refusal = lambda do |&answer|
        answer.call
      rescue Desk::Questions::Invalid => e
        [e.message, e.field]
      end

      expect(refusal.call { Desk::Variation.parse_payment(shares(%w[50 Now], %w[40 Later])) })
        .to eq(['The shares add up to 90%, not 100%', 'rows'])
      expect(refusal.call { Desk::Variation.parse_items(items(['One', '100', '0', ''])) })
        .to eq(['Choose the currency', 'rows.0.currency'])
      expect(refusal.call { Desk::Variation.parse_items(items(%w[One 100 0], %w[Two 5 0 SAR])) })
        .to eq(['One currency only, please (SAR, AUD)', 'rows.1.currency'])
      expect(refusal.call { Desk::Variation.parse_items(items(%w[One 100 0], ['Two', 'SAR 5', '0'])) })
        .to eq(['One currency only, please (SAR, AUD)', 'rows.1.currency'])
      expect(refusal.call { Desk::Variation.parse_items(items(%w[One ten 0])) })
        .to eq(['"ten" is not a price: write it like AUD 10000 or 10,000.00', 'rows.0.one_time'])
      expect(refusal.call { Desk::Variation.parse_items(items(%w[One 1 0], %w[one 2 0])) })
        .to eq(['Two items have the same name', 'rows.1.name'])
      expect(refusal.call { Desk::Variation.parse_items(items(['One', '1', ''])) })
        .to eq(['Write the monthly price, or 0', 'rows.0.monthly'])
      expect(refusal.call do
        Desk::Variation.parse_parent('title' => 'Agreement', 'reference' => 'A-1', 'date' => 'sometime',
                                     'clauses' => 'clause 2')
      end).to eq(['Write the date, such as 4 August 2026', 'date'])
      expect(refusal.call do
        Desk::Variation.parse_spread({ 'share' => '4', 'label' => 'instalments', 'times' => '2', 'current' => '100' },
                                     Desk::Variation.parse_payment(shares(%w[100 Now])))
      end).to eq(['Choose one of the shares', 'share'])
      expect(refusal.call do
        Desk::Variation.parse_terms({ 'rows' => [{ 'kind' => 'term', 'text' => 'ok' },
                                                 { 'kind' => 'not_included:Nothing', 'text' => 'x' }] }, [])
      end).to eq(['No item is called Nothing', 'rows.1.kind'])
      expect(Desk::Variation.clean('rows' => [{ 'name' => ' A ', 'currency' => 'AUD' }, { 'currency' => 'AUD' }]))
        .to eq('rows' => [{ 'name' => 'A', 'currency' => 'AUD' }]) # a row with only its currency set is no row
      expect(Desk::Variation.fmt(BigDecimal('15000'), 'AUD')).to eq('AUD 15,000')
      expect(Desk::Variation.fmt(BigDecimal('6916.65'), 'AUD', cents: true)).to eq('AUD 6,916.65')
    end
  end

  describe 'a variation written from its answers' do
    let(:client) { saffron_client(account).tap { |c| c.update!(default_currency: 'AED') } }

    it 'asks eight questions, numbers it from the register, computes it, words it, draws it, and stops at ready' do
      stub_ai('variation-wording-uae-1')
      Desk::NumberRegister.create!(account_id: account.id, prefix: 'NW-VAR', year: Time.current.year, last_number: 1)
      document = Desk::Variation.start!(account:, user:)

      expect(document.questions.count).to eq(8)
      expect(document.state).to eq('waiting_for_you')

      answer_variation(document, client)
      expect(document.reload.state).to eq('preparing')
      run_pipeline(document)

      expect(document.state).to eq('ready_to_send'), document.last_error
      expect(document.number).to eq("NW-VAR-#{Time.current.year}-002")
      expect(document.title).to eq('Variation 01 · Driver Mobile App and Route Optimisation')

      text = pdf_text(document.source_file.download)
      expect(text).to include("NW-VAR-#{Time.current.year}-002-R0", 'AED 18,500', 'AED 450', 'VAT at 5%', 'AED 925.00',
                              'AED 9,250.00', 'This variation forms part of Agreement SA-2026-014',
                              'licence 1234567.01', 'Sam Example', 'Layla Haddad', 'Operations Director')
      expect(text).to include('Drivers can view their route') # the AI wording, checked by code

      amounts = document.facts.current.where(key: 'amount').to_h { |f| [f.value['label'], f.value['amount']] }
      expect(amounts).to include('Total one-time' => '18500.0', 'Total per month' => '450.0',
                                 'VAT at 5% on the one-time total' => '925.0')

      template = document.template
      kinds = template.fields.map do |f|
        [template.submitters.find do |s|
          s['uuid'] == f['submitter_uuid']
        end['name'], f['type']]
      end
      expect(kinds).to contain_exactly([DeskSpecHelpers::OWN, 'date'], [DeskSpecHelpers::OWN, 'signature'],
                                       ['Saffron Dune Logistics L.L.C. - Operations Director', 'date'],
                                       ['Saffron Dune Logistics L.L.C. - Operations Director', 'signature'])
      expect(template.fields.map { |f| f['areas'][0]['page'] }.uniq).to eq([3])
      expect(Digest::SHA256.hexdigest(template.documents.first.download)).to eq(document.file_sha256)
      expect(document.submission.submitters.map(&:email)).to eq(['sam@northwind.example', 'layla@saffron.example'])
      expect(Sidekiq::Worker.jobs.pluck('class')).not_to include('SendSubmitterInvitationEmailJob')
    end

    it 'refuses a wrong answer in the box, with the reason' do
      document = Desk::Variation.start!(account:, user:)
      Desk::Questions.answer!(document.questions.find_by(key: 'variation:client'), client.id.to_s, user)

      payment = { 'rows' => [{ 'percent' => '60', 'when' => 'Now' }, { 'percent' => '60', 'when' => 'Later' }] }
      expect { Desk::Questions.answer!(document.questions.find_by(key: 'variation:payment'), payment, user) }
        .to raise_error(Desk::Questions::Invalid, /120%/)
      expect(document.questions.find_by(key: 'variation:payment')).to be_open
    end

    it 'prints the notes as written, and says so, when the AI wording adds a figure' do
      reply = JSON.parse(ai_reply('variation-wording-uae-1'))
      content = JSON.parse(reply['choices'][0]['message']['content'])
      content['items'][0]['what'] = 'Drivers see their route on their phones, with support 24/7.'
      reply['choices'][0]['message']['content'] = content.to_json
      stub_ai(reply)
      document = Desk::Variation.start!(account:, user:)

      answer_variation(document, client)
      run_pipeline(document)

      text = pdf_text(document.source_file.download)
      expect(text).not_to include('24/7')
      expect(text).to include('Drivers see their route, scan deliveries and capture proof of delivery on their phones.')
      expect(document.facts.current.where(key: 'wording_note').pick(:value)['note'])
        .to match(/Driver mobile app: the AI wording added 24/)
    end

    it 'still writes the document from the notes when the AI cannot be reached' do
      stub_request(:post, DeskSpecHelpers::AI_URL).to_return(status: 503)
      document = Desk::Variation.start!(account:, user:)

      answer_variation(document, client)
      run_pipeline(document)

      expect(document.state).to eq('ready_to_send')
      expect(document.facts.current.where(key: 'wording_note').pick(:value)['note']).to match(/could not word/)
    end
  end

  describe 'our own company' do
    it 'never asks a question about us: a gap about our company is dropped, our details come from the profile' do
      reply = JSON.parse(ai_reply('b-client-contract-ksa-1'))
      content = JSON.parse(reply['choices'][0]['message']['content'])
      content['gaps'] = [{ 'key' => 'second_party_address',
                           'question' => "What is the Second Party's registered address?" },
                         { 'key' => 'own_tax', 'question' => 'What is the tax number of Northwind Studio FZE?' },
                         { 'key' => 'commencement', 'question' => 'What is the commencement date?' }]
      reply['choices'][0]['message']['content'] = content.to_json
      stub_ai(reply)
      Desk::Client.create!(account_id: account.id, legal_name: 'Najd Falcon Drilling Services Co.',
                           tax_number: '300987654300003', source: 'Added by hand',
                           signers: [{ name: 'Faisal Al-Qahtani', email: 'faisal@najd.example' }])
      document = desk_upload(account:, user:, pdf: synthetic_pdf(:client_contract), filename: 'contract.pdf')

      run_pipeline(document)

      expect(document.questions.pluck(:prompt)).to contain_exactly(a_string_matching(/commencement date/))
    end

    it 'flags, never asks, where a document differs from the profile or is dated after our licence' do
      Desk::Setting.for(account).update!(own_profile: DeskSpecHelpers::PROFILE.merge(
        'address' => 'Business Bay, Abu Dhabi', 'licence_expiry' => '2026-10-01'
      ))
      stub_ai('a-service-agreement-uae-1')
      saffron_client(account)
      document = desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement))

      run_pipeline(document)

      notes = Desk::OwnCheck.notes(document)
      expect(notes).to include(a_string_matching(/gives our address as "Sharjah, United Arab Emirates"/),
                               a_string_matching(/Our licence expires on 1 October 2026/))
      expect(document.questions.pluck(:kind)).to eq(['acknowledge'])
    end
  end

  describe 'the own-signer rule' do
    let(:client) { saffron_client(account) }

    def ready_variation
      stub_ai('variation-wording-uae-1')
      document = Desk::Variation.start!(account:, user:)
      answer_variation(document, client)
      run_pipeline(document)
      raise "not ready: #{document.last_error}" unless document.state == 'ready_to_send'

      document
    end

    it 'lets only the person the document names sign for us; anyone else sends, and that person is invited' do
      sam = with_two_factor(create(:user, account:, first_name: 'Sam', last_name: 'Example',
                                          email: 'sam@northwind.example'))
      document = ready_variation
      save_signature!(user)

      Desk::Sender.call(document, approval_for(with_two_factor(user)))

      own = document.submission.submitters.find_by(email: sam.email)
      expect(document.reload.state).to eq('sent')
      expect(own.reload.completed_at).to be_nil
      expect(own.attachments).to be_empty
      expect(SendSubmitterInvitationEmailJob.jobs.pluck('args').flatten.pluck('submitter_id')).to eq([own.id])
      expect(document.events.pluck(:action)).to include(/approved and sent by/)
    end

    it 'signs for us at the moment of approval when the named person says Yes' do
      sam = with_two_factor(create(:user, account:, first_name: 'Sam', last_name: 'Example',
                                          email: 'sam@northwind.example'))
      document = ready_variation
      save_signature!(sam)

      Desk::Sender.call(document, approval_for(sam))

      own = document.submission.submitters.find_by(email: sam.email)
      expect(own.reload.completed_at).to be_present
      expect(document.events.pluck(:action)).to include(/approved and signed by Sam Example/)
    end

    it 'stops on configuration, never asks, when the named signer cannot be reached' do
      Desk::Setting.for(account).update!(own_profile: DeskSpecHelpers::PROFILE.except('signer_email'))
      stub_ai('variation-wording-uae-1')
      document = Desk::Variation.start!(account:, user:)

      answer_variation(document, client)
      run_pipeline(document)

      expect(document.state).to eq('waiting_for_you')
      expect(document.last_error).to match(/Sam Example signs for Northwind Studio FZE but has no e-mail address/)
      expect(document.questions.open).to be_empty
    end
  end

  describe 'the nightly check' do
    let(:document) { desk_ready_document(account:, user:) }

    before do
      create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))
    end

    def send_it
      save_signature!(user)
      Desk::Sender.call(document, approval_for(with_two_factor(user)))
      document.reload
    end

    it 'starts a follow-up that stopped again, once, and finds nothing to do the second time' do
      send_it
      document.update!(checked_at: 2.hours.ago, follow_up_token: 'lost')

      Desk::Automation.run { Desk::Reconcile.call }
      token = document.reload.follow_up_token
      Desk::Automation.run { Desk::Reconcile.call }

      expect(token).not_to eq('lost')
      expect(document.reload.follow_up_token).to eq(token)
      expect(document.events.where(action: 'follow-up started again by the nightly check').count).to eq(1)
      expect(Desk::FollowUpJob.jobs.pluck('args').flatten.pluck('token')).to include(token)
    end

    it 'brings a document signed while nobody was looking into the register' do
      send_it
      theirs = document.submission.submitters.find_by(email: 'layla@saffron.example')
      signature = ActiveStorage::Attachment.create!(
        blob: ActiveStorage::Blob.create_and_upload!(io: Rails.root.join('spec/fixtures/sample-image.png').open,
                                                     filename: 's.png', content_type: 'image/png'),
        name: 'attachments', record: theirs
      )
      field = document.submission.template_fields.find do |f|
        f['submitter_uuid'] == theirs.uuid && f['type'] == 'signature'
      end
      request = ActionDispatch::TestRequest.create('REQUEST_METHOD' => 'POST')
      request.env['warden'] = instance_double(Warden::Proxy, user: nil)
      values = { field['uuid'] => signature.uuid }
      Submitters::SubmitValues.call(theirs, ActionController::Parameters.new(values:,
                                                                             completed: 'true'), request)

      Desk::Automation.run { Desk::Reconcile.call }

      expect(document.reload.state).to eq('signed')
      expect(document.signed_pdf.attachment.preview_images).to exist
    end

    it 'queues a preparation that stopped' do
      stuck = desk_upload(account:, user:, pdf: synthetic_pdf(:client_contract))
      stuck.update_columns(updated_at: 2.hours.ago)

      Desk::Automation.run { Desk::Reconcile.call }

      expect(Desk::ProcessDocumentJob.jobs.pluck('args').flatten.pluck('document_id')).to include(stuck.id)
    end

    it 'runs once a night, in one chain only' do
      store = fake_redis!
      allow(Desk::Reconcile).to receive(:call).and_return({})

      Desk::ReconcileJob.start!
      token = store[Desk::ReconcileJob::TOKEN_KEY]
      Desk::ReconcileJob.new.perform('token' => 'an old chain')
      Desk::ReconcileJob.new.perform('token' => token)
      Desk::ReconcileJob.new.perform('token' => token)

      expect(Desk::Reconcile).to have_received(:call).once
      expect(Desk::ReconcileJob.jobs.pluck('args').flatten.pluck('token').uniq).to eq([token])
    end
  end
end

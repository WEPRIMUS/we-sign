# frozen_string_literal: true

# Contract Desk specs: the AI is never called; its replies are recorded fixtures (spec/fixtures/desk/ai), served at a
# fake endpoint. Synthetic PDFs are made on the fly (Desk::SyntheticDocuments) with a fictional own party.
module DeskSpecHelpers
  AI_URL = 'https://ai.example/v1/chat/completions'
  OWN = 'Northwind Studio FZE'
  # What the flow specs answer: "noted" to a gap in the document, "yes" to a new client.
  ANSWERS = { 'acknowledge' => '', 'confirm_client' => 'Yes' }.freeze

  # The answers of a synthetic variation (for the client saffron_client).
  # As the question box sends them: the form questions as hashes (rows where there are rows), the rest as text.
  VARIATION_ANSWERS = {
    'variation:parent' => { 'title' => 'Services Agreement', 'reference' => 'SA-2026-014', 'date' => '12 October 2026',
                            'clauses' => 'clause 9' },
    'variation:items' => { 'rows' => [
      { 'name' => 'Driver mobile app', 'one_time' => '12000', 'currency' => 'AED', 'monthly' => '450', 'note' => '' },
      { 'name' => 'Route optimisation', 'one_time' => '6500', 'currency' => 'AED', 'monthly' => '0',
        'note' => 'Included in the monthly support of the platform.' }
    ] },
    'variation:scope' => { 'rows' => [
      { 'name' => 'Driver mobile app',
        'what' => 'drivers see their route, scan deliveries and capture proof of delivery on their phones',
        'status' => 'designed, build starts on signature',
        'acceptance' => 'a driver completes a route end to end and the office sees each proof' },
      { 'name' => 'Route optimisation', 'what' => "plans the day's stops in the best order for each vehicle",
        'status' => 'prototype tested on two routes',
        'acceptance' => "the planner runs a full day's plan for all vehicles" }
    ] },
    'variation:monthly' => 'covers hosting of the app, updates and support. It starts on the first day of the month ' \
                           'after go-live.',
    'variation:payment' => { 'rows' => [{ 'percent' => '50', 'when' => 'On signature of this variation' },
                                        { 'percent' => '50', 'when' => 'On acceptance of both items' }] },
    'variation:instalments' => { 'share' => '' },
    'variation:terms' => { 'rows' => [
      { 'kind' => 'not_included:Driver mobile app', 'label' => '', 'text' => 'hardware and phone contracts.' },
      { 'kind' => 'term', 'label' => 'Warranty', 'text' => '90 days from acceptance, as for the platform.' }
    ] }
  }.freeze

  def desk_ai_configured!
    allow(Desk::AiClient).to receive_messages(
      settings: { endpoint: 'https://ai.example/v1', model: 'test-vision', key: 'test-key', allow_internal: false },
      retry_wait: 0
    )
  end

  def ai_reply(name) = Rails.root.join("spec/fixtures/desk/ai/#{name}.json").read

  # The replies in the order the desk asks.
  def stub_ai(*replies)
    stub_request(:post, AI_URL).to_return(*replies.map do |r|
      { status: 200, body: r.is_a?(String) ? ai_reply(r) : r.to_json }
    end)
  end

  # The synthetic documents the AI replies were recorded from (made by Desk::SyntheticDocuments with OWN).
  SYNTHETIC = { service_agreement: 'a-service-agreement-uae', client_contract: 'b-client-contract-ksa',
                scanned_letter: 'c-scanned-letter-au' }.freeze

  def synthetic_pdf(kind) = Rails.root.join("spec/fixtures/desk/#{SYNTHETIC.fetch(kind)}.pdf").binread

  def desk_upload(account:, user:, pdf:, filename: 'document.pdf')
    document = Desk::Document.create!(account_id: account.id, created_by_user: user, filename:,
                                      title: File.basename(filename, '.pdf'), file_sha256: Digest::SHA256.hexdigest(pdf))
    document.source_file.attach(io: StringIO.new(pdf), filename:, content_type: 'application/pdf')
    document
  end

  def run_pipeline(document)
    Desk::Automation.run { Desk::Pipeline.call(document) }
    document.reload
  end

  PROFILE = { 'legal_name' => OWN, 'place' => 'Example Free Zone, UAE', 'address' => 'Example Free Zone, Sharjah, UAE',
              'country' => 'AE', 'licence_number' => '1234567.01', 'licence_expiry' => '2030-12-31', 'vat_rate' => '5',
              'signer_name' => 'Sam Example', 'signer_title' => 'Manager', 'signer_email' => 'sam@northwind.example',
              'document_prefix' => 'NW' }.freeze

  def desk_settings_for(account, **attrs)
    Desk::Setting.for(account).tap { |s| s.update!(own_party_names: [OWN], own_profile: PROFILE, **attrs) }
  end

  # The synthetic agreement (a), read, its client in the register and its one gap answered: ready to send.
  def desk_ready_document(account:, user:)
    stub_ai('a-service-agreement-uae-1')
    saffron_client(account) unless Desk::Client.match(account.id, legal_name: 'Saffron Dune Logistics L.L.C.')
    document = desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement), filename: 'agreement.pdf')
    run_pipeline(document)
    document.questions.open.each { |q| Desk::Questions.answer!(q, '', user) }
    run_pipeline(document)
    raise "not ready: #{document.state} #{document.last_error}" unless document.state == 'ready_to_send'

    document
  end

  # A fake Sidekiq.redis for the nightly check's token and once-a-night key.
  def fake_redis!
    store = {}
    redis = Object.new
    redis.define_singleton_method(:call) do |command, key, value = nil, *options|
      case command
      when 'GET' then store[key]
      when 'SET'
        next nil if options.include?('NX') && store.key?(key)

        store[key] = value
        'OK'
      end
    end
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    store
  end

  def save_signature!(user)
    blob = ActiveStorage::Blob.create_and_upload!(io: Rails.root.join('spec/fixtures/sample-image.png').open,
                                                  filename: 'signature.png', content_type: 'image/png')
    attachment = ActiveStorage::Attachment.create!(blob:, name: 'signature', record: user)
    UserConfig.create!(user:, key: UserConfig::SIGNATURE_KEY, value: attachment.uuid)
  end

  def approval_for(user)
    request = ActionDispatch::TestRequest.create('REQUEST_METHOD' => 'POST', 'REMOTE_ADDR' => '203.0.113.7')
    request.env['warden'] = instance_double(Warden::Proxy, user: user)

    Desk::Approval.from_request!(request:, user:, true_user: user)
  end

  def with_two_factor(user)
    user.update!(otp_required_for_login: true, otp_secret: User.generate_otp_secret)
    user
  end

  def saffron_client(account, with_email: true)
    Desk::Client.create!(account_id: account.id, legal_name: 'Saffron Dune Logistics L.L.C.', country: 'AE',
                         tax_number: '100234567800003', source: 'Added by hand',
                         signers: [{ name: 'Layla Haddad', role: 'Operations Director',
                                     email: (with_email ? 'layla@saffron.example' : nil) }])
  end
end

RSpec.configure do |config|
  config.include DeskSpecHelpers, desk: true
end

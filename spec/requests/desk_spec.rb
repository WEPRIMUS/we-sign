# frozen_string_literal: true

# Contract Desk through its pages: intake, separation of accounts, "Yes, send" (the only path that sends), the
# follow-up to the signed copy.
RSpec.describe 'Contract Desk', :desk do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before do
    desk_ai_configured!
    desk_settings_for(account)
  end

  def ready_document = desk_ready_document(account:, user:)

  describe 'intake' do
    before { sign_in(user) }

    it 'makes one document per file: the same file again opens the first one' do
      file = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/desk/a-service-agreement-uae.pdf'),
                                          'application/pdf')

      post '/desk/uploads', params: { file: }
      first = Desk::Document.sole
      post '/desk/uploads', params: { file: }

      expect(Desk::Document.count).to eq(1)
      expect(response).to redirect_to("/desk/documents/#{first.uuid}")
      expect(Desk::ProcessDocumentJob.jobs.size).to eq(1)
      expect(first.events.pluck(:action)).to eq(['intake: uploaded'])
    end

    it 'takes only a PDF' do
      post '/desk/uploads', params: { file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'),
                                                                         'image/png') }

      expect(Desk::Document.count).to eq(0)
      expect(flash[:alert]).to match(/PDF/)
    end
  end

  describe 'the pages' do
    it 'renders every desk page for a prepared document' do
      document = ready_document
      question = document.questions.first
      sign_in(user)

      ['/desk', '/desk/uploads/new', '/desk/documents', '/desk/documents?state=out&q=agreement',
       "/desk/documents/#{document.uuid}", "/desk/documents/#{document.uuid}/review",
       "/desk/questions/#{question.id}", '/desk/clients', "/desk/clients/#{document.client_id}",
       "/desk/clients/#{document.client_id}/edit", '/desk/clients/new', '/desk/settings/edit'].each do |path|
        get path
        expect(response).to have_http_status(:ok), path
      end

      get "/desk/documents/#{document.uuid}/review"
      expect(response.body).to include('Can I send it?', 'Yes, send', 'Fix something', 'layla@saffron.example')
    end
  end

  describe 'a new contract' do
    it 'starts from the home page, asks one question at a time, and states the own-signer rule on the review' do
      stub_ai('variation-wording-uae-1')
      client = saffron_client(account)
      create(:user, account:, first_name: 'Sam', last_name: 'Example', email: 'sam@northwind.example')
      sign_in(user)

      get '/desk/contracts/new'
      expect(response.body).to include('Quotation and variation')
      post '/desk/contracts'
      document = Desk::Document.sole
      expect(response).to redirect_to("/desk/questions/#{document.questions.find_by(position: 0).id}")

      document.questions.order(:position).each do |question|
        get "/desk/questions/#{question.id}"
        expect(response).to have_http_status(:ok)
        answer = question.kind == 'choose_client' ? client.id : DeskSpecHelpers::VARIATION_ANSWERS.fetch(question.key)
        patch "/desk/questions/#{question.id}", params: { answer: }
        expect(flash[:alert]).to be_nil, flash[:alert]
        expect(response).to be_redirect, response.body[/text-red-600">[^<]+/] # a refused form comes back as 422
      end
      run_pipeline(document)

      get "/desk/documents/#{document.uuid}/review"
      expect(response.body).to include('Only Sam Example signs for it', 'Yes, send')
      get "/desk/documents/#{document.uuid}"
      expect(response).to have_http_status(:ok)
    end

    it 'puts a refusal under the box it is about, and keeps what was written' do
      client = saffron_client(account)
      sign_in(user)
      post '/desk/contracts'
      document = Desk::Document.sole
      patch "/desk/questions/#{document.questions.find_by(key: 'variation:client').id}", params: { answer: client.id }
      items = document.questions.find_by(key: 'variation:items')

      get "/desk/questions/#{items.id}"
      expect(response.body).to include('name="answer[rows][][one_time]"', '+ Add another item', '<template>')
      patch "/desk/questions/#{items.id}",
            params: { answer: { rows: [{ name: 'Driver app', one_time: 'twelve', currency: 'AED', monthly: '0' }] } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="Driver app"', 'value="twelve"', 'aria-invalid="true"',
                                       '&quot;twelve&quot; is not a price')
      expect(items.reload).to be_open
    end
  end

  describe 'separation of accounts' do
    let(:document) do
      desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement),
                  filename: 'Saffron Dune master agreement.pdf')
    end
    let(:client) { saffron_client(account) }
    let(:intruder) { create(:user, account: create(:account)) }

    before { sign_in(intruder) }

    it 'shows another account nothing of this one' do
      question = Desk::Question.create!(account_id: account.id, document:, key: 'k', kind: 'email', prompt: 'p')

      calls = [-> { get "/desk/documents/#{document.uuid}" },
               -> { get "/desk/documents/#{document.uuid}/download/source" },
               -> { get "/desk/clients/#{client.id}" },
               -> { patch "/desk/questions/#{question.id}", params: { answer: 'x@example.com' } },
               -> { post "/desk/documents/#{document.uuid}/approve" }]

      calls.each do |call|
        sign_in(intruder) # a request that raises sets no session cookie: sign in again for each
        expect { call.call }.to raise_error(ActiveRecord::RecordNotFound)
      end

      sign_in(intruder)

      get '/desk/documents'
      expect(response.body).not_to include(document.name)
      get '/desk/clients'
      expect(response.body).not_to include(client.legal_name)
      expect(question.reload.status).to eq('open')
    end
  end

  describe 'the client register' do
    it 'counts the documents of each client as the Documents page does: archived ones are not counted' do
      client = Desk::Client.create!(account_id: account.id, legal_name: 'Count Check Co', source: 'Added by hand')
      %w[ready_to_send signed archived].each do |state|
        Desk::Document.create!(account_id: account.id, created_by_user: user, client:, source: 'generated',
                               doc_type: 'variation', title: "Count #{state}", state:,
                               file_sha256: "pending:#{SecureRandom.uuid}")
      end
      sign_in(user)

      get '/desk/clients'

      expect(response.body).to include('<td>2</td>')
      expect(response.body).not_to include('<td>3</td>')
    end
  end

  describe '"Yes, send"' do
    let(:document) { ready_document }

    it 'is refused without two-factor sign-in' do
      sign_in(user)

      post "/desk/documents/#{document.uuid}/approve"

      expect(flash[:alert]).to match(/two-factor/)
      expect(document.reload.state).to eq('ready_to_send')
      expect(Sidekiq::Worker.jobs.pluck('class')).not_to include('SendSubmitterInvitationEmailJob')
    end

    it 'is refused to a person who is not an approver when approval is required' do
      with_two_factor(user)
      Desk::Setting.for(account).update!(approval_required: true, approver_user_ids: [create(:user, account:).id])
      sign_in(user)

      post "/desk/documents/#{document.uuid}/approve"

      expect(flash[:alert]).to match(/approvers/)
      expect(document.reload.state).to eq('ready_to_send')
    end

    it 'asks for a saved signature when the sender signs on approval' do
      with_two_factor(user)
      sign_in(user)

      post "/desk/documents/#{document.uuid}/approve"

      expect(flash[:alert]).to match(/signature/)
      expect(document.reload.state).to eq('ready_to_send')
    end

    it 'signs for the own company with the saved signature and invites the client' do
      with_two_factor(user)
      save_signature!(user)
      sign_in(user)

      post "/desk/documents/#{document.uuid}/approve", params: { signer_title: 'Manager' }

      document.reload
      own, theirs = document.submission.submitters.sort_by do |s|
        document.submission.template_submitters.index do |t|
          t['uuid'] == s.uuid
        end
      end
      expect(document.state).to eq('sent')
      expect(document.sent_by_user).to eq(user)
      expect(own.completed_at).to be_present
      expect(own.email).to eq(user.email)
      expect(own.values.values).to include(user.full_name, 'Manager')
      expect(theirs.completed_at).to be_nil
      expect([own, theirs].map { |s| s.preferences['send_email'] }).to all(be(true))
      expect(document.submission.expire_at).to be_within(1.minute).of(30.days.from_now)
      expect(document.events.pluck(:action)).to include(/approved and signed by #{user.full_name}/)
      expect(ProcessSubmitterCompletionJob.jobs.pluck('args').flatten.pluck('submitter_id')).to eq([own.id])
      expect(Desk::FollowUpJob.jobs.size).to eq(1)

      post "/desk/documents/#{document.uuid}/approve"
      expect(flash[:alert]).to match(/not ready to send/)
    end

    it 'sends the invitation itself when the sender does not sign on approval' do
      Desk::Setting.for(account).update!(sender_signs_on_approval: false)
      with_two_factor(user)
      sign_in(user)
      stub_ai('b-client-contract-ksa-1')
      Desk::Client.create!(account_id: account.id, legal_name: 'Najd Falcon Drilling Services Co.',
                           tax_number: '300987654300003', source: 'Added by hand',
                           signers: [{ name: 'Faisal Al-Qahtani', email: 'faisal@najd.example' }])
      contract = desk_upload(account:, user:, pdf: synthetic_pdf(:client_contract), filename: 'contract.pdf')

      run_pipeline(contract)
      # our side is never asked about: its signer comes from the own profile
      expect(contract.questions.open.pluck(:kind)).to all(eq('acknowledge'))
      contract.questions.open.each { |q| Desk::Questions.answer!(q, '', user) }
      run_pipeline(contract)
      expect(contract.state).to eq('ready_to_send')

      post "/desk/documents/#{contract.uuid}/approve"

      expect(contract.reload.state).to eq('sent')
      expect(contract.submission.submitters.map(&:completed_at)).to all(be_nil)
      expect(SendSubmitterInvitationEmailJob.jobs.pluck('args').flatten.pluck('submitter_id'))
        .to eq([contract.submission.submitters.find_by(email: 'sam@northwind.example').id]) # our side first, only
    end
  end

  describe 'follow-up' do
    let(:document) { ready_document }

    before do
      with_two_factor(user)
      save_signature!(user)
      sign_in(user)
      post "/desk/documents/#{document.uuid}/approve", params: { signer_title: 'Manager' }
      document.reload
    end

    it 'marks it opened, reminds on the schedule and warns before the links expire' do
      theirs = document.submission.submitters.find { |s| s.email == 'layla@saffron.example' }
      theirs.update!(sent_at: Time.current, opened_at: Time.current)

      Desk::FollowUp.call(document)
      expect(document.reload.state).to eq('opened')

      Desk::FollowUp.call(document, now: document.sent_at + 3.days + 1.hour)
      reminder = ActionMailer::Base.deliveries.last
      expect(reminder.to).to eq(['layla@saffron.example'])
      expect(reminder.subject).to start_with('Reminder:')
      expect(document.reload.reminders_sent).to eq([3])
      expect(theirs.submission_events.pluck(:event_type)).to include('send_reminder_email')

      Desk::FollowUp.call(document, now: document.sent_at + 3.days + 2.hours)
      expect(ActionMailer::Base.deliveries.count { |m| m.subject.start_with?('Reminder:') }).to eq(1)

      Desk::FollowUp.call(document, now: document.submission.expire_at - 2.days)
      expect(ActionMailer::Base.deliveries.last.subject).to start_with('Signing links expire soon')
      expect(document.reload.expiry_warned_at).to be_present
    end

    it 'fetches the signed PDF and the audit record into the register and tells the sender' do
      create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))
      submission = document.submission
      theirs = submission.submitters.find { |s| s.email == 'layla@saffron.example' }
      signature = ActiveStorage::Attachment.create!(
        blob: ActiveStorage::Blob.create_and_upload!(io: Rails.root.join('spec/fixtures/sample-image.png').open,
                                                     filename: 's.png', content_type: 'image/png'),
        name: 'attachments', record: theirs
      )
      sig_field = submission.template_fields.find { |f| f['submitter_uuid'] == theirs.uuid && f['type'] == 'signature' }
      request = ActionDispatch::TestRequest.create('REQUEST_METHOD' => 'POST')
      request.env['warden'] = instance_double(Warden::Proxy, user: nil)
      values = { sig_field['uuid'] => signature.uuid }
      Submitters::SubmitValues.call(theirs, ActionController::Parameters.new(values:,
                                                                             completed: 'true'), request)

      Desk::FollowUp.call(document.reload)

      document.reload
      expect(document.state).to eq('signed')
      expect(document.signed_pdf).to be_attached
      expect(document.audit_log).to be_attached
      expect(document.signed_pdf.attachment.preview_images).to exist # the card shows the signed pages
      expect(document.events.pluck(:action)).to include('signed PDF and audit record fetched', 'sender notified')

      get "/desk/documents/#{document.uuid}/download/signed"
      expect(response.media_type).to eq('application/pdf')
      expect(response.body).to start_with('%PDF')
    end
  end
end

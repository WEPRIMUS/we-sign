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
      expect(response.body).to include('Can I send it?', 'Yes, send', 'Fix something', 'layla@saffron.example',
                                       'Copy for information (not signing)')
      get "/desk/documents/#{document.uuid}"
      expect(response.body).not_to include('See signatures in WE Sign') # not sent yet
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

    it 'invites the signers of the other party at the same moment, once our side has signed' do
      with_two_factor(user)
      save_signature!(user)
      create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))
      stub_ai('c-scanned-letter-au-1', 'c-scanned-letter-au-2')
      Desk::Client.create!(account_id: account.id, legal_name: 'Wattle Creek Minerals Pty Ltd',
                           tax_number: '51 824 753 556', source: 'Added by hand',
                           signers: [{ name: 'Hannah Reid', role: 'Director', email: 'hannah@wattle.example' },
                                     { name: 'Tom Brennan', role: 'Company Secretary', email: 'tom@wattle.example' }])
      letter = desk_upload(account:, user:, pdf: synthetic_pdf(:scanned_letter), filename: 'letter.pdf')
      run_pipeline(letter)
      letter.questions.open.each { |q| Desk::Questions.answer!(q, DeskSpecHelpers::ANSWERS.fetch(q.kind), user) }
      run_pipeline(letter)
      expect(letter.template.submitters.pluck('order')).to eq([0, 1, 1])
      sign_in(user)

      post "/desk/documents/#{letter.uuid}/approve", params: { signer_title: 'Manager' }
      own = letter.reload.submission.submitters.find_by(email: user.email)
      expect(SendSubmitterInvitationEmailJob.jobs).to be_empty # our side signs first
      ProcessSubmitterCompletionJob.new.perform('submitter_id' => own.id)

      invited = SendSubmitterInvitationEmailJob.jobs.pluck('args').flatten.pluck('submitter_id')
      expect(Submitter.where(id: invited).pluck(:email))
        .to contain_exactly('hannah@wattle.example', 'tom@wattle.example')
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

    it 'links the card to the signatures in WE Sign, and says the preview is the original file' do
      get "/desk/documents/#{document.uuid}"

      expect(response.body).to include('See signatures in WE Sign', %(href="/submissions/#{document.submission.id}"),
                                       'This is the original file. Signatures are added in WE Sign.')
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

  describe 'keep informed' do
    let(:document) { ready_document }

    before do
      Desk::Setting.for(account).update!(keep_informed: ['partner@northwind.example', user.email])
      with_two_factor(user)
      save_signature!(user)
    end

    # The e-mails the desk queued (deliver_later), delivered now.
    def queued_mail
      Sidekiq::Worker.jobs.select { |j| j['wrapped'] == 'ActionMailer::MailDeliveryJob' }
                     .each { |j| ActiveJob::Base.execute(j['args'].first) }
      ActionMailer::Base.deliveries
    end

    def send_document(**params)
      sign_in(user)
      post "/desk/documents/#{document.uuid}/approve", params: { signer_title: 'Manager', **params }
      document.reload
    end

    def client_signs!
      unless EncryptedConfig.exists?(account:, key: EncryptedConfig::ESIGN_CERTS_KEY)
        create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                  value: GenerateCertificate.call.transform_values(&:to_pem))
      end
      theirs = document.submission.submitters.find { |s| s.email == 'layla@saffron.example' }
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
      Submitters::SubmitValues.call(theirs, ActionController::Parameters.new(values:, completed: 'true'), request)
      Sidekiq::Worker.clear_all
      ActionMailer::Base.deliveries.clear
      ProcessSubmitterCompletionJob.new.perform('submitter_id' => theirs.id) # WE Sign's own e-mails at completion
      Desk::FollowUp.call(document.reload)
    end

    it 'is edited in Desk settings, one address per line, and refuses what is not an address' do
      sign_in(user)

      patch '/desk/settings', params: { setting: { keep_informed: "a@northwind.example\nb@northwind.example, " \
                                                                  'A@northwind.example' } }
      expect(Desk::Setting.for(account).keep_informed).to eq(%w[a@northwind.example b@northwind.example])

      patch '/desk/settings', params: { setting: { keep_informed: 'a@northwind.example not-an-address' } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('Keep informed: not an e-mail address: not-an-address')
      expect(Desk::Setting.for(account).keep_informed).to eq(%w[a@northwind.example b@northwind.example])
    end

    it 'sends nothing while the document is prepared' do
      document

      expect(document.state).to eq('ready_to_send')
      expect(queued_mail).to be_empty
      expect(Sidekiq::Worker.jobs.pluck('class')).not_to include('SendSubmitterInvitationEmailJob')
    end

    it 'tells everyone on the list but the sender that the document was sent' do
      send_document

      notices = queued_mail.select { |m| m.subject == "Sent: #{document.name}" }
      expect(notices.flat_map(&:to)).to eq(['partner@northwind.example'])
      html = (notices.first.html_part || notices.first).body.decoded
      expect(Nokogiri::HTML(html).text).to include("#{user.full_name} sent '#{document.name}' to Layla Haddad " \
                                                   '(Saffron Dune Logistics L.L.C.).')
      expect(html).to include("/desk/documents/#{document.uuid}")
      expect(document.events.pluck(:action)).to include('keep-informed notice sent')
    end

    it 'sends no notice when the list is empty' do
      Desk::Setting.for(account).update!(keep_informed: [])

      send_document

      expect(document.state).to eq('sent')
      expect(queued_mail.map(&:subject)).not_to include(start_with('Sent:'))
      expect(document.events.pluck(:action)).not_to include('keep-informed notice sent')
    end

    it 'sends the signed copy and the audit record to the list, and no second copy to a listed signer' do
      Desk::Setting.for(account).update!(keep_informed: ['partner@northwind.example', 'Layla@Saffron.example',
                                                         user.email])
      send_document

      client_signs!

      expect(document.reload.state).to eq('signed')
      copies = queued_mail.select { |m| m.attachments.any? }
      per_address = copies.flat_map(&:to).tally
      # the listed client and the sender (who signed for us) each get WE Sign's copy to signers, and only that one
      expect(per_address).to eq('partner@northwind.example' => 1, 'layla@saffron.example' => 1, user.email => 1)
      copy = copies.find { |m| m.to == ['partner@northwind.example'] }
      expect(copy.attachments.size).to eq(2)
      expect(copy.attachments.map(&:filename)).to include(match(/audit/i))
      expect(document.events.pluck(:action)).to include('signed copy sent to the keep-informed list')
    end

    describe 'a copy for information' do
      before do
        create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                  value: GenerateCertificate.call.transform_values(&:to_pem))
      end

      it 'refuses what is not an e-mail address, and sends nothing' do
        send_document(copy_to: 'observer@northwind.example, not-an-address')

        expect(flash[:alert]).to eq('Copy for information: not an e-mail address: not-an-address')
        expect(document.state).to eq('ready_to_send')
        expect(document.submission.submitters.map(&:completed_at)).to all(be_nil)
        expect(queued_mail).to be_empty
      end

      it 'tells each address it was sent, with the PDF signed on our side, leaving out signers and the list' do
        send_document(copy_to: 'Observer@northwind.example; layla@saffron.example, partner@northwind.example ' \
                               "#{user.email} observer@northwind.example")

        expect(document.copy_to).to eq(['observer@northwind.example'])
        notices = queued_mail.select { |m| m.subject == "Sent: #{document.name}" }
        expect(notices.flat_map(&:to).tally).to eq('partner@northwind.example' => 1, 'observer@northwind.example' => 1)
        copy = notices.find { |m| m.to == ['observer@northwind.example'] }
        expect(copy.attachments.size).to eq(1)
        expect(copy.attachments.first.body.decoded).to start_with('%PDF')
        expect(copy.attachments.first.body.decoded).not_to eq(document.source_file.download) # signed on our side
        expect(Nokogiri::HTML(copy.html_part.body.decoded).text).to include('as sent, signed on our side')
        expect(copy.html_part.body.decoded).not_to include('/desk/documents/') # no link into the desk
        expect(notices.find { |m| m.to == ['partner@northwind.example'] }.attachments).to be_empty
        expect(document.events.pluck(:action)).to include('copy for information sent')

        get "/desk/documents/#{document.uuid}"
        expect(response.body).to include('Copy for information: observer@northwind.example')
      end

      it 'attaches the original when our side has not signed' do
        document.update!(sent_by_user: user, sent_at: Time.current)

        mail = DeskMailer.sent_email(document, 'observer@northwind.example', attach: true)

        expect(mail.attachments.sole.body.decoded).to eq(document.source_file.download)
        expect(Nokogiri::HTML(mail.html_part.body.decoded).text).to include('the document as sent')
      end

      it 'sends each the signed copy and the audit record when everyone has signed, once' do
        send_document(copy_to: 'observer@northwind.example')

        client_signs!

        copies = queued_mail.select { |m| m.attachments.any? }
        expect(copies.flat_map(&:to).tally).to eq('partner@northwind.example' => 1, 'observer@northwind.example' => 1,
                                                  'layla@saffron.example' => 1, user.email => 1)
        expect(copies.find { |m| m.to == ['observer@northwind.example'] }.attachments.map(&:filename))
          .to include(match(/audit/i))
        expect(document.events.pluck(:action)).to include('signed copy sent for information')
      end
    end

    it 'sends the list the signed copy even when WE Sign sends no copy to signers' do
      create(:account_config, account:, key: AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY,
                              value: { 'enabled' => false })
      Desk::Setting.for(account).update!(keep_informed: ['partner@northwind.example', 'layla@saffron.example'])
      send_document

      client_signs!

      copies = queued_mail.select { |m| m.attachments.any? }
      expect(copies.flat_map(&:to).tally).to eq('partner@northwind.example' => 1, 'layla@saffron.example' => 1)
    end
  end

  describe 'the invitation e-mail' do
    def invitation(document)
      theirs = document.submission.submitters.find { |s| s.email == 'layla@saffron.example' }
      mail = SubmitterMailer.invitation_email(theirs)

      [mail.subject, Nokogiri::HTML((mail.html_part || mail).body.decoded).text.squish]
    end

    it 'greets each signer by first name and names the document and the sender' do
      document = ready_document

      subject, text = invitation(document)

      expect(subject).to eq("#{account.name}: #{document.name}, for your signature")
      expect(text).to start_with('Hi Layla,')
      expect(text).to include("#{user.full_name} of #{account.name} has sent you \"#{document.name}\" for your " \
                              'signature.', 'Review and sign')
    end

    it 'is edited in Desk settings, beside its variables, for the documents prepared after' do
      sign_in(user)
      get '/desk/settings/edit'
      expect(response.body).to include('Invitation e-mail', '{{submitter.first_name}}', '{{template.name}}')

      patch '/desk/settings', params: { setting: { invitation_subject: 'Please sign: {{template.name}}',
                                                   invitation_body: "Dear {{submitter.first_name}},\r\n\r\n" \
                                                                    '{{submitter.link}}' } }
      expect(Desk::Setting.for(account).invitation_subject).to eq('Please sign: {{template.name}}')
      desk_settings_for(account, sender_signs_on_approval: true) # the rest of the form, as it was
      document = ready_document

      subject, text = invitation(document)
      expect(subject).to eq("Please sign: #{document.name}")
      expect(text).to start_with('Dear Layla,')
    end

    it 'stores nothing for the desk text as it is, so that the default stays the desk own' do
      sign_in(user)

      body = Desk::Setting::INVITATION_BODY.gsub("\n", "\r\n") # as a browser sends a text area
      patch '/desk/settings', params: { setting: { invitation_subject: Desk::Setting::INVITATION_SUBJECT,
                                                   invitation_body: body } }

      expect(Desk::Setting.for(account).attributes.values_at('invitation_subject', 'invitation_body')).to eq([nil, nil])
    end

    it 'keeps what was set for the document itself in WE Sign' do
      document = ready_document
      template = document.template
      template.update!(preferences: template.preferences.merge('request_email_subject' => 'Our words'))

      expect(invitation(document).first).to eq('Our words')
    end
  end

  describe 'e-mail that does not go out' do
    it 'is recorded, though the app raises no delivery error, and shown on the desk home until one goes out' do
      mail = Mail.new(from: 'desk@northwind.example', to: 'someone@northwind.example', subject: 'Test', body: 'Test')
      mail.delivery_method(:smtp, address: '127.0.0.1', port: 1, enable_starttls: false, open_timeout: 2)
      mail.raise_delivery_errors = false

      expect { mail.deliver }.not_to raise_error

      settings = Desk::Setting.for(account)
      expect(settings.reload.mail_error).to eq('Errno::ECONNREFUSED')
      sign_in(user)
      get '/desk'
      expect(response.body).to include('E-mails are not going out since', '(Errno::ECONNREFUSED)',
                                       'href="/settings/email"')

      first = settings.mail_failed_at
      failing = Class.new { def deliver!(_mail) = raise(Net::ReadTimeout) }.prepend(Desk::MailHealth::Delivery)
      travel(1.hour) { expect { failing.new.deliver!(mail) }.to raise_error(Net::ReadTimeout) }
      expect(settings.reload.attributes.values_at('mail_failed_at', 'mail_error')).to eq([first, 'Net::ReadTimeout'])

      going_out = Class.new { def deliver!(_mail) = :sent }.prepend(Desk::MailHealth::Delivery)
      going_out.new.deliver!(mail)

      expect(settings.reload.attributes.values_at('mail_failed_at', 'mail_error')).to eq([nil, nil])
      get '/desk'
      expect(response.body).not_to include('E-mails are not going out')
    end
  end
end

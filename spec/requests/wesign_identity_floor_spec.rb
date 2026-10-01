# frozen_string_literal: true

# WE Sign must-fix 1: the e-mail code is the floor for every signer, whatever the template says.
describe 'WE Sign identity floor' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let(:submitter) { create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:) }
  let(:field_uuid) { template.fields.first['uuid'] }
  let(:code) { EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':')) }

  describe 'a template with no verification preference' do
    it 'does not show the form before the e-mail code is passed' do
      get submit_form_path(slug: submitter.slug)

      expect(response.body.include?(I18n.t('send_verification_code'))).to be(true)
      expect(response.body.include?('<submission-form')).to be(false)
    end

    it 'refuses a submit before the e-mail code is passed' do
      put submit_form_path(slug: submitter.slug), params: { values: { field_uuid => 'Mary' }, completed: 'true' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.values).to be_empty
    end

    it 'shows the form and accepts the submit once the code is accepted' do
      post submit_form_email_2fa_path, params: { submitter_slug: submitter.slug, one_time_code: code }
      get submit_form_path(slug: submitter.slug)

      expect(response.body.include?('<submission-form')).to be(true)

      put submit_form_path(slug: submitter.slug), params: { values: { field_uuid => 'Mary' }, completed: 'true' }

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.completed_at).to be_present
    end
  end

  describe 'the e-mail code' do
    it 'is used up when accepted' do
      post submit_form_email_2fa_path, params: { submitter_slug: submitter.slug, one_time_code: code }

      expect(response).to redirect_to(submit_form_path(submitter.slug))

      reset! # another browser replays the same code

      post submit_form_email_2fa_path, params: { submitter_slug: submitter.slug, one_time_code: code }

      expect(response).to redirect_to(submit_form_path(submitter.slug, status: :error))

      get submit_form_path(slug: submitter.slug)

      expect(response.body.include?('<submission-form')).to be(false)
    end
  end

  describe 'the attempt counters' do
    it 'keep counting when the process memory is gone' do
      2.times { RateLimit.call('wesign-spec', limit: 2, ttl: 1.minute, enabled: true) }

      RateLimit::STORE.clear if RateLimit.const_defined?(:STORE) # what a restart does to a per-process store

      expect { RateLimit.call('wesign-spec', limit: 2, ttl: 1.minute, enabled: true) }
        .to raise_error(RateLimit::LimitApproached)
    end

    it 'start again when the window has passed' do
      2.times { RateLimit.call('wesign-spec', limit: 2, ttl: 1.minute, enabled: true) }

      travel_to(2.minutes.from_now) do
        expect(RateLimit.call('wesign-spec', limit: 2, ttl: 1.minute, enabled: true)).to be(true)
      end
    end
  end

  describe 'the signing link' do
    it 'expires 30 days after sending when no expiry was set' do
      expect(submission.expire_at).to be_within(1.minute).of(30.days.from_now)

      travel_to(31.days.from_now) do
        post submit_form_email_2fa_path, params: { submitter_slug: submitter.slug, one_time_code: code }
        get submit_form_path(slug: submitter.slug)

        expect(response.body.include?('<submission-form')).to be(false)

        put submit_form_path(slug: submitter.slug), params: { values: { field_uuid => 'Mary' }, completed: 'true' }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq(I18n.t('form_has_been_expired'))
      end
    end

    it 'keeps an expiry that was set' do
      expect(create(:submission, template:, expire_at: 2.days.from_now).expire_at)
        .to be_within(1.minute).of(2.days.from_now)
    end

    it 'cannot have its expiry removed through the API' do
      put "/api/submissions/#{submission.id}", headers: { 'x-auth-token': author.access_token.token },
                                               params: { expire_at: nil }.to_json

      expect(submission.reload.expire_at).to be_within(1.minute).of(submission.created_at + 30.days)
    end
  end

  describe 'a signer with no e-mail address' do
    before { sign_in(author) }

    it 'cannot be sent a document from the staff screen' do
      expect do
        post template_submissions_path(template),
             params: { submission: { '1' => { submitters: [{ uuid: template.submitters.first['uuid'],
                                                             name: 'No Mail' }] } } }
      end.not_to change(Submitter, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'cannot be sent a document through the API' do
      expect do
        post '/api/submissions', headers: { 'x-auth-token': author.access_token.token },
                                 params: { template_id: template.id,
                                           submitters: [{ role: 'First Party', phone: '+971500000000' }] }.to_json
      end.not_to change(Submitter, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'cannot be stored' do
      expect(build(:submitter, submission:, account:, email: nil).tap(&:validate).errors[:email]).to be_present
    end
  end

  describe 'the phone verification setting, which nothing checks' do
    before { sign_in(author) }

    it 'cannot be stored on a template' do
      post template_preferences_path(template),
           params: { template: { preferences: { require_phone_2fa: 'true', require_email_2fa: 'true' } } }

      expect(template.reload.preferences).to eq('require_email_2fa' => true)
    end

    it 'cannot be stored on a signer' do
      post '/api/submissions', headers: { 'x-auth-token': author.access_token.token },
                               params: { template_id: template.id, send_email: false, require_phone_2fa: true,
                                         submitters: [{ role: 'First Party', email: 'john@example.com',
                                                        require_phone_2fa: true }] }.to_json

      expect(response).to have_http_status(:ok)
      expect(Submitter.last.preferences).not_to have_key('require_phone_2fa')
    end
  end

  describe 'a shared template link' do
    let(:template) { create(:template, shared_link: true, account:, author:, only_field_types: %w[text]) }

    it 'does not let the person who typed an address view or submit without the code sent to it' do
      put start_form_path(slug: template.slug), params: { submitter: { email: 'john@example.com' } }

      link_submitter = Submitter.find_by!(email: 'john@example.com')

      expect(response).to redirect_to(submit_form_path(link_submitter.slug))

      get submit_form_path(slug: link_submitter.slug)

      expect(response.body.include?(I18n.t('send_verification_code'))).to be(true)
      expect(response.body.include?('<submission-form')).to be(false)

      put submit_form_path(slug: link_submitter.slug),
          params: { values: { field_uuid => 'Mary' }, completed: 'true' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(link_submitter.reload.completed_at).to be_nil
    end
  end

  describe 'completed documents' do
    it 'are not shown by the submission address alone, only by the e-mailed link' do
      create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))
      submitter.update!(completed_at: 1.minute.ago)
      Submissions.maybe_update_completed_at(submission)

      get submissions_preview_path(slug: submission.slug)

      expect(response).to redirect_to(submissions_preview_completed_path(submission.slug))

      get submissions_preview_download_index_path(submission.slug)

      expect(response).to have_http_status(:not_found)
    end
  end
end

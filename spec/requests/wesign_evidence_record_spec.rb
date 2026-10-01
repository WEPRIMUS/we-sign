# frozen_string_literal: true

# WE Sign must-fix 8: the evidence record cannot be padded, and says "verified" only when a code was accepted.
describe 'WE Sign evidence record' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]).reload }
  let(:submission) do
    Submissions.create_from_emails(template:, user: author, emails: 'john@example.com', source: :invite).first
  end
  let!(:submitter) { submission.submitters.first }
  let(:values) { { template.fields.first['uuid'] => 'Mary' } }
  let(:file) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png') }

  def pass_code
    post submit_form_email_2fa_path, params: {
      submitter_slug: submitter.slug,
      one_time_code: EmailVerificationCodes.generate([submitter.email, submitter.slug].join(':'))
    }
  end

  def audit_text
    create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))

    Submissions::EnsureResultGenerated.call(submitter.reload)

    data = Submissions::GenerateAuditTrail.call(submission.reload).download

    Pdfium::Document.open_bytes(data) { |doc| Array.new(doc.page_count) { |i| doc.get_page(i).text }.join("\n") }
  end

  describe 'a holder of the link who has not passed the e-mail code' do
    it 'cannot add "form viewed" events or reset the opened time through the old route' do
      submitter.update!(opened_at: 1.day.ago, completed_at: 1.hour.ago)

      expect do
        post '/api/submitter_form_views', params: { submitter_slug: submitter.slug }.to_json
      rescue ActionController::RoutingError
        nil
      end.not_to change(SubmissionEvent, :count)

      expect(submitter.reload.opened_at).to be_within(1.minute).of(1.day.ago)
    end

    it 'cannot add "form viewed" events through the current route without the token given with the form' do
      expect do
        post submit_form_view_index_path(submitter.slug), params: { v: 'made-up' }
      end.not_to change(SubmissionEvent, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'cannot upload a file through the old route' do
      expect do
        post '/api/attachments', params: { submitter_slug: submitter.slug, file: }
      rescue ActionController::RoutingError
        nil
      end.not_to change(ActiveStorage::Attachment, :count)
    end

    it 'cannot upload a file through the current route' do
      expect do
        post submit_form_upload_index_path(submitter.slug), params: { file: }
      end.not_to change(ActiveStorage::Attachment, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'a signer who has passed the e-mail code' do
    it 'can upload a file through the current route' do
      pass_code

      expect do
        post submit_form_upload_index_path(submitter.slug), params: { file: }
      end.to change(ActiveStorage::Attachment, :count).by(1)
    end
  end

  describe 'the audit record' do
    it 'does not say the e-mail was verified when the signer only clicked the e-mailed link' do
      create(:submission_event, submission:, submitter:, event_type: 'click_email')
      submitter.update!(completed_at: Time.current, values:)
      Submissions.maybe_update_completed_at(submission)

      expect(audit_text.include?("#{I18n.t('email_verification')}: #{I18n.t('verified')}")).to be(false)
    end

    it 'says the e-mail was verified when a code was accepted' do
      pass_code
      put submit_form_path(slug: submitter.slug), params: { values:, completed: 'true' }

      expect(audit_text.include?("#{I18n.t('email_verification')}: #{I18n.t('verified')}")).to be(true)
    end
  end
end

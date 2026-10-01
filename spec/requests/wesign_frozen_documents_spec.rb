# frozen_string_literal: true

# WE Sign must-fix 2: what was sent is frozen at creation, and only the signer completes a form.
describe 'WE Sign frozen documents' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]).reload }
  let(:document) { template.documents_attachments.first }
  let!(:field_uuid) { template.fields.first['uuid'] }
  let!(:sent_sha256) { Base64.urlsafe_encode64(Digest::SHA256.digest(document.download)) }
  let(:token) { { 'x-auth-token': author.access_token.token } }

  def send_by_email(email = 'john@example.com')
    Submissions.create_from_emails(template:, user: author, emails: email, source: :invite).first
  end

  def complete(submission)
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))

    submission.submitters.first.tap do |submitter|
      post submit_form_email_2fa_path, params: {
        submitter_slug: submitter.slug,
        one_time_code: EmailVerificationCodes.generate([submitter.email, submitter.slug].join(':'))
      }
      put submit_form_path(slug: submitter.slug), params: { values: { field_uuid => 'Mary' }, completed: 'true' }
      submitter.reload
    end
  end

  def pdf_text(data)
    Pdfium::Document.open_bytes(data) { |doc| Array.new(doc.page_count) { |i| doc.get_page(i).text }.join("\n") }
  end

  describe 'the fields, the document list and a SHA-256 of each document' do
    it 'are recorded when a document is sent from the staff screen' do
      sign_in(author)

      post template_submissions_path(template), params: { emails: 'john@example.com' }

      submission = Submission.last

      expect(submission.template_fields).to eq(template.fields)
      expect(submission.template_submitters).to eq(template.submitters)
      expect(submission.template_schema.map { |e| e.values_at('attachment_uuid', 'sha256') })
        .to eq([[document.uuid, sent_sha256]])
    end

    it 'are recorded when a document is sent through the API' do
      post '/api/submissions', headers: token, params: {
        template_id: template.id, send_email: false, submitters: [{ role: 'First Party', email: 'john@example.com' }]
      }.to_json

      submission = Submission.last

      expect(submission.template_fields).to eq(template.fields)
      expect(submission.template_schema.map { |e| e.values_at('attachment_uuid', 'sha256') })
        .to eq([[document.uuid, sent_sha256]])
    end

    it 'are recorded when a signer starts from a shared template link' do
      template.update!(shared_link: true)

      put start_form_path(slug: template.slug), params: { submitter: { email: 'john@example.com' } }

      submission = Submission.last

      expect(submission.template_fields).to eq(template.fields)
      expect(submission.template_schema.map { |e| e.values_at('attachment_uuid', 'sha256') })
        .to eq([[document.uuid, sent_sha256]])
    end
  end

  describe 'a template edited after sending' do
    it 'does not change the fields the signer completes' do
      submitter = send_by_email.submitters.first

      template.update!(fields: [])

      complete(submitter.submission)

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.values).to eq(field_uuid => 'Mary')
    end
  end

  describe 'the signed PDF' do
    it 'is built when the file is the one that was sent' do
      submitter = complete(send_by_email)

      expect(Submissions::GenerateResultAttachments.call(submitter).size).to eq(1)
    end

    it 'is refused when the file is no longer the one that was sent' do
      submission = send_by_email

      other_pdf = StringIO.new.tap { |io| HexaPDF::Document.new.tap { |pdf| pdf.pages.add }.write(io) }

      document.update!(blob: ActiveStorage::Blob.create_and_upload!(io: other_pdf.tap(&:rewind),
                                                                    filename: 'other.pdf'))

      submitter = complete(submission)

      expect { Submissions::GenerateResultAttachments.call(submitter) }
        .to raise_error(/differs from what was sent/)
      expect(submitter.documents).to be_empty
    end
  end

  describe 'the audit record' do
    it 'shows the SHA-256 recorded when the document was sent' do
      submission = send_by_email
      submitter = complete(submission)

      Submissions::EnsureResultGenerated.call(submitter)

      document.update!(metadata: document.metadata.merge('sha256' => 'changed-after-sending'))

      text = pdf_text(Submissions::GenerateAuditTrail.call(submission.reload).download)

      expect(text.delete("\r\n ")).to include(sent_sha256)
      expect(text).not_to include('changed-after-sending')
    end
  end

  describe 'completion through the API' do
    it 'is refused when a document is sent' do
      expect do
        post '/api/submissions', headers: token, params: {
          template_id: template.id,
          submitters: [{ role: 'First Party', email: 'john@example.com', completed: true }]
        }.to_json
      end.not_to change(Submitter, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused for a signer who has been sent a document' do
      submitter = send_by_email.submitters.first

      put "/api/submitters/#{submitter.id}", headers: token, params: { completed: true }.to_json

      expect(response).to have_http_status(:unprocessable_content)
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.submission_events.where(event_type: 'api_complete_form')).to be_empty
    end
  end
end

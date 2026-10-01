# frozen_string_literal: true

# WE Sign must-fix 7: the seal names the signers and the product, and a failed timestamp fails the job.
RSpec.describe 'WE Sign seal' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]).reload }
  let(:submission) do
    Submissions.create_from_emails(template:, user: author, emails: 'john@example.com', source: :invite).first
  end
  let(:submitter) do
    submission.submitters.first.tap do |submitter|
      submitter.update!(completed_at: Time.current, values: { template.fields.first['uuid'] => 'Mary' })
      Submissions.maybe_update_completed_at(submission)
      submission.reload
    end
  end
  let(:tsa_url) { 'https://tsa.example/tsr' }

  def signature_reason(attachment)
    HexaPDF::Document.new(io: StringIO.new(attachment.download)).signatures.first[:Reason]
  end

  before do
    create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
    allow(Docuseal).to receive(:product_name).and_return('Acme Sign')
  end

  describe 'the signature reason' do
    it 'names the signer and the product on a signed document' do
      document = Submissions::GenerateResultAttachments.call(submitter).first

      expect(signature_reason(document)).to eq('Signed by john@example.com with Acme Sign')
    end

    it 'names the product on the audit record' do
      Submissions::EnsureResultGenerated.call(submitter)

      expect(signature_reason(Submissions::GenerateAuditTrail.call(submission)))
        .to eq('Audit log sealed with Acme Sign')
    end
  end

  describe 'a timestamp server that fails' do
    before { create(:encrypted_config, account:, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY, value: tsa_url) }

    it 'fails the signing job when it answers with an error' do
      stub_request(:post, tsa_url).to_return(status: 500)

      expect { Submissions::GenerateResultAttachments.call(submitter) }.to raise_error(StandardError)
      expect(submitter.documents.reload).to be_empty
    end

    it 'fails the signing job when it does not answer' do
      stub_request(:post, tsa_url).to_timeout

      expect { Submissions::GenerateResultAttachments.call(submitter) }.to raise_error(StandardError)
      expect(submitter.documents.reload).to be_empty
    end

    it 'fails the signing job when the fallback server fails too' do
      EncryptedConfig.find_by(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY)
                     .update!(value: "#{tsa_url},https://tsa2.example/tsr")

      stub_request(:post, tsa_url).to_return(status: 500)
      stub_request(:post, 'https://tsa2.example/tsr').to_timeout

      expect { Submissions::GenerateResultAttachments.call(submitter) }.to raise_error(StandardError)
      expect(a_request(:post, 'https://tsa2.example/tsr')).to have_been_made.at_least_once
    end
  end
end

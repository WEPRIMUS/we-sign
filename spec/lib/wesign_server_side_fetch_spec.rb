# frozen_string_literal: true

# WE Sign must-fix 9: a server-side fetch resolves the name and refuses an internal address (SEC-APP-08),
# and has a timeout and a size cap (SEC-REL-01).
RSpec.describe 'WE Sign server-side fetches' do # rubocop:disable RSpec/DescribeClass
  let(:internal_url) { 'https://internal.example/file.pdf' }
  let(:public_url) { 'https://files.example/file.pdf' }

  def resolve(host, *addresses)
    allow(Resolv).to receive(:getaddresses).with(host).and_return(addresses)
  end

  describe 'a download from a supplied address' do
    %w[10.0.0.5 172.16.0.1 192.168.1.1 127.0.0.1 169.254.169.254 0.0.0.0 ::1 fc00::1 fe80::1
       ::ffff:127.0.0.1].each do |address|
      it "is refused when the name resolves to #{address}" do
        resolve('internal.example', address)
        stub_request(:get, internal_url).to_return(body: 'secret')

        expect { DownloadUtils.call(internal_url, validate: true) }.to raise_error(DownloadUtils::UnableToDownload)
        expect(a_request(:get, internal_url)).not_to have_been_made
      end
    end

    it 'is refused when one of several addresses of the name is internal' do
      resolve('internal.example', '203.0.113.10', '10.0.0.5')
      stub_request(:get, internal_url).to_return(body: 'secret')

      expect { DownloadUtils.call(internal_url, validate: true) }.to raise_error(DownloadUtils::UnableToDownload)
      expect(a_request(:get, internal_url)).not_to have_been_made
    end

    it 'is refused when the name does not resolve' do
      resolve('internal.example')

      expect { DownloadUtils.call(internal_url, validate: true) }.to raise_error(DownloadUtils::UnableToDownload)
    end

    it 'is refused when a public address redirects to an internal one' do
      resolve('internal.example', '10.0.0.5')
      stub_request(:get, public_url).to_return(status: 302, headers: { 'Location' => internal_url })
      stub_request(:get, internal_url).to_return(body: 'secret')

      expect { DownloadUtils.call(public_url, validate: true) }.to raise_error(DownloadUtils::UnableToDownload)
      expect(a_request(:get, internal_url)).not_to have_been_made
    end

    it 'is refused when the file is larger than the cap' do
      stub_const('DownloadUtils::MAX_SIZE', 10)
      stub_request(:get, public_url).to_return(body: 'x' * 11)

      expect { DownloadUtils.call(public_url, validate: true) }.to raise_error(DownloadUtils::UnableToDownload)
    end

    it 'has a 5-second connect timeout and a 30-second read timeout' do
      options = DownloadUtils.conn(validate: true).options

      expect([options.open_timeout, options.timeout]).to eq([5, 30])
    end

    it 'returns the file from a public address, also after a redirect' do
      stub_request(:get, public_url).to_return(status: 302, headers: { 'Location' => 'https://cdn.example/f.pdf' })
      stub_request(:get, 'https://cdn.example/f.pdf').to_return(body: 'the file')

      expect(DownloadUtils.call(public_url, validate: true).body).to eq('the file')
    end
  end

  describe 'a webhook' do
    let(:account) { create(:account) }
    let(:webhook_url) { create(:webhook_url, account:, url: 'https://internal.example/hook') }
    let(:template) { create(:template, account:, author: create(:user, account:)) }

    before do
      resolve('internal.example', '10.0.0.5')
      stub_request(:post, webhook_url.url).to_return(status: 200, body: 'internal answer')
    end

    it 'is not sent to an address that resolves to an internal one, and the attempt is recorded as failed' do
      SendWebhookRequest.call(webhook_url, event_uuid: SecureRandom.uuid, event_type: 'template.created',
                                           record: template, data: {})

      expect(a_request(:post, webhook_url.url)).not_to have_been_made
      expect(WebhookEvent.last.status).to eq('error')
      expect(WebhookAttempt.last.response_status_code).to eq(0)
    end

    it 'is not sent as a test either' do
      submitter = create(:submission, :with_submitters, template:).submitters.first

      expect do
        SendTestWebhookRequestJob.new.perform('submitter_id' => submitter.id, 'webhook_url_id' => webhook_url.id)
      end.to raise_error(DownloadUtils::UnableToDownload)

      expect(a_request(:post, webhook_url.url)).not_to have_been_made
    end
  end

  describe 'a timestamp server' do
    let(:tsa_url) { 'https://internal.example/tsr' }

    before do
      resolve('internal.example', '10.0.0.5')
      stub_request(:post, tsa_url).to_return(status: 200, body: 'internal answer')
    end

    it 'is not called when its address resolves to an internal one' do
      handler = Submissions::TimestampHandler.new(tsa_url:)

      expect { handler.sign(StringIO.new('0123456789'), [0, 5, 5, 5]) }
        .to raise_error(DownloadUtils::UnableToDownload)
      expect(a_request(:post, tsa_url)).not_to have_been_made
    end
  end
end

# frozen_string_literal: true

# WE Sign must-fix 9: the timestamp server address a staff user saves is checked like any supplied address.
describe 'WE Sign timestamp server setting' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:tsa_url) { 'https://internal.example/tsr' }

  before do
    sign_in(user)
    allow(Resolv).to receive(:getaddresses).with('internal.example').and_return(['10.0.0.5'])
    stub_request(:post, tsa_url).to_return(status: 200, body: 'internal answer')
  end

  it 'is not called and not saved when the address resolves to an internal one' do
    post timestamp_server_index_path, params: { encrypted_config: { value: tsa_url } }

    expect(a_request(:post, tsa_url)).not_to have_been_made
    expect(EncryptedConfig.where(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY)).to be_empty
    expect(response).to be_redirect
  end
end

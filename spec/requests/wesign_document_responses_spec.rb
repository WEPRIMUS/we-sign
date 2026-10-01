# frozen_string_literal: true

# WE Sign must-fix 6: a document is never kept by a cache and is not offered to other origins.
describe 'WE Sign document responses' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:document) { template.documents_attachments.first }
  let(:document_path) { ActiveStorage::Blob.proxy_path(document.blob, expires_at: 5.minutes.from_now.to_i) }
  let(:evil) { { 'Origin' => 'https://evil.example' } }

  def expect_private_and_same_origin_only
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(response.headers.keys.grep(/access-control/i)).to be_empty
  end

  it 'serves a document through its signed link as private, no-store, with no cross-origin header' do
    get document_path, headers: evil

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(document.blob.byte_size)
    expect_private_and_same_origin_only
  end

  it 'serves a byte range of a document the same way' do
    get document_path, headers: evil.merge('Range' => 'bytes=0-99')

    expect(response).to have_http_status(:partial_content)
    expect_private_and_same_origin_only
  end

  it 'serves a page image of a document as private, no-store' do
    url = ActiveStorage::Current.set(url_options: { host: 'www.example.com' }) { document.preview_images.first.url }

    get url, headers: evil

    expect(response).to have_http_status(:ok)
    expect_private_and_same_origin_only
  end

  it 'sends no cross-origin header with a JSON error' do
    env = Rack::MockRequest.env_for('/api/nothing', 'HTTP_ACCEPT' => 'application/json',
                                                    'HTTP_ORIGIN' => 'https://evil.example',
                                                    'action_dispatch.exception' => ActiveRecord::RecordNotFound.new)

    status, headers, = ErrorsController.action(:show).call(env)

    expect(status).to eq(404)
    expect(headers.keys.grep(/access-control/i)).to be_empty
  end
end

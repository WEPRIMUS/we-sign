# frozen_string_literal: true

# WE Sign must-fix 11: the API does not change anything on the strength of the staff session cookie alone
# (SEC-APP-06). A cross-site request carries the cookie but cannot add the X-Auth-Token header.
describe 'WE Sign API and the session cookie' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let!(:template) { create(:template, account:, author: user, only_field_types: %w[text]) }
  let(:body) { { template_id: template.id, submitters: [{ role: 'First Party', email: 'john@example.com' }] } }

  context 'with the session cookie only' do
    before { sign_in(user) }

    it 'refuses to send a document' do
      expect { post '/api/submissions', params: body.to_json }.not_to change(Submission, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses to change a template' do
      put "/api/templates/#{template.id}", params: { name: 'Changed from another site' }.to_json

      expect(response).to have_http_status(:unauthorized)
      expect(template.reload.name).not_to eq('Changed from another site')
    end

    it 'refuses to archive a template' do
      delete "/api/templates/#{template.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(template.reload.archived_at).to be_nil
    end

    it 'still answers a read' do
      get '/api/templates'

      expect(response).to have_http_status(:ok)
    end
  end

  context 'with the API token' do
    it 'sends a document' do
      expect do
        post '/api/submissions', headers: { 'x-auth-token': user.access_token.token }, params: body.to_json
      end.to change(Submission, :count).by(1)
    end
  end
end

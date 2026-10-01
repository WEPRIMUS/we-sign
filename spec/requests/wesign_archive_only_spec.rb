# frozen_string_literal: true

# WE Sign must-fix 3: a signed record is archived, never destroyed, on every route.
describe 'WE Sign archive only' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let!(:submission) { create(:submission, :with_submitters, :with_events, template:, created_by_user: author) }
  let(:token) { { 'x-auth-token': author.access_token.token } }

  def expect_everything_kept
    expect(Template.where(id: template.id)).to exist
    expect(Submission.where(id: submission.id)).to exist
    expect(Submitter.where(submission_id: submission.id).count).to eq(1)
    expect(SubmissionEvent.where(submission_id: submission.id).count).to eq(1)
  end

  it 'archives a submission when the staff screen asks for permanent removal' do
    sign_in(author)

    delete submission_path(submission, permanently: true)

    expect_everything_kept
    expect(submission.reload.archived_at).to be_present
  end

  it 'archives a submission when the API asks for permanent removal' do
    delete "/api/submissions/#{submission.id}?permanently=true", headers: token

    expect(response).to have_http_status(:ok)
    expect_everything_kept
    expect(submission.reload.archived_at).to be_present
  end

  it 'archives a template, and keeps its submissions, when the staff screen asks for permanent removal' do
    sign_in(author)

    delete template_path(template, permanently: true)

    expect_everything_kept
    expect(template.reload.archived_at).to be_present
  end

  it 'archives a template, and keeps its submissions, when the API asks for permanent removal' do
    delete "/api/templates/#{template.id}?permanently=true", headers: token

    expect(response).to have_http_status(:ok)
    expect_everything_kept
    expect(template.reload.archived_at).to be_present
  end

  it 'has no helper that destroys and regenerates the documents of a submission' do
    expect(Submissions).not_to respond_to(:regenerate_documents)
  end
end

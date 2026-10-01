# frozen_string_literal: true

# WE Sign (SEC-REL-05): a signer's part is completed once. The "already completed" check was a read followed
# by a write with no lock, so two requests arriving together could both complete it.
describe 'WE Sign completion race' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let!(:submitter) { create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:) }
  let(:field_uuid) { template.fields.first['uuid'] }
  let(:first_completion) { 1.second.ago.change(usec: 0) }

  before do
    post submit_form_email_2fa_path, params: {
      submitter_slug: submitter.slug,
      one_time_code: EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':'))
    }

    # another request completes the signer's part after this request has read it as not completed
    allow(Submitters::SubmitValues).to receive(:assign_completed_attributes)
      .and_wrap_original do |original, *args, **opts|
      Submitter.where(id: submitter.id).update_all(completed_at: first_completion, values: { field_uuid => 'First' })

      original.call(*args, **opts)
    end
  end

  it 'refuses the second completion and leaves the first one as it was' do
    put submit_form_path(slug: submitter.slug), params: { values: { field_uuid => 'Second' }, completed: 'true' }

    expect(response).to have_http_status(:unprocessable_content)
    expect(submitter.reload.completed_at).to eq(first_completion)
    expect(submitter.values).to eq(field_uuid => 'First')
    expect(submitter.submission_events.where(event_type: 'complete_form')).to be_empty
    expect(ProcessSubmitterCompletionJob.jobs).to be_empty
  end
end

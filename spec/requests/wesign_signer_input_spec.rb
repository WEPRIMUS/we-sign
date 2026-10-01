# frozen_string_literal: true

# WE Sign must-fix 10: what a signer sends is checked for shape and size, not only for ownership
# (SEC-APP-03, SEC-APP-04).
describe 'WE Sign signer input' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text number checkbox multiple]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let!(:submitter) { create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:) }
  let(:fields) { submission.template_fields.index_by { |f| f['type'] } }

  def field_uuid(type)
    fields[type]['uuid']
  end

  def submit(values, **extra)
    put submit_form_path(slug: submitter.slug), params: { values:, **extra }
  end

  def upload(name, content, type = 'application/octet-stream')
    file = Tempfile.new(['upload', File.extname(name)]).tap do |f|
      f.binmode
      f.write(content)
      f.rewind
    end

    post submit_form_upload_index_path(submitter.slug),
         params: { file: Rack::Test::UploadedFile.new(file.path, type, original_filename: name) }
  end

  before do
    post submit_form_email_2fa_path, params: {
      submitter_slug: submitter.slug,
      one_time_code: EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':'))
    }
  end

  describe 'a submitted value' do
    it 'is refused when a text field is given a list' do
      submit({ field_uuid('text') => %w[a b] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(submitter.reload.values).to be_empty
    end

    it 'is refused when a text field is given a nested structure' do
      submit({ field_uuid('text') => { 'a' => { 'b' => 'c' } } })

      expect(response).to have_http_status(:unprocessable_content)
      expect(submitter.reload.values).to be_empty
    end

    it 'is refused when a number field is given text' do
      submit({ field_uuid('number') => 'twelve' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(submitter.reload.values).to be_empty
    end

    it 'is refused when a checkbox is given text' do
      submit({ field_uuid('checkbox') => 'maybe' })

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused when a multiple-choice field is given a single text' do
      submit({ field_uuid('multiple') => 'Red' })

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused when it does not match the pattern set on the field' do
      fields['text']['validation'] = { 'pattern' => '[0-9]{4}' }
      submission.save!

      submit({ field_uuid('text') => '12a4' })

      expect(response).to have_http_status(:unprocessable_content)

      submit({ field_uuid('text') => '1234' })

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.values).to eq(field_uuid('text') => '1234')
    end

    it 'is refused when the values are not a set of fields at all' do
      put submit_form_path(slug: submitter.slug), params: { values: 'everything' }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused when the request is larger than 1 MB' do
      submit({ field_uuid('text') => 'a' * 1.1.megabytes })

      expect(response).to have_http_status(:content_too_large)
      expect(submitter.reload.values).to be_empty
    end

    it 'is accepted in the shape of its field type' do
      submit({ field_uuid('text') => 'Mary' })
      submit({ field_uuid('number') => '12' }, cast_number: 'true')
      submit({ field_uuid('checkbox') => 'true' }, cast_boolean: 'true')
      submit({ field_uuid('multiple') => %w[Red Blue] })

      expect(response).to have_http_status(:ok)
      expect(submitter.reload.values).to eq(field_uuid('text') => 'Mary', field_uuid('number') => 12,
                                            field_uuid('checkbox') => true, field_uuid('multiple') => %w[Red Blue])
    end
  end

  describe 'an uploaded file' do
    it 'is refused when it is a program renamed to look like a PDF' do
      expect { upload('contract.pdf', "MZ\x90\x00\x03".b + ('0' * 200), 'application/pdf') }
        .not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused when its type is not on the list' do
      expect { upload('picture.svg', '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>') }
        .not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused when it is larger than the cap' do
      stub_const('Submitters::MAX_UPLOAD_SIZE', 100)

      expect { upload('contract.pdf', "%PDF-1.7\n#{'0' * 200}") }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is accepted when it is a real PDF or image' do
      expect { upload('contract.pdf', Rails.root.join('spec/fixtures/sample-document.pdf').binread) }
        .to change(ActiveStorage::Blob, :count).by(1)

      expect { upload('photo.png', Rails.root.join('spec/fixtures/sample-image.png').binread) }
        .to change(ActiveStorage::Blob, :count).by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'the API parameter validator' do
    it 'does not let a request through when the validator itself fails, in production as elsewhere' do
      failing_validator = Class.new(Params::BaseValidator) do
        def call
          raise 'a bug in the validator'
        end
      end

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect { failing_validator.call({}) }.to raise_error('a bug in the validator')
    end
  end
end

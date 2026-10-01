# frozen_string_literal: true

# WE Sign: the product name follows one setting (Docuseal.product_name), and the DocuSeal attribution the
# licence requires stays DocuSeal. Each example fails when the mechanism behind it is removed.
describe 'WE Sign brand' do
  let(:name) { Docuseal.product_name }

  it 'names the product from the setting in upstream translations, in every language' do
    expect(I18n.t('welcome_to_docuseal')).to eq("Welcome to #{name}")
    expect(I18n.t('welcome_to_docuseal', locale: :es)).to eq("Bienvenido a #{name}")
    expect(I18n.t('app_tour').to_json).not_to include('DocuSeal')
  end

  it "leaves the vendor's paid products and services under the vendor's name" do
    expect(I18n.t('unlock_with_docuseal_pro')).to eq('Unlock with DocuSeal Pro')
    expect(I18n.t('docuseal_trusted_signature')).to eq('DocuSeal Trusted Signature')
  end

  it 'does not put the 21 CFR Part 11 compliance wording under our name' do
    key = 'require_signer_to_provide_a_reason_for_signing_before_completing_their_signature_e_g_approvals_' \
          'certifications_part_of_docuseals_21_cfr_part_11_compliance_settings'

    expect(I18n.t(key)).to include("DocuSeal's 21 CFR Part 11")
  end

  it "replaces the vendor's support address" do
    expect(I18n.t('app_tour.support_description')).to include(Docuseal::SUPPORT_EMAIL)
    expect(I18n.t('app_tour.support_description')).not_to include('docuseal.com')
  end

  # The DocuSeal credit is the words "Powered by DocuSeal" and nothing more (the product owner's decision,
  # 30 Sep 2026): plain text, no link on the name, no tail. The name is the upstream's and never follows the
  # product name. The source offer (AGPL section 13) stands beside it on signer and staff pages, and not on the
  # sign-in panel.
  it 'credits DocuSeal in plain words on the sign-in page: no link, no source offer' do
    create(:user)

    get new_user_session_path

    expect(response.body).to match(/Powered by\s+DocuSeal\s*</)
    expect(response.body).not_to include('DocuSeal</a>')
    expect(response.body).not_to include('open source documents software')
    expect(response.body).not_to include(%(href="#{Docuseal::SOURCE_CODE_URL}"))
    expect(response.body).to match(/<title>\s*#{Regexp.escape(name)} \|/)
  end

  it 'credits DocuSeal under its own name, never under the product name' do
    stub_const('Docuseal::PRODUCT_NAME', 'Acme Sign')
    create(:user)

    get new_user_session_path
    html = ApplicationController.render(partial: 'shared/email_attribution')

    expect(response.body).to match(/Powered by\s+DocuSeal\s*</)
    expect(response.body).not_to match(/Powered by\s+Acme Sign/)
    expect(html).to include('Powered by DocuSeal')
    expect(html).not_to include('Acme Sign')
  end

  describe 'on signer pages and staff pages' do
    let(:account) { create(:account) }
    let(:author) { create(:user, account:) }
    let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
    let(:submission) { create(:submission, template:, created_by_user: author) }
    let(:submitter) { create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:) }
    let(:code) { EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':')) }
    let(:credit_and_source_offer) do
      source = Regexp.escape(Docuseal::SOURCE_CODE_URL)

      /Powered by\s+DocuSeal\s*<span class="whitespace-nowrap">&middot; <a href="#{source}"/
    end

    def pass_the_e_mail_code
      post submit_form_email_2fa_path, params: { submitter_slug: submitter.slug, one_time_code: code }
    end

    it 'shows the logo on signer pages as plain content, not as a link to the front page' do
      front_page_link = %r{<a\b[^>]*\bhref="/"} # the bare address is the staff sign-in page

      get submit_form_path(slug: submitter.slug) # the e-mail code page

      expect(response.body).to include(I18n.t('send_verification_code'))
      expect(response.body).not_to match(front_page_link)

      pass_the_e_mail_code
      get submit_form_path(slug: submitter.slug) # the signing form

      expect(response.body).to include('<submission-form')
      expect(response.body).not_to match(front_page_link)

      get submissions_preview_path(slug: submission.slug, sig: submitter.signed_id(purpose: :download_completed))

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to match(front_page_link)

      sign_in(author) # staff pages keep their link to the dashboard
      get root_path

      expect(response.body).to match(front_page_link)
    end

    it 'credits DocuSeal in plain words, with the source offer beside it' do
      pass_the_e_mail_code
      get submit_form_path(slug: submitter.slug)

      expect(response.body).to include('<submission-form')
      expect(response.body).to match(credit_and_source_offer)

      sign_in(author)
      get root_path

      expect(response.body).to match(credit_and_source_offer)
    end
  end

  it 'credits DocuSeal on the printable QR sheet in the same plain words, without a link' do
    author = create(:user)
    template = create(:template, account: author.account, author:, shared_link: true)
    sign_in(author)

    get template_share_link_qr_path(template)

    expect(response).to have_http_status(:ok)
    expect(response.body).to match(%r{<div class="qr-branding">\s*Powered by DocuSeal\s*</div>})
    expect(response.body).not_to include('docuseal.com')
  end

  it 'shows the e-mail code as always on in the template preferences, with no switch for it' do
    author = create(:user)
    template = create(:template, account: author.account, author:)
    sign_in(author)

    get template_preferences_path(template)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('wesign.email_code_always_on'))
    expect(response.body).not_to include('require_email_2fa')
    expect(response.body).not_to include('require_phone_2fa')
  end

  # Permanent deletion was removed on purpose; a "remove" button on an archived item would only archive again.
  it 'shows no remove button on archived templates and archived submissions, but keeps restore' do
    author = create(:user)
    template = create(:template, account: author.account, author:)
    submission = create(:submission, :with_submitters, template:, created_by_user: author)
    submission.update!(archived_at: Time.current)
    template.update!(archived_at: Time.current)
    removal = /name="permanently"|permanently=true/
    sign_in(author)

    [[templates_archived_index_path, template_restore_index_path(template)],
     [submissions_archived_index_path, submission_path(submission)],
     [template_archived_index_path(template), submission_path(submission)],
     [template_path(template), submission_path(submission)]].each do |path, card|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(card) # the item is listed...
      expect(response.body).not_to match(removal) # ...without a remove button
    end

    get template_path(template), headers: { 'User-Agent' => 'Hotwire Native' } # the menu of the mobile app

    expect(response.body).to include(template_restore_index_path(template))
    expect(response.body).not_to match(removal)
  end

  it 'opens the sign-in page, not the upstream landing page, at the bare address' do
    get root_path
    expect(response).to redirect_to(setup_index_path) # a fresh install still goes to setup first, as upstream

    create(:user)
    get root_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it 'credits DocuSeal in e-mails as one plain line, without a link' do
    html = ApplicationController.render(partial: 'shared/email_attribution')

    expect(html).to match(%r{<p>\s*Powered by DocuSeal\s*</p>})
    expect(html).not_to include('<a')
  end

  it 'credits DocuSeal beside the product name in the PDF Creator field' do
    expect(Submissions::GenerateResultAttachments.info_creator).to eq("#{name} (built on DocuSeal)")
  end
end

# frozen_string_literal: true

require 'open3'

# WE Sign: one application image, one brand pack per installation (lib/brand.rb, brands/<pack>/). The pack is
# chosen by the environment variable BRAND when the application starts. Each example fails when the mechanism
# behind it is removed.
#
# Where an example needs a second pack it uses the stand-in in spec/fixtures/brands/sample (plain colours, tiny
# generated images, every option a client pack may set). Only inside such an example does the loader look there,
# through stub_const on Brand::ROOT; how the application finds and loads its packs is not changed for the tests.
describe 'WE Sign brand packs' do
  let(:packs) { Rails.root.join('brands').children.select(&:directory?).map { |dir| dir.basename.to_s }.sort }
  let(:stand_in) { Rails.root.join('spec/fixtures/brands/sample') }

  around do |example|
    pack = Brand.pack
    example.run
  ensure
    Brand.load!(pack)
  end

  def load_stand_in
    stub_const('Brand::ROOT', stand_in.parent)
    Brand.load!('sample')
  end

  def sign_in_page
    create(:user) unless User.exists?
    get new_user_session_path

    response.body
  end

  def signer_of(author)
    template = create(:template, account: author.account, author:, only_field_types: %w[text])
    submission = create(:submission, template:, created_by_user: author)

    create(:submitter, submission:, uuid: template.submitters.first['uuid'], account: author.account)
  end

  def pass_the_e_mail_code(submitter)
    code = EmailVerificationCodes.generate([submitter.email.downcase.strip, submitter.slug].join(':'))

    post submit_form_email_2fa_path, params: { submitter_slug: submitter.slug, one_time_code: code }
  end

  # pack.yml as the loader reads it, with one option added or replaced
  def with_pack_option(key, value)
    allow(YAML).to(receive(:safe_load_file).and_wrap_original { |load, *args| load.call(*args).merge(key => value) })
  end

  def audit_pdf_header
    column = Struct.new(:calls) do
      def image(path, **) = calls << path
      def formatted_text(parts, **) = calls << parts.pluck(:text).join
    end.new([])

    Submissions::GenerateAuditTrail.add_logo(column)
    column.calls
  end

  it 'serves the WE PRIMUS pack when BRAND is not set' do
    expect(ENV.fetch('BRAND', nil)).to be_nil
    expect(Brand.pack).to eq('we-primus')

    html = sign_in_page

    expect(html).to match(%r{<img src="/brand/we-primus-\h{12}/logo-light\.png" alt="WE PRIMUS"})
    expect(html).to match(%r{<link rel="stylesheet" href="/brand/we-primus-\h{12}/theme\.css">})
    expect(html).to match(%r{class="we-auth-brand">\s*<img[^>]+>\s*<span>WE Sign</span>})
    expect(html).to include(Brand.url('login-photo-1920.webp'))
    expect(html.scan(%r{/brand/[a-z0-9-]+-\h{12}/}).uniq).to eq([Brand.url('')]) # no file of another pack

    get Brand.url('logo-light.png')

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
    expect(response.body.b).to eq(Rails.root.join('brands/we-primus/logo-light.png').binread)
  end

  it 'offers a 16 px tab icon beside the 32 px one when the pack has one' do
    icon = lambda do |size|
      %(<link rel="icon" type="image/png" sizes="#{size}x#{size}" href="#{Brand.url("favicon-#{size}.png")}">)
    end

    expect(Brand.file?('favicon-16.png')).to be(false) # we-primus has the 32 px icon only
    expect(sign_in_page).to include(icon[32])
    expect(response.body).not_to include('sizes="16x16"')

    allow(Brand).to receive(:file?).and_call_original
    allow(Brand).to receive(:file?).with('favicon-16.png').and_return(true)

    expect(sign_in_page).to include(icon[16], icon[32])
  end

  it 'serves only what a page uses from the pack: never pack.yml or a licence text' do
    %w[logo-light.png login-photo-1920.webp theme.css onest-latin.woff2].each do |file|
      get Brand.url(file)

      expect(response).to have_http_status(:ok)
    end

    %w[pack.yml OFL-Onest.txt].each do |file|
      expect(Brand.file?(file)).to be(true)

      get Brand.url(file)

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('public_name', 'Copyright')
    end
  end

  it 'serves the logo, icons, colours and names of the pack BRAND names, and no file of another pack' do
    load_stand_in

    html = sign_in_page

    expect(html).to match(%r{<img src="/brand/sample-\h{12}/logo-light\.png" alt="Sample Client"})
    expect(html).to match(%r{<link rel="stylesheet" href="/brand/sample-\h{12}/theme\.css">})
    expect(html).to include('<meta name="theme-color" content="#e8f0f8">')
    expect(html).not_to match(%r{/brand/we-primus|alt="WE PRIMUS"|favicon-32}) # no WE PRIMUS file or mark

    get Brand.url('logo-light.png')

    expect(response.body.b).to eq(stand_in.join('logo-light.png').binread)
    expect(response.body.b).not_to eq(Rails.root.join('brands/we-primus/logo-light.png').binread)

    get Brand.url('theme.css')

    expect(response.body).to eq(stand_in.join('theme.css').read)

    get '/manifest.json'

    expect(response.parsed_body['icons'].pluck('src')).to eq([Brand.url('icon-192.png'), Brand.url('icon-512.png')])
    expect(response.parsed_body['theme_color']).to eq('#e8f0f8')
    expect(response.body).not_to include('we-primus')

    get '/favicon.ico'

    expect(response).to redirect_to(Brand.url('icon-192.png')) # the pack has no 32 px favicon

    # a file only the other pack has: not found (the test environment raises where production shows the 404 page)
    expect { get '/brand/we-primus-000000000000/mark.png' }.to raise_error(ActionController::RoutingError)
    expect(audit_pdf_header).to eq([Brand.path('logo-light.png'), "Sample Client Ltd\nPowered by DocuSeal"])
    expect(Brand.path('logo-light.png')).to include('/spec/fixtures/brands/sample/')
  end

  it 'shows the logo alone on staff pages and signer pages in a pack whose logo leads alone' do
    load_stand_in
    author = create(:user)
    submitter = signer_of(author)
    logo_alone = %r{<img src="/brand/sample-\h{12}/logo-light\.png" alt="Sample Client"[^>]*>\s*</(a|div)>}

    expect(Brand.header).to eq('logo') # what logo_leads_alone: true means for the in-app headers

    get submit_form_path(slug: submitter.slug) # the e-mail code page

    expect(response.body).to match(logo_alone)
    expect(response.body).not_to match(/we-primus|WE PRIMUS/)

    sign_in(author)
    get root_path

    expect(response.body).to match(logo_alone)
    expect(response.body).not_to match(/we-primus|WE PRIMUS/)
  end

  it 'shows the product name alone in the in-app headers with header: name, and the logo at sign-in' do
    expect(Brand.header).to eq('name') # we-primus
    expect(sign_in_page).to match(%r{class="we-auth-brand">\s*<img[^>]+>\s*<span>WE Sign</span>}) # unchanged

    author = User.first
    submitter = signer_of(author)

    get submit_form_path(slug: submitter.slug) # the e-mail code page: the start-form header

    expect(response.body).to match(%r{<div class="brand-lockup[^"]*">\s*<h1[^>]*>WE Sign</h1>\s*</div>})

    pass_the_e_mail_code(submitter)
    get submit_form_path(slug: submitter.slug) # the signing form

    expect(response.body).to match(%r{<div class="brand-lockup[^"]*">\s*<span>WE Sign</span>\s*</div>})
    expect(response.body).not_to include('logo-light.png')

    sign_in(author)
    get root_path

    expect(response.body).to match(%r{<a href="/" class="[^"]*">\s*<span>WE Sign</span>\s*</a>})
    expect(response.body).not_to include('logo-light.png')
    expect(ApplicationController.render(partial: 'templates_share_link_qr/logo').strip).to eq('<span>WE Sign</span>')
    expect(audit_pdf_header).to eq(["WE Sign\nPowered by DocuSeal"])
  end

  it 'shows the logo and the product name in the in-app headers by default; refuses an unknown header' do
    allow(Brand).to receive(:header).and_return('logo_and_name')

    expect(ApplicationController.render(partial: 'shared/title'))
      .to match(%r{<img src="/brand/we-primus-\h{12}/logo-light\.png"[^>]*>\s*<span>WE Sign</span>})
    expect(audit_pdf_header).to eq([Brand.path('logo-light.png'), "WE Sign\nPowered by DocuSeal"])

    with_pack_option('header', 'x')

    expect { Brand.load!('we-primus') }
      .to raise_error(Brand::Error, /sets header: x; it is one of logo_and_name, logo, name\./)
  end

  it "adds the pack's footer line under the attribution line of staff and signer pages, not on the sign-in page" do
    line = '<div class="text-center px-2">WE PRIMUS</div>' # we-primus: footer_credit
    under_the_credit = %r{Powered by\s+DocuSeal\s*<span class="whitespace-nowrap">.*?</span>\s*</div>\s*#{line}}m

    expect(sign_in_page).not_to include(line)

    author = User.first
    submitter = signer_of(author)
    pass_the_e_mail_code(submitter)
    get submit_form_path(slug: submitter.slug) # the signing form; its completion screen reads the meta tag

    expect(response.body).to match(under_the_credit)
    expect(response.body).to include('<meta name="footer-credit" content="WE PRIMUS">')

    sign_in(author)
    get root_path

    expect(response.body).to match(under_the_credit)
    expect(response.body.scan(line).size).to eq(1)

    load_stand_in
    get root_path

    expect(response.body).not_to include(line, 'footer-credit')
  end

  it 'heads the audit PDF with the legal name of the pack and the credit, on bands of its page colour' do
    load_stand_in
    author = create(:user)
    template = create(:template, account: author.account, author:, only_field_types: %w[text]).reload
    submission = Submissions.create_from_emails(template:, user: author, emails: 'john@example.com',
                                                source: :invite).first
    submitter = submission.submitters.first
    submitter.update!(completed_at: Time.current, values: { template.fields.first['uuid'] => 'Mary' })
    Submissions.maybe_update_completed_at(submission)
    create(:encrypted_config, account: author.account, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
    Submissions::EnsureResultGenerated.call(submitter.reload)

    data = Submissions::GenerateAuditTrail.call(submission.reload).download
    text = Pdfium::Document.open_bytes(data) { |doc| doc.get_page(0).text }
    page = HexaPDF::Document.new(io: StringIO.new(data)).pages[0]

    expect(text.squish).to start_with('Sample Client Ltd Powered by DocuSeal')
    expect(text).not_to include('WE Sign')
    expect(page.contents).to include('0.909804 0.941176 0.972549 rg') # #e8f0f8, not the default page colour
  end

  def first_run_certificate_subjects
    post setup_index_path, params: {
      user: { first_name: 'Ada', last_name: 'Admin', email: 'ada@example.com', password: 'Tall-Quiet-Harbour-47' },
      account: { name: 'Example', timezone: 'UTC', locale: 'en-US' },
      encrypted_config: { value: 'https://sign.example.com' }
    }

    certs = EncryptedConfig.find_by!(key: EncryptedConfig::ESIGN_CERTS_KEY).value

    %w[cert sub_ca root_ca].map do |key|
      OpenSSL::X509::Certificate.new(certs[key]).subject.to_a.map { |field, value, _type| [field, value] }
    end
  end

  it 'issues the first-run signing certificate to the legal name of the pack, with no country when it sets none' do
    load_stand_in
    o = ['O', 'Sample Client Ltd']

    expect(first_run_certificate_subjects).to eq([[o, ['CN', 'Sample Client Ltd']],
                                                  [o, ['CN', 'Sample Client Ltd Sub-CA']],
                                                  [o, ['CN', 'Sample Client Ltd Root CA']]])
  end

  it 'issues the first-run signing certificate in the country of the pack when it sets legal_country' do
    with_pack_option('legal_country', 'AE')
    load_stand_in

    c = %w[C AE]
    o = ['O', 'Sample Client Ltd']

    expect(Brand.legal_country).to eq('AE')
    expect(first_run_certificate_subjects).to eq([[c, o, ['CN', 'Sample Client Ltd']],
                                                  [c, o, ['CN', 'Sample Client Ltd Sub-CA']],
                                                  [c, o, ['CN', 'Sample Client Ltd Root CA']]])
  end

  it 'refuses a legal_country that is not a two-letter ISO 3166 code' do
    ['UK', 'ae', 'XX', 'UAE', '', false].each do |country|
      with_pack_option('legal_country', country)

      expect { Brand.load!('we-primus') }
        .to raise_error(Brand::Error, /sets legal_country: #{Regexp.escape(country.inspect)}; it is a two-letter ISO/)
    end
  end

  it 'refuses a pack that does not exist, names the ones that do, and keeps the pack it had' do
    expect { Brand.load!('acme') }
      .to raise_error(Brand::Error, /BRAND=acme: there is no brand pack of that name\. The packs in .+ we-primus/)
    expect { Brand.load!('../config') }.to raise_error(Brand::Error, /no brand pack of that name/)
    expect(Brand.pack).to eq('we-primus')
  end

  it 'does not start with an unknown BRAND' do
    output, status = Open3.capture2e({ 'BRAND' => 'acme' }, 'bin/rails', 'runner', 'puts :started',
                                     chdir: Rails.root.to_s)

    expect(status).not_to be_success
    expect(output).to include('BRAND=acme: there is no brand pack of that name')
    expect(output).not_to include('started')
  end

  it 'shows the same DocuSeal credit in every pack' do
    credit = lambda do
      [sign_in_page[%r{<div class="we-auth-credit">.*?</div>\s*</div>}m],
       ApplicationController.render(partial: 'shared/powered_by')[%r{<div.*?</div>}m], # without a pack's footer line
       ApplicationController.render(partial: 'shared/email_attribution'),
       audit_pdf_header.last.lines.last]
    end

    shown = packs.to_h do |pack|
      Brand.load!(pack)
      [pack, credit.call]
    end
    load_stand_in
    shown['sample'] = credit.call

    expect(shown.values.uniq.size).to eq(1)
    expect(shown.fetch('sample')).to match([/Powered by\s+DocuSeal\s*</, /Powered by\s+DocuSeal\s*<span/,
                                            /Powered by DocuSeal/, 'Powered by DocuSeal'])
    expect(shown.fetch('sample').join).not_to match(%r{Sample|DocuSeal</a>})
  end

  # The opening film of a pack (its logo reveal) is played by app/javascript/brand/opening.js once after a
  # successful sign-in. The page only names the film; whether the sign-in succeeded is the server's answer.
  it 'names an opening film on the sign-in page only, and only in a pack that has one' do
    expect(sign_in_page).not_to include('brand-opening', 'opening.mp4') # we-primus has none

    load_stand_in
    allow(Brand).to receive(:file?).and_call_original
    allow(Brand).to receive(:file?).with('opening.mp4').and_return(true) # the stand-in carries no film file

    expect(sign_in_page).to match(
      %r{<meta name="brand-opening" content="/brand/sample-\h{12}/opening\.mp4" data-form="/sign_in">}
    )

    get new_user_password_path

    expect(response.body).not_to include('brand-opening')

    sign_in(User.first)
    get root_path

    expect(response.body).not_to include('brand-opening')
  end

  # The builder of the system signs the sign-in photograph (pack.yml: builder_credit, builder_logo, support_email).
  it "signs the sign-in photograph with the builder's logo and the support address, where the pack says so" do
    expect(sign_in_page).not_to include('we-auth-builder', 'we-auth-support', 'mailto:') # we-primus: off

    load_stand_in
    html = sign_in_page
    corner = html[%r{<div class="we-auth-builder">.*?</div>\s*</div>}m]
    help = %(<div>Need help? Ask a question: <a href="mailto:help@example.com">help@example.com</a></div>)
    logo = %r{<img class="we-auth-builder-logo" src="/brand/sample-\h{12}/builder-logo\.png" alt="Sample Builder">}

    expect(corner).to match(/#{logo}\s*#{Regexp.escape(help)}/)
    expect(corner).not_to include('<div>Sample Builder</div>')
    expect(corner.scan('<a ').size).to eq(1) # the address only: the logo is not a link
    expect(html).to include(%(<div class="we-auth-support">#{help.delete_prefix('<div>')})) # phones
    expect(html.index('we-auth-builder')).to be > html.index('</main>') # a corner of its own, not in the panel

    get Brand.url('builder-logo.png')

    expect(response.body.b).to eq(stand_in.join('builder-logo.png').binread)

    allow(Brand).to receive(:builder_logo).and_return(nil) # a pack without builder_logo: the name in words
    corner = sign_in_page[%r{<div class="we-auth-builder">.*?</div>\s*</div>}m]

    expect(corner).to match(%r{<div>Sample Builder</div>\s*#{Regexp.escape(help)}})
    expect(corner).not_to include('<img')

    sign_in(User.first)
    get root_path

    expect(response.body).not_to include('we-auth-builder', 'mailto:help@example.com')
  end

  it 'refuses a builder_logo that is not a file in the pack' do
    %w[missing.png ../we-primus/logo-light.png].each do |file|
      with_pack_option('builder_logo', file)

      expect { Brand.load!('we-primus') }
        .to raise_error(Brand::Error, /sets builder_logo: #{Regexp.escape(file)}, which is not a file in the pack/)
    end
  end

  it 'shows a plain sign-in page for a pack without a photograph' do
    allow(Brand).to receive(:file?).and_call_original
    allow(Brand).to receive(:file?).with('login-photo-1920.webp').and_return(false)

    html = sign_in_page

    expect(html).to include('<body class="we-auth we-auth-plain">')
    expect(html).not_to include('we-auth-photo', 'login-photo')
  end

  # What a new client pack must contain: the check to run after adding a folder under brands/.
  it 'finds every pack complete: the files, the names and every variable the bundles read' do
    variables = %w[--p --pf --pc --s --sf --sc --a --af --ac --n --nf --nc --b1 --b2 --b3 --bc --in --inc --su
                   --suc --wa --wac --er --erc --brand-font --brand-bold --brand-radius --brand-muted --brand-raised
                   --brand-on-dark --brand-paper --brand-shadow --brand-glass-button --brand-soft
                   --brand-soft-hover --brand-soft-content --brand-line]

    expect(packs).to include('we-primus')

    packs.each do |pack|
      expect { Brand.load!(pack) }.not_to raise_error

      css = Brand::ROOT.join(pack, 'theme.css').read
      missing = variables.reject { |name| css.match?(/^\s*(?:--[\w-]+:[^;]+;\s*)*#{name}:/) }

      expect(missing).to be_empty, "brands/#{pack}/theme.css does not set #{missing.join(', ')}"
      expect(css).not_to match(%r{url\(["']?(?:https?:)?//}), "brands/#{pack}/theme.css loads from another host"
      expect(Brand.page_color).to match(/\A#\h{6}\z/)
      expect(css).to include('--brand-opening-color:') if Brand.file?('opening.mp4')
    end
  end
end

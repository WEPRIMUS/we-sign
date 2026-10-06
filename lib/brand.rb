# frozen_string_literal: true

# WE Sign: the brand pack of this installation. A pack is one folder under brands/ that holds everything which
# differs between installations and nothing else: logos, icons, one stylesheet of variables, the sign-in
# photograph, a few names (README.md, "Brand packs"). The environment variable BRAND picks
# the pack when the application starts. An unknown or incomplete pack stops the start: it never falls back.
#
# Only the selected pack is served, under /brand/<name>-<digest>/ (mounted in config/routes.rb), and of it only what
# a page uses (SERVED): never pack.yml or a licence text. The digest is taken from the pack's files, so browsers may
# keep them for good, and no other pack can be fetched.
module Brand
  Error = Class.new(StandardError)

  ROOT = Rails.root.join('brands')
  DEFAULT = 'we-primus'
  REQUIRED = %w[pack.yml theme.css logo-light.png apple-touch-icon.png icon-192.png icon-512.png].freeze
  NAMES = %w[public_name page_color].freeze
  HEADERS = %w[logo_and_name logo name].freeze
  CACHE = { 'cache-control' => 'public, max-age=31536000, immutable' }.freeze
  SERVED = %w[.css .png .webp .woff2 .mp4].freeze
  # ISO 3166-1 alpha-2: the 249 assigned codes (Debian iso-codes, data/iso_3166-1.json), for legal_country.
  COUNTRIES = %w[
    AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ
    CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO
    FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE
    JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO
    MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW
    PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM
    TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW
  ].freeze

  module_function

  def load!(name = ENV['BRAND'].presence || DEFAULT)
    name = name.to_s
    dir = ROOT.join(name)
    config = check(name, dir)
    digest = Digest::SHA256.new
    dir.glob('**/*').select(&:file?).sort.each { |file| digest << file.basename.to_s << file.binread }

    @name = name
    @dir = dir
    @config = config
    @prefix = "/brand/#{name}-#{digest.hexdigest[0, 12]}"
    @files = Rack::Files.new(dir.to_s, CACHE)
    self
  end

  # Says what is wrong with a pack, or returns its names.
  def check(name, dir)
    packs = ROOT.children.select(&:directory?).map { |d| d.basename.to_s }.sort.join(', ')

    unless name.match?(/\A[a-z0-9-]+\z/) && dir.directory?
      raise Error, "BRAND=#{name}: there is no brand pack of that name. The packs in #{ROOT} are: #{packs}."
    end

    missing = REQUIRED.reject { |file| dir.join(file).file? }
    raise Error, "BRAND=#{name}: the pack in #{dir} has no #{missing.join(', ')}." if missing.any?

    pack_yml = dir.join('pack.yml')
    config = YAML.safe_load_file(pack_yml) || {}
    unset = NAMES.reject { |key| config[key].present? }
    raise Error, "BRAND=#{name}: #{pack_yml} does not set #{unset.join(', ')}." if unset.any?

    if config.key?('header') && HEADERS.exclude?(config['header'])
      raise Error, "BRAND=#{name}: #{pack_yml} sets header: #{config['header']}; " \
                   "it is one of #{HEADERS.join(', ')}."
    end

    check_country(name, pack_yml, config)

    logo = config['builder_logo'].to_s
    if logo.present? && !(File.basename(logo) == logo && dir.join(logo).file?)
      raise Error, "BRAND=#{name}: #{pack_yml} sets builder_logo: #{logo}, which is not a file in the pack."
    end

    config
  end

  # legal_country, when the pack sets it: one of the ISO 3166 codes, written as the standard writes it.
  def check_country(name, pack_yml, config)
    return if !config.key?('legal_country') || COUNTRIES.include?(config['legal_country'])

    raise Error, "BRAND=#{name}: #{pack_yml} sets legal_country: #{config['legal_country'].inspect}; " \
                 'it is a two-letter ISO 3166 country code in capitals, such as AE (write Norway as "NO").'
  end

  def pack = @name

  # Address of a pack file for a browser.
  def url(file) = "#{@prefix}/#{file}"

  # The same file on disk, for what is drawn on the server (the audit PDF).
  def path(file) = @dir.join(file).to_s

  # Optional files: mark.png, favicon-16.png, favicon-32.png, logo-dark.png, login-photo-<width>.webp.
  def file?(file) = @dir.join(file).file?

  # The small icon: a pack without a 32 px favicon shows its 192 px icon instead.
  def favicon = file?('favicon-32.png') ? 'favicon-32.png' : 'icon-192.png'

  def public_name = @config['public_name']
  def legal_name = @config['legal_name'].presence
  def page_color = @config['page_color']

  # How the PDFs this installation draws look (the Contract Desk's generated documents): font files in the pack and
  # colours, as `document_style` in pack.yml. Empty when the pack sets none: the document then uses plain defaults.
  def document_style = @config['document_style'] || {}

  # The country of the legal entity (ISO 3166 alpha-2), the C= of the self-made signing certificate, or nil: the
  # certificate then names no country.
  def legal_country = @config['legal_country'].presence

  # A pack whose logo stands alone: no product name is printed beside it, on the sign-in panel and, unless the pack
  # sets header, in the in-app headers.
  def logo_leads_alone? = @config['logo_leads_alone'] == true

  # What the in-app headers show (staff, signer, start-form and QR pages, and the header of the audit PDF): the logo
  # and the product name (logo_and_name, the default), the logo alone (logo) or the product name alone (name). The
  # sign-in panel is not an in-app header: it follows logo_leads_alone only.
  def header = @config['header'] || (logo_leads_alone? ? 'logo' : 'logo_and_name')
  def header_logo? = header != 'name'
  def header_name? = header != 'logo'

  # One line of the pack's own under the attribution line of staff and signer pages, in plain text, or nil.
  def footer_credit = @config['footer_credit'].presence

  # The builder's signature in a corner of the sign-in photograph ("WE PRIMUS"), or nil: shown in words, or as the
  # builder's logo when the pack has builder_logo (a file in the pack; builder_credit is then its alternative text);
  # and the support address shown under it, or nil.
  def builder_credit = @config['builder_credit'].presence
  def builder_logo = @config['builder_logo'].presence
  def support_email = @config['support_email'].presence

  # The Rack application behind /brand. The first path segment is the name and digest: only a cache key.
  def call(env)
    env['PATH_INFO'] = env['PATH_INFO'].sub(%r{\A/[^/]+}, '')
    return [404, { 'content-type' => 'text/plain' }, ['Not Found']] if SERVED.exclude?(File.extname(env['PATH_INFO']))

    @files.call(env)
  end
end

Brand.load!

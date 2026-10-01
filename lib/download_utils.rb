# frozen_string_literal: true

module DownloadUtils
  LOCALHOSTS = Set[
    '0.0.0.0',
    '127.0.0.1',
    '127.0.1.1',
    'localhost',
    'localhost.localdomain',
    '::1',
    '[::1]',
    'ip6-localhost',
    'ip6-loopback',
    '127.0.0.0',
    '127.255.255.255',
    '::',
    '0:0:0:0:0:0:0:1',
    '[0:0:0:0:0:0:0:1]',
    '0000:0000:0000:0000:0000:0000:0000:0001',
    '[0000:0000:0000:0000:0000:0000:0000:0001]',
    '::0',
    '0::0',
    '::ffff:127.0.0.1',
    '[::ffff:127.0.0.1]',
    '::ffff:7f00:1',
    '[::ffff:7f00:1]',
    'local',
    'localhost.local',
    'ip6-localnet',
    'ip6-allnodes',
    'ip6-allrouters'
  ].freeze

  UnableToDownload = Class.new(StandardError)

  # WE Sign (SEC-APP-08, SEC-REL-01): limits of a server-side fetch
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30
  MAX_SIZE = 100.megabytes
  UNSPECIFIED_RANGES = [IPAddr.new('0.0.0.0/8'), IPAddr.new('::/128')].freeze

  module_function

  def call(url, validate: Docuseal.multitenant?)
    uri = begin
      URI(url)
    rescue URI::Error
      Addressable::URI.parse(url).normalize
    end

    validate_uri!(uri) if validate

    body = +''

    resp = conn(validate:).get(uri) do |req|
      req.options.on_data = proc do |chunk, received_bytes|
        raise UnableToDownload, "Error loading: #{uri}. The file is too large." if received_bytes > MAX_SIZE

        body.clear if received_bytes == chunk.bytesize # a new response, after a redirect
        body << chunk
      end
    end

    raise UnableToDownload, "Error loading: #{uri}" if resp.status >= 400

    resp.env[:body] = body

    resp
  end

  def validate_uri!(uri)
    raise UnableToDownload, "Error loading: #{uri}. Only HTTPS is allowed." if uri.scheme != 'https' ||
                                                                               [443, nil].exclude?(uri.port)
    raise UnableToDownload, "Error loading: #{uri}. Can't download from localhost." if uri.host.in?(LOCALHOSTS)

    validate_host!(uri)
  end

  # WE Sign (SEC-APP-08): the name is resolved, and every address it has must be a public one. Also used for
  # webhook and timestamp-server addresses.
  # ponytail: the name is resolved again when the connection is made; pin the checked address if anyone other
  # than staff or an API key can ever supply the address
  def validate_host!(uri)
    addresses = Resolv.getaddresses(uri.host.to_s.delete('[]'))

    return if addresses.present? && addresses.none? { |address| internal_address?(address) }

    raise UnableToDownload, "Error loading: #{uri}. The address is internal or does not resolve."
  end

  def internal_address?(address)
    ip = IPAddr.new(address).native

    ip.loopback? || ip.private? || ip.link_local? || UNSPECIFIED_RANGES.any? { |range| range.include?(ip) }
  end

  def conn(validate: Docuseal.multitenant?)
    Faraday.new(request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }) do |faraday|
      faraday.response :follow_redirects, callback: lambda { |_, new_env|
        validate_uri!(new_env[:url]) if validate
      }
    end
  end
end

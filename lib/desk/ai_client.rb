# frozen_string_literal: true

module Desk
  # One OpenAI-compatible chat endpoint per installation: DESK_AI_ENDPOINT (e.g. https://api.deepseek.com, or
  # https://api.openai.com/v1), DESK_AI_MODEL and DESK_AI_API_KEY. Swapping the provider or a local model is a change
  # of these three settings, not of code. The AI only returns data; it holds no credential of the app and no code
  # path from here can send anything.
  #
  # Server-side fetch guard (SEC-APP-08): only the configured endpoint is ever called, over HTTPS to a public address,
  # and redirects are not followed. DESK_AI_ALLOW_INTERNAL=true lets that one configured host be internal or plain
  # HTTP (a model on the same network); it opens nothing else.
  module AiClient
    Error = Class.new(StandardError)
    NotConfigured = Class.new(Error)

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 240
    ATTEMPTS = 3
    RETRY_STATUSES = [408, 409, 429, 500, 502, 503, 504].freeze

    module_function

    def settings
      {
        endpoint: ENV['DESK_AI_ENDPOINT'].to_s.strip.delete_suffix('/').presence,
        model: ENV['DESK_AI_MODEL'].to_s.strip.presence,
        key: ENV['DESK_AI_API_KEY'].to_s.strip.presence,
        allow_internal: ENV['DESK_AI_ALLOW_INTERNAL'] == 'true'
      }
    end

    def configured? = settings.values_at(:endpoint, :model, :key).all?

    def model = settings[:model]

    def endpoint_host = settings[:endpoint] && Addressable::URI.parse(settings[:endpoint]).host

    # Sends chat messages and returns the reply parsed as a JSON object. Bounded: ATTEMPTS tries on timeouts, rate
    # limits and server errors, then Error. Never returns an empty or made-up result.
    def chat_json(messages, max_tokens: 16_000)
      config = settings

      unless configured?
        raise NotConfigured, 'The AI provider is not set up (DESK_AI_ENDPOINT, DESK_AI_MODEL, DESK_AI_API_KEY)'
      end

      uri = Addressable::URI.parse("#{config[:endpoint]}/chat/completions")
      guard!(uri, allow_internal: config[:allow_internal])

      body = { model: config[:model], temperature: 0, max_tokens:, response_format: { type: 'json_object' },
               messages: }.to_json

      Automation.run { parse(post(uri, body, config[:key])) }
    end

    def guard!(uri, allow_internal:)
      return if allow_internal

      raise Error, 'The AI endpoint must use HTTPS' if uri.scheme != 'https' || [443, nil].exclude?(uri.port)

      DownloadUtils.validate_host!(uri)
    rescue DownloadUtils::UnableToDownload
      raise Error, "The AI endpoint #{uri.host} is internal or does not resolve"
    end

    def post(uri, body, key)
      attempt = 0

      begin
        attempt += 1

        response = Faraday.new(request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }).post(uri.to_s) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Authorization'] = "Bearer #{key}"
          req.body = body
        end

        raise Error, "The AI answered #{response.status}" if RETRY_STATUSES.include?(response.status)
        if response.status >= 300
          raise Error,
                "The AI refused the request (#{response.status}): #{error_text(response)}"
        end

        response.body
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Error => e
        raise if e.message.start_with?('The AI refused') || attempt >= ATTEMPTS

        sleep(retry_wait(attempt))
        retry
      end
    end

    def retry_wait(attempt) = 2 * attempt

    def parse(raw)
      content = JSON.parse(raw).dig('choices', 0, 'message', 'content').to_s
      content = content.strip.delete_prefix('```json').delete_prefix('```').delete_suffix('```').strip

      result = JSON.parse(content)

      raise Error, 'The AI reply was not a JSON object' unless result.is_a?(Hash)

      result
    rescue JSON::ParserError
      raise Error, 'The AI reply could not be read'
    end

    def error_text(response)
      JSON.parse(response.body).dig('error', 'message').to_s.truncate(200)
    rescue JSON::ParserError
      response.body.to_s.truncate(200)
    end
  end
end

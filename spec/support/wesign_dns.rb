# frozen_string_literal: true

# WE Sign: the server-side fetch guard resolves host names. Specs must not depend on a DNS server, so every
# name resolves to a public documentation address here; a spec that needs another answer stubs it itself.
RSpec.configure do |config|
  config.before do
    allow(Resolv).to receive(:getaddresses) { |host| host.match?(/\A[\d.]+\z|:/) ? [host] : ['203.0.113.10'] }
  end
end

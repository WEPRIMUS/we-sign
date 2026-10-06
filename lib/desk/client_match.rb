# frozen_string_literal: true

module Desk
  # Finds the document's client in the register (by tax number, then by legal name), or creates it as
  # "new: please confirm" with its source. Deterministic: the AI only read the name and numbers.
  module ClientMatch
    module_function

    def call(document)
      party = Signers.parties(document).find { |p| !p['own'] }

      return unless party

      client = Client.match(document.account_id, legal_name: party['legal_name'], tax_number: party['tax_number'])
      action = client ? 'client matched' : 'client created: new, please confirm'
      client ||= create!(document, party)

      document.update!(client:)
      document.log!(action, actor: 'system', data: { client_id: client.id, legal_name: client.legal_name })

      client
    end

    def create!(document, party)
      Client.create!(account_id: document.account_id, legal_name: party['legal_name'],
                     trading_name: party['trading_name'], country: party['country'], address: party['address'],
                     tax_number: party['tax_number'], status: 'new_please_confirm',
                     source: "Read from the document \"#{document.name}\"", source_document_id: document.id,
                     created_by_user_id: document.created_by_user_id)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      Client.match(document.account_id, legal_name: party['legal_name'], tax_number: party['tax_number']) || raise
    end
  end
end

# frozen_string_literal: true

# Contract Desk: synthetic test data for a LOCAL trial only (fictional companies, people and numbers).
namespace :desk do
  def desk_local_trial!
    host = Docuseal.default_url_options[:host].to_s

    return if %w[127.0.0.1 localhost ::1].include?(host)

    abort "Refused: the desk's test data is for a local trial only (this app answers at #{host})."
  end

  desc 'Local trial only: the three fictional clients (UAE, KSA, Australia), signers at name+uae@, +ksa@, +au@ ...'
  task :seed, %i[email account_id] => :environment do |_, args|
    desk_local_trial!

    local, domain = args[:email].to_s.split('@', 2)
    abort 'Give the address the test addresses are made from: bin/rails "desk:seed[name@example.com]"' if domain.blank?

    account = args[:account_id].present? ? Account.find(args[:account_id]) : Account.order(:id).first

    Desk::SyntheticDocuments::CLIENTS.each do |client|
      if Desk::Client.match(account.id, legal_name: client[:legal_name], tax_number: client[:tax_number])
        puts "already in the register: #{client[:legal_name]}"
        next
      end

      signers = client[:signers].each_with_index.map do |signer, index|
        signer.merge(email: "#{local}+#{client[:tag]}#{index + 1 if index.positive?}@#{domain}")
      end

      created = Desk::Client.create!(account_id: account.id, **client.except(:tag, :signers), signers:,
                                     source: 'Synthetic test data (desk:seed)', confirmed_at: Time.current)
      Desk::Event.log!(account_id: account.id, client: created, action: 'client added: synthetic test data',
                       actor: 'system')
      puts "added: #{created.legal_name} (#{signers.pluck(:email).join(', ')})"
    end
  end

  desc 'Local trial only: writes the three synthetic test PDFs to a folder (own party: the brand pack legal name)'
  task :synthetic_pdfs, %i[dir] => :environment do |_, args|
    desk_local_trial!

    dir = Pathname(args[:dir].presence || Rails.root.join('tmp/desk-synthetic'))
    dir.mkpath

    Desk::SyntheticDocuments.all(Brand.legal_name || Docuseal.product_name).each do |name, pdf|
      dir.join(name).binwrite(pdf)
      puts dir.join(name)
    end
  end
end

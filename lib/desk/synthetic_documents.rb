# frozen_string_literal: true

# rubocop:disable Metrics
module Desk
  # Contract Desk: three fictional test documents, made on demand (never stored in a client's register).
  # (a) a clean two-party service agreement with a two-column signature block, (b) a client-style contract with
  # stacked signature blocks and one blank date, (c) a one-page letter that is only a scanned image (no text layer).
  # Every company, person and number in them is invented. The installation's own party is passed in.
  module SyntheticDocuments
    CLIENTS = [
      {
        legal_name: 'Saffron Dune Logistics L.L.C.', country: 'AE', default_currency: 'AED', payment_terms: '30 days',
        address: 'Unit 1408, Palm Grove Business Centre, Al Barsha, Dubai, United Arab Emirates',
        tax_number: '100234567800003', tag: 'uae',
        signers: [{ name: 'Layla Haddad', role: 'Operations Director' }]
      },
      {
        legal_name: 'Najd Falcon Drilling Services Co.', country: 'SA', default_currency: 'SAR',
        payment_terms: '45 days',
        address: 'Building 14, Al Olaya District, Riyadh 12211, Kingdom of Saudi Arabia',
        tax_number: '300987654300003', tag: 'ksa',
        signers: [{ name: 'Faisal Al-Qahtani', role: 'General Manager' }]
      },
      {
        legal_name: 'Wattle Creek Minerals Pty Ltd', country: 'AU', default_currency: 'AUD', payment_terms: '14 days',
        address: 'Level 9, 120 Kestrel Lane, Perth WA 6000, Australia',
        tax_number: '51 824 753 556', tag: 'au',
        signers: [{ name: 'Hannah Reid', role: 'Director' }, { name: 'Tom Brennan', role: 'Company Secretary' }]
      }
    ].freeze

    FONT = 'Helvetica'

    module_function

    def all(own_name)
      {
        'a-service-agreement-uae.pdf' => service_agreement(own_name),
        'b-client-contract-ksa.pdf' => client_contract(own_name),
        'c-scanned-letter-au.pdf' => scanned_letter(own_name)
      }
    end

    def service_agreement(own_name)
      client = CLIENTS[0]

      composer = HexaPDF::Composer.new(page_size: :A4, margin: 56)
      composer.style(:base, font: FONT, font_size: 10.5, line_spacing: 1.3, margin: [0, 0, 8])
      composer.style(:h1, font: "#{FONT} bold", font_size: 17, margin: [0, 0, 4])
      composer.style(:h2, font: "#{FONT} bold", font_size: 11, margin: [10, 0, 4])

      composer.text('SERVICES AGREEMENT', style: :h1)
      composer.text('Reference: SA-2026-014   Revision: 0   Date: 12 October 2026')
      composer.text("This Services Agreement is made between #{own_name}, Sharjah, United Arab Emirates " \
                    "(the \"Provider\"), and #{client[:legal_name]}, #{client[:address]}, Tax Registration " \
                    "Number #{client[:tax_number]} (the \"Client\").")
      composer.text('1. Services', style: :h2)
      composer.text('The Provider sets up a fleet-tracking dashboard for the Client and supports it every month, ' \
                    'as described in Schedule 1.')
      composer.text('2. Fees', style: :h2)
      composer.text('One-time set-up fee: AED 18,500.00')
      composer.text('Monthly support fee: AED 1,200.00 per month')
      composer.text('VAT at 5% is added to each invoice.')
      composer.text('3. Term', style: :h2)
      composer.text('This Agreement starts on 1 November 2026 and runs for twelve (12) months.')
      composer.text('4. Payment', style: :h2)
      composer.text('Invoices are payable within thirty (30) days of the invoice date.')
      composer.text('5. Governing law', style: :h2)
      composer.text('This Agreement is governed by the laws of the Emirate of Dubai and the federal laws of the ' \
                    'United Arab Emirates.')

      composer.new_page
      canvas = composer.canvas
      canvas.font(FONT, variant: :bold, size: 12).text('SIGNED by the parties on the dates below.', at: [56, 770])

      [[56, own_name, nil, nil], [310, client[:legal_name], *client[:signers][0].values_at(:name, :role)]]
        .each do |x, party, name, role|
        canvas.font(FONT, size: 10.5)
        canvas.text('For and on behalf of', at: [x, 720])
        canvas.font(FONT, variant: :bold, size: 10.5).text(party, at: [x, 704])
        canvas.font(FONT, size: 10.5)
        canvas.text(name ? "Name: #{name}" : 'Name: ______________________', at: [x, 660])
        canvas.text(role ? "Title: #{role}" : 'Title: ______________________', at: [x, 630])
        canvas.text('Signature: ___________________', at: [x, 570])
        canvas.text('Date: _______________________', at: [x, 530])
      end

      write(composer)
    end

    def client_contract(own_name)
      client = CLIENTS[1]
      company = client[:legal_name].sub(/ Co\.\z/, ' Company') # the contract writes the name out in full

      composer = HexaPDF::Composer.new(page_size: :A4, margin: [50, 64, 50, 64])
      composer.style(:base, font: 'Times', font_size: 11, line_spacing: 1.25, margin: [0, 0, 7])
      composer.style(:h1, font: 'Times bold', font_size: 15, text_align: :center, margin: [0, 0, 2])
      composer.style(:center, font: 'Times', font_size: 11, text_align: :center, margin: [0, 0, 12])
      composer.style(:article, font: 'Times bold', font_size: 11, margin: [8, 0, 3])

      composer.text('CONSULTANCY SERVICES CONTRACT', style: :h1)
      composer.text('Contract No. NFD-CSC-2026-0457', style: :center)
      composer.text("FIRST PARTY: #{company}, Commercial Registration 1010654321, VAT No. #{client[:tax_number]}, " \
                    "#{client[:address]}, hereinafter the \"First Party\".")
      composer.text("SECOND PARTY: #{own_name}, United Arab Emirates, hereinafter the \"Second Party\".")
      composer.text('Article 1 - Scope of Work', style: :article)
      composer.text('The Second Party shall provide a drilling-data reporting portal and monthly reporting for the ' \
                    'First Party, as set out in Appendix A.')
      composer.text('Article 2 - Contract Value', style: :article)
      composer.text('The contract value is SAR 96,000.00 (Ninety-six thousand Saudi Riyals), exclusive of Value ' \
                    'Added Tax at 15%.')
      composer.text('Article 3 - Duration', style: :article)
      composer.text('Commencement date: ____________________')
      composer.text('Duration: six (6) months from the commencement date.')
      composer.text('Article 4 - Payment', style: :article)
      composer.text('The First Party shall pay each approved invoice within forty-five (45) days.')
      composer.text('Article 5 - Governing Law', style: :article)
      composer.text('This Contract is governed by the laws of the Kingdom of Saudi Arabia.')

      composer.new_page
      canvas = composer.canvas
      canvas.font('Times', variant: :bold, size: 12).text('IN WITNESS WHEREOF the Parties have signed this Contract.',
                                                          at: [64, 780])

      [[730, 'FIRST PARTY', company, client[:signers][0]], [430, 'SECOND PARTY', own_name, nil]]
        .each do |y, label, party, signer|
        canvas.font('Times', variant: :bold, size: 11).text("#{label}: #{party}", at: [64, y])
        canvas.font('Times', size: 11)
        canvas.text(signer ? "Name: #{signer[:name]}" : 'Name: ______________________________', at: [64, y - 40])
        canvas.text(signer ? "Position: #{signer[:role]}" : 'Position: ____________________________',
                    at: [64, y - 75])
        canvas.text('Signature: ___________________________', at: [64, y - 130])
        canvas.text('Date: ________________________________', at: [64, y - 170])
        canvas.text('Company Stamp:', at: [360, y - 40])
        canvas.rectangle(360, y - 175, 150, 120).stroke
      end

      write(composer)
    end

    def scanned_letter(own_name)
      client = CLIENTS[2]
      director, secretary = client[:signers]

      composer = HexaPDF::Composer.new(page_size: :A4, margin: 60)
      composer.style(:base, font: FONT, font_size: 10.5, line_spacing: 1.3, margin: [0, 0, 8])
      composer.style(:h1, font: "#{FONT} bold", font_size: 14, margin: [0, 0, 10])

      composer.text(client[:legal_name].upcase, style: :h1)
      composer.text("ABN #{client[:tax_number]}  |  #{client[:address]}")
      composer.text('Date: 2 October 2026')
      composer.text('ACCESS AUTHORISATION AND ACCEPTANCE', style: :h1)
      composer.text("#{client[:legal_name]} authorises #{own_name} to access its exploration document portal " \
                    'for the purpose of the geological data study described in the proposal dated ' \
                    '15 September 2026, until 31 March 2027.')
      composer.text('The study fee of AUD 24,000.00 plus GST is payable as set out in the proposal.')
      composer.text("Executed by #{client[:legal_name]} in accordance with section 127 of the Corporations Act " \
                    '2001 (Cth):')

      canvas = composer.canvas
      [[60, 'Director', director], [320, 'Director / Company Secretary', secretary]].each do |x, label, signer|
        canvas.font(FONT, size: 10.5)
        canvas.text('_____________________________', at: [x, 400])
        canvas.text("Signature of #{label}", at: [x, 385])
        canvas.text("Name: #{signer[:name]}", at: [x, 365])
        canvas.text('Date: _______________________', at: [x, 330])
      end
      canvas.font(FONT, variant: :bold, size: 10.5).text("Accepted for #{own_name}", at: [60, 270])
      canvas.font(FONT, size: 10.5)
      canvas.text('Signature: ___________________', at: [60, 230])
      canvas.text('Name: ________________________', at: [60, 200])
      canvas.text('Date: ________________________', at: [60, 170])

      image_only_pdf(write(composer))
    end

    def write(composer)
      io = StringIO.new
      composer.write(io)
      io.string
    end

    # A "scan": the page rendered to a slightly turned, grainy grey image, then put back in a PDF as a picture only.
    def image_only_pdf(pdf)
      doc = Pdfium::Document.open_bytes(pdf)
      page = doc.get_page(0)
      bytes, width, height = page.render_to_bitmap(width: 1654)
      page.close
      doc.close

      image = Vips::Image.new_from_memory_copy(bytes, width, height, 4, :uchar).extract_band(0, n: 3)
      image = image.colourspace(:b_w).similarity(angle: 0.4, background: [246])
      image = (image + Vips::Image.gaussnoise(image.width, image.height, sigma: 7)).cast(:uchar)
      jpeg = image.write_to_buffer('.jpg', Q: 70)

      out = HexaPDF::Document.new
      out.pages.add(:A4).canvas.image(StringIO.new(jpeg), at: [0, 0], width: 595, height: 842)
      io = StringIO.new
      out.write(io)
      io.string
    end
  end
end
# rubocop:enable Metrics

# frozen_string_literal: true

# Contract Desk: who signs for our side, the names of the signing parties, and the boxes of a signature page set as a
# ruled table under headings in spaced capitals. The AI is never called.
RSpec.describe 'Contract Desk signing page', :desk do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, first_name: 'Desk', last_name: 'Approver', email: 'approver@northwind.example') }
  let(:settings) do
    desk_settings_for(account, own_profile: DeskSpecHelpers::PROFILE.merge('signer_name' => 'Tomás de Exemplo',
                                                                           'signer_email' => user.email))
  end

  before { desk_ai_configured! }

  def fact(document, key, value)
    Desk::Fact.create!(account_id: account.id, document:, key:, value:, origin: 'ai', status: 'validated', run_id: 'r')
  end

  # A document whose reading gave our party (p1) with the printed signer name, and the client (p2) with its lines.
  def read_document(own_printed, client_lines = [{}])
    document = Desk::Document.create!(account_id: account.id, created_by_user: user, title: 'Variation',
                                      file_sha256: SecureRandom.hex(32))
    fact(document, 'party', { 'key' => 'p1', 'legal_name' => DeskSpecHelpers::OWN, 'own' => true })
    fact(document, 'party', { 'key' => 'p2', 'legal_name' => 'Wattle Creek Minerals Pty Ltd', 'own' => false })
    fact(document, 'signer', { 'party_key' => 'p1', 'name' => own_printed })
    client_lines.each { |line| fact(document, 'signer', { 'party_key' => 'p2', **line }) }
    document
  end

  def own_slot(printed) = Desk::Signers.plan(read_document(printed), settings).find(&:own)

  describe 'our own signer' do
    it 'is the user whose e-mail is that of the Our company signatory, the name printed shorter or longer' do
      ['Exemplo', 'Tomás de Exemplo', 'TOMAS DE EXEMPLO', 'Tomas De Jesus Andrade Exemplo'].each do |printed|
        slot = own_slot(printed)

        expect(slot).to have_attributes(approver: true, signer_user_id: user.id, email: user.email), printed
      end
    end

    it 'is the user of that full name, accents and case ignored' do
      named = create(:user, account:, first_name: 'Inês', last_name: 'Marçal', email: 'ines@northwind.example')

      expect(own_slot('INES MARCAL')).to have_attributes(approver: true, signer_user_id: named.id)
    end

    it 'signs only on the click of that person' do
      other = create(:user, account:, first_name: 'Other', last_name: 'Person')
      slot = own_slot('Exemplo')

      expect(slot.signed_by?(user)).to be(true)
      expect(slot.signed_by?(other)).to be(false)
    end

    it 'is nobody for a name that is not the signatory, and the document says it cannot reach that person' do
      slot = own_slot('Ana Exemplo')

      expect(slot).to have_attributes(approver: false, signer_user_id: nil, email: nil)
      expect(Desk::Signers.own_problems([slot]).join).to include('Ana Exemplo signs for', 'has no e-mail address')
    end

    it 'is never a user of another account with that e-mail' do
      settings.update!(own_profile: settings.own_profile.merge('signer_email' => 'elsewhere@northwind.example'))
      create(:user, account: create(:account), email: 'elsewhere@northwind.example')

      expect(own_slot('Exemplo')).to have_attributes(approver: false, signer_user_id: nil,
                                                     email: 'elsewhere@northwind.example')
    end
  end

  describe 'the name of each signing party in WE Sign' do
    def labels(lines) = Desk::Signers.plan(read_document('Exemplo', lines), settings).reject(&:own).map(&:label)

    it 'names two signers of one party apart' do
      expect(labels([{ 'name' => 'Hannah Reid', 'title' => 'Director' },
                     { 'name' => 'Tom Brennan', 'title' => 'Director' }]))
        .to eq(['Wattle Creek Minerals Pty Ltd - Hannah Reid', 'Wattle Creek Minerals Pty Ltd - Tom Brennan'])
    end

    it 'numbers them when no name is known' do
      expect(labels([{ 'title' => 'Director' }, { 'title' => 'Director' }]))
        .to eq(['Wattle Creek Minerals Pty Ltd - Director 1', 'Wattle Creek Minerals Pty Ltd - Director 2'])
    end

    it 'keeps the title for one signer, and for signers with different titles' do
      expect(labels([{ 'name' => 'Hannah Reid', 'title' => 'Director' }]))
        .to eq(['Wattle Creek Minerals Pty Ltd - Director'])
      expect(labels([{ 'name' => 'Hannah Reid', 'title' => 'Director' },
                     { 'name' => 'Tom Brennan', 'title' => 'Secretary' }]))
        .to eq(['Wattle Creek Minerals Pty Ltd - Director', 'Wattle Creek Minerals Pty Ltd - Secretary'])
    end
  end

  describe 'a signature table under headings in spaced capitals' do
    let(:client) { 'Wattle Creek Minerals Pty Ltd' }
    let(:parties) do
      [{ 'key' => 'p1', 'legal_name' => DeskSpecHelpers::OWN, 'own' => true },
       { 'key' => 'p2', 'legal_name' => client, 'own' => false }]
    end
    let(:slots) do
      slot = Desk::Signers::Slot
      [slot.new(key: 'own-1', party_key: 'p1', party_name: DeskSpecHelpers::OWN, own: true, approver: true,
                uuid: 'own'),
       slot.new(key: 'p2-1', party_key: 'p2', party_name: client, own: false, name: 'Hannah Reid', uuid: 'first'),
       slot.new(key: 'p2-2', party_key: 'p2', party_name: client, own: false, name: 'Tom Brennan', uuid: 'second')]
    end

    it 'gives each box to the party under whose heading it stands, and each block to its own director' do
      pdf = Desk::SyntheticDocuments.signature_table(DeskSpecHelpers::OWN)
      attachment = Struct.new(:uuid) { def image? = false }.new('page')

      result = Desk::FieldPlacement.call(attachment:, data: pdf, slots:, parties:)

      boxes = result.fields.group_by { |f| f['submitter_uuid'] }.transform_values do |fields|
        fields.map { |f| [f['name'], f['areas'][0]['x'] < 0.5 ? :left : :right, f['areas'][0]['y'].round(1)] }
      end
      expect(result.problems).to be_empty
      # our printed name and every printed title get no box; each blank Name line gets one, filled in
      expect(boxes['own']).to contain_exactly(['Date', :left, 0.3], ['Signature', :left, 0.3])
      expect(boxes['first']).to contain_exactly(['Name', :right, 0.2], ['Date', :right, 0.3],
                                                ['Signature', :right, 0.3])
      expect(boxes['second']).to contain_exactly(['Name', :right, 0.4], ['Date', :right, 0.5],
                                                 ['Signature', :right, 0.5])
      expect(result.fields.select { |f| f['name'] == 'Name' }.pluck('default_value'))
        .to eq(['Hannah Reid', 'Tom Brennan'])
      expect(a_request(:post, DeskSpecHelpers::AI_URL)).not_to have_been_made
    end

    it 'reads a heading letter by letter or joined, and only a heading in capitals' do
      expect(Desk::FieldPlacement.party_named('F O R N O R T H W I N D S T U D I O F Z E', parties)['key']).to eq('p1')
      expect(Desk::FieldPlacement.party_named('FORWATTLECREEKMINERALSPTYLTD', parties)['key']).to eq('p2')
      expect(Desk::FieldPlacement.party_named('Reviewed by northwindstudio staff', parties)).to be_nil
    end
  end
end

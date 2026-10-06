# frozen_string_literal: true

# Contract Desk: the deterministic rules (state machine, numbering, client register, reminders, event log, the AI
# boundary). The AI is never called.
RSpec.describe 'Contract Desk rules', :desk do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before { desk_ai_configured! }

  describe 'the state machine' do
    let(:document) { desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement)) }

    it 'follows the agreed steps and logs each one' do
      document.transition!('waiting_for_you', actor: 'system')
      document.transition!('preparing', actor: 'person', user:)
      document.transition!('ready_to_send', actor: 'system')

      expect(document.events.pluck(:action)).to eq(['state preparing -> waiting_for_you',
                                                    'state waiting_for_you -> preparing',
                                                    'state preparing -> ready_to_send'])
    end

    it 'refuses a step that is not in the flow' do
      expect { document.transition!('signed', actor: 'system') }.to raise_error(Desk::Document::InvalidTransition)
      expect { document.transition!('opened', actor: 'system') }.to raise_error(Desk::Document::InvalidTransition)
      expect(document.reload.state).to eq('preparing')
    end

    it 'never leaves archived' do
      document.transition!('archived', actor: 'person', user:)

      Desk::Document::STATES.each do |state|
        expect { document.transition!(state, actor: 'person', user:) }.to raise_error(Desk::Document::InvalidTransition)
      end
    end

    it 'moves to sent only with a person approval' do
      document.update!(state: 'ready_to_send')

      expect { document.transition!('sent', actor: 'system') }.to raise_error(Desk::Approval::NotAllowed)
      expect { document.transition!('sent', actor: 'person', user:) }.to raise_error(Desk::Approval::NotAllowed)
      expect(document.reload.state).to eq('ready_to_send')
    end

    it 'never deletes a document, a client or a fact' do
      client = saffron_client(account)

      expect { document.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { client.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe 'what code reads itself (never the AI)' do
    it 'turns only one complete date into a calendar date' do
      expect(Desk::Reader.parse_date('12 October 2026')).to eq('2026-10-12')
      expect(Desk::Reader.parse_date('October 12, 2026')).to eq('2026-10-12')
      expect(Desk::Reader.parse_date('03/04/2026')).to eq('2026-04-03')
      expect(Desk::Reader.parse_date('January to June 2027')).to be_nil
      expect(Desk::Reader.parse_date('June 2027')).to be_nil
      expect(Desk::Reader.parse_date('within thirty (30) days')).to be_nil
    end

    it 'reads an amount and its currency, and never takes a rate for an amount' do
      expect(Desk::Reader.parse_amount('AED 18,500.00')).to eq('18500.0')
      expect(Desk::Reader.parse_amount('AUD 7,500.00 (AUD 1,250.00 with each)')).to eq('7500.0')
      expect(Desk::Reader.parse_amount('5%')).to be_nil
      expect(Desk::Reader.currency('SAR 96,000.00 (Ninety-six thousand Saudi Riyals)')).to eq('SAR')
      expect(Desk::Reader.currency('A$ 1,200')).to eq('AUD')
    end

    it 'keys a tax number on the number alone' do
      expect(Desk::Normalize.tax('ABN 51 824 753 556')).to eq('51824753556')
      expect(Desk::Normalize.tax('VAT No. 300987654300003')).to eq('300987654300003')
      expect(Desk::Normalize.tax('TRN: 100-234-567-800-003')).to eq('100234567800003')
    end
  end

  describe 'the numbering register' do
    it 'gives the next number of each series, per account, prefix and year' do
      numbers = Array.new(3) { Desk::NumberRegister.next!(account_id: account.id, prefix: 'SP-VAR', year: 2026) }
      other_year = Desk::NumberRegister.next!(account_id: account.id, prefix: 'SP-VAR', year: 2027)
      other_account = Desk::NumberRegister.next!(account_id: create(:account).id, prefix: 'SP-VAR', year: 2026)

      expect(numbers).to eq(%w[SP-VAR-2026-001 SP-VAR-2026-002 SP-VAR-2026-003])
      expect([other_year, other_account]).to eq(%w[SP-VAR-2027-001 SP-VAR-2026-001])
    end
  end

  describe 'the client register' do
    let!(:client) { saffron_client(account) }

    it 'matches the same company written differently' do
      expect(Desk::Client.match(account.id, legal_name: 'SAFFRON DUNE LOGISTICS LLC')).to eq(client)
      expect(Desk::Client.match(account.id, legal_name: 'The Saffron Dune Logistics, L.L.C')).to eq(client)
      expect(Desk::Client.match(account.id, legal_name: 'Another name', tax_number: '1002 3456 7800 003')).to eq(client)
      expect(Desk::Client.match(account.id, legal_name: 'Saffron Dune Trading L.L.C.')).to be_nil
    end

    it 'refuses a second client with the same legal name or tax number' do
      same_name = Desk::Client.new(account_id: account.id, legal_name: 'Saffron Dune Logistics LLC',
                                   source: 'Added by hand')
      same_tax = Desk::Client.new(account_id: account.id, legal_name: 'Other Co', tax_number: '100-234-567-800-003',
                                  source: 'Added by hand')

      expect(same_name).not_to be_valid
      expect(same_tax).not_to be_valid
    end

    it 'is held by the database too, whatever the code does' do
      expect do
        Desk::Client.insert_all!([{ account_id: account.id, legal_name: 'x', normalized_name: client.normalized_name,
                                    source: 's', status: 'confirmed', signers: [] }])
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'never matches a client of another account' do
      other = create(:account)

      expect(Desk::Client.match(other.id, legal_name: client.legal_name, tax_number: client.tax_number)).to be_nil
    end
  end

  describe 'the reminder schedule' do
    let(:document) { desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement)) }
    let(:sent_at) { Time.zone.parse('2026-10-05 09:00') }

    before { document.update!(sent_at:) }

    def due(now) = Desk::FollowUp.due_days(document, [3, 7, 14], now)

    it 'is due on days 3, 7 and 14 after sending' do
      expect(due(sent_at + 2.days + 23.hours)).to eq([])
      expect(due(sent_at + 3.days)).to eq([3])

      document.update!(reminders_sent: [3])

      expect(due(sent_at + 6.days)).to eq([])
      expect(due(sent_at + 7.days)).to eq([7])

      document.update!(reminders_sent: [3, 7])

      expect(due(sent_at + 14.days + 1.hour)).to eq([14])
    end

    it 'sends one reminder, not three, after a long stop' do
      expect(due(sent_at + 15.days)).to eq([3, 7, 14])
    end

    it 'follows the days set for the account' do
      expect(Desk::FollowUp.due_days(document, [2, 5], sent_at + 2.days)).to eq([2])
    end
  end

  describe 'the event log' do
    let!(:event) { Desk::Event.log!(account_id: account.id, action: 'test', actor: 'system') }

    it 'cannot be changed or removed through the application' do
      expect { event.update!(action: 'changed') }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { event.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it 'cannot be changed or removed in the database (trigger of the migration)' do
      require Rails.root.join('db/migrate/20261005100000_create_desk_tables.rb')
      ActiveRecord::Base.connection.execute(CreateDeskTables::APPEND_ONLY_SQL)

      savepoint = ->(&block) { ActiveRecord::Base.transaction(requires_new: true, &block) }

      expect { savepoint.call { Desk::Event.where(id: event.id).update_all(action: 'changed') } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { savepoint.call { Desk::Event.where(id: event.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect(event.reload.action).to eq('test')
    end
  end

  describe 'a failed AI call' do
    let(:document) { desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement)) }

    before { desk_settings_for(account) }

    it 'leaves the document waiting for a person, with the error shown and no made-up result' do
      stub_request(:post, DeskSpecHelpers::AI_URL).to_return(status: 503, body: '{"error":{"message":"busy"}}')

      run_pipeline(document)

      expect(a_request(:post, DeskSpecHelpers::AI_URL)).to have_been_made.times(Desk::AiClient::ATTEMPTS)
      expect(document.state).to eq('waiting_for_you')
      expect(document.last_error).to match(/AI answered 503/)
      expect(document.facts).to be_empty
      expect(document.questions).to be_empty
      expect(document.template).to be_nil
      expect(document.events.pluck(:action)).to include('failed')
    end

    it 'does not try again when the provider refuses the request' do
      stub_request(:post, DeskSpecHelpers::AI_URL).to_return(status: 401, body: '{"error":{"message":"bad key"}}')

      run_pipeline(document)

      expect(a_request(:post, DeskSpecHelpers::AI_URL)).to have_been_made.once
      expect(document.last_error).to match(/refused the request \(401\): bad key/)
    end

    it 'treats a reply that is not JSON as a failure' do
      not_json = { choices: [{ message: { content: 'Sure! Here is the summary you asked for.' } }] }
      stub_request(:post, DeskSpecHelpers::AI_URL).to_return(status: 200, body: not_json.to_json)

      run_pipeline(document)

      expect(document.state).to eq('waiting_for_you')
      expect(document.last_error).to match(/could not be read/)
      expect(document.facts).to be_empty
    end

    it 'is never made to an internal address' do
      allow(Desk::AiClient).to receive(:settings)
        .and_return(endpoint: 'https://ai.internal/v1', model: 'm', key: 'k', allow_internal: false)
      allow(Resolv).to receive(:getaddresses).with('ai.internal').and_return(['10.0.0.8'])

      run_pipeline(document)

      expect(a_request(:post, /ai.internal/)).not_to have_been_made
      expect(document.last_error).to match(/internal or does not resolve/)
    end
  end

  describe 'the AI and the jobs cannot send' do
    let(:document) do
      desk_upload(account:, user:, pdf: synthetic_pdf(:service_agreement)).tap do |d|
        d.update!(state: 'ready_to_send')
      end
    end

    it 'refuses Desk::Sender inside any automated path, even with a real approval' do
      approval = approval_for(with_two_factor(user))

      expect { Desk::Automation.run { Desk::Sender.call(document, approval) } }.to raise_error(Desk::Approval::NotAllowed)
      expect(document.reload.state).to eq('ready_to_send')
    end

    it 'refuses Desk::Sender without a person approval' do
      expect { Desk::Sender.call(document, nil) }.to raise_error(Desk::Approval::NotAllowed)
      expect { Desk::Sender.call(document, Struct.new(:user).new(user)) }.to raise_error(Desk::Approval::NotAllowed)
    end

    it 'gives no approval without two-factor sign-in, a POST, or the person own session' do
      request = ActionDispatch::TestRequest.create('REQUEST_METHOD' => 'POST')
      request.env['warden'] = instance_double(Warden::Proxy, user:)

      expect { Desk::Approval.from_request!(request:, user:, true_user: user) }
        .to raise_error(Desk::Approval::NotAllowed, /two-factor/)

      with_two_factor(user)
      get_request = ActionDispatch::TestRequest.create('REQUEST_METHOD' => 'GET')
      get_request.env['warden'] = instance_double(Warden::Proxy, user:)

      expect { Desk::Approval.from_request!(request: get_request, user:, true_user: user) }
        .to raise_error(Desk::Approval::NotAllowed)
      expect { Desk::Approval.from_request!(request:, user:, true_user: create(:user, account:)) }
        .to raise_error(Desk::Approval::NotAllowed)
      expect { Desk::Approval.new(user:, request:) }.to raise_error(NoMethodError)
    end

    it 'has the jobs leave a ready document unsent' do
      document.update!(follow_up_token: 'abc')

      Desk::ProcessDocumentJob.new.perform('document_id' => document.id)
      Desk::FollowUpJob.new.perform('document_id' => document.id, 'token' => 'abc')

      expect(document.reload.state).to eq('ready_to_send')
      expect(Sidekiq::Worker.jobs.pluck('class')).not_to include('SendSubmitterInvitationEmailJob')
    end
  end
end

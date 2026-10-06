# frozen_string_literal: true

# Contract Desk in a real browser: while the desk prepares a document, the page refreshes itself, also when it was
# reached by a link inside the app (a Turbo visit, where an inline script is refused by the content security policy),
# and again after each refresh (Turbo morphs the same page and keeps the element, so one timer would fire only once).
RSpec.describe 'Contract Desk refresh', :desk do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before do
    desk_settings_for(account)
    sign_in(user)
  end

  def preparing(title)
    Desk::Document.create!(account_id: account.id, created_by_user: user, source: 'generated', doc_type: 'variation',
                           title:, state: 'preparing', file_sha256: "pending:#{SecureRandom.uuid}")
  end

  it 'shows each document as ready once the desk has prepared it, refresh after refresh, without a reload by hand' do
    first = preparing('Refresh one')
    second = preparing('Refresh two')
    visit desk_clients_path
    within('nav[aria-label="Contract desk"]') { click_link 'Home' }
    expect(page).to have_css('li', text: 'The desk is preparing it', count: 2)

    first.update_columns(state: 'ready_to_send') # what the job does, behind the page's back
    expect(page).to have_css('li', text: 'Ready to send', count: 1, wait: 15)
    expect(page).to have_css('li', text: 'The desk is preparing it', count: 1)

    second.update_columns(state: 'ready_to_send')
    expect(page).to have_css('li', text: 'Ready to send', count: 2, wait: 15)
    expect(page).to have_no_content('The desk is preparing it')
  end
end

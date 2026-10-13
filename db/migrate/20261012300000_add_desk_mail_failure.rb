# frozen_string_literal: true

# Contract Desk: e-mail that does not go out is shown on the desk home (Desk::MailHealth). Since when deliveries
# fail, and the class of the last error; never a message, an address or a credential.
class AddDeskMailFailure < ActiveRecord::Migration[8.1]
  def change
    change_table :desk_settings, bulk: true do |t|
      t.datetime :mail_failed_at
      t.string :mail_error
    end
  end
end

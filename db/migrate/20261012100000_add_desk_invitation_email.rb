# frozen_string_literal: true

# Contract Desk: the invitation e-mail of desk documents (subject and body, with WE Sign's e-mail variables). Blank
# means the desk's default (Desk::Setting::INVITATION_SUBJECT and INVITATION_BODY).
class AddDeskInvitationEmail < ActiveRecord::Migration[8.1]
  def change
    change_table :desk_settings, bulk: true do |t|
      t.string :invitation_subject
      t.text :invitation_body
    end
  end
end

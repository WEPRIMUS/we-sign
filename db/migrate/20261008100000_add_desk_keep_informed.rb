# frozen_string_literal: true

# Contract Desk: "Keep informed", the e-mail addresses told when a desk document is sent and sent the signed copy and
# the audit record when everyone has signed.
class AddDeskKeepInformed < ActiveRecord::Migration[8.1]
  def change
    add_column :desk_settings, :keep_informed, :jsonb, null: false, default: []
  end
end

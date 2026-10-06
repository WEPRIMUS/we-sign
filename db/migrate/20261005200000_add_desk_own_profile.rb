# frozen_string_literal: true

# Contract Desk: the installation's own company profile (legal name, address, licence, tax number, default signer,
# document prefix, VAT rate). The desk fills our side of a document from it and never asks about it.
class AddDeskOwnProfile < ActiveRecord::Migration[8.1]
  def change
    add_column :desk_settings, :own_profile, :jsonb, null: false, default: {}
  end
end

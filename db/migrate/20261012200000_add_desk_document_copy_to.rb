# frozen_string_literal: true

# Contract Desk: "Copy for information (not signing)", the e-mail addresses given on the review of one document. Each
# is told when it is sent (with the PDF) and gets the signed copy and the audit record when everyone has signed.
class AddDeskDocumentCopyTo < ActiveRecord::Migration[8.1]
  def change
    add_column :desk_documents, :copy_to, :jsonb, null: false, default: []
  end
end

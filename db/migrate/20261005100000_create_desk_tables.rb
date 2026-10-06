# frozen_string_literal: true

# rubocop:disable Metrics
# Contract Desk (architecture: Postquadratic Operating Architecture, POA-001, originated by João de Melo).
# Its own tables, every one carrying the account; rows are archived, never deleted; the event log is append-only.
class CreateDeskTables < ActiveRecord::Migration[8.1]
  # The event log refuses UPDATE, DELETE and TRUNCATE in the database itself, whatever code runs.
  # (schema.rb cannot carry a trigger; the spec installs this same SQL to test it.)
  APPEND_ONLY_SQL = <<~SQL # rubocop:disable Rails/SquishedSQLHeredocs
    CREATE OR REPLACE FUNCTION desk_events_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'desk_events is append-only';
    END
    $$;
    DROP TRIGGER IF EXISTS desk_events_no_change ON desk_events;
    CREATE TRIGGER desk_events_no_change BEFORE UPDATE OR DELETE ON desk_events
      FOR EACH ROW EXECUTE FUNCTION desk_events_append_only();
    DROP TRIGGER IF EXISTS desk_events_no_truncate ON desk_events;
    CREATE TRIGGER desk_events_no_truncate BEFORE TRUNCATE ON desk_events
      FOR EACH STATEMENT EXECUTE FUNCTION desk_events_append_only();
  SQL

  def up
    create_table :desk_settings do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.boolean :approval_required, null: false, default: false
      t.jsonb :approver_user_ids, null: false, default: []
      t.boolean :sender_signs_on_approval, null: false, default: true
      t.jsonb :reminder_days, null: false, default: [3, 7, 14]
      t.integer :expiry_warning_days, null: false, default: 3
      t.jsonb :own_party_names, null: false, default: []
      t.jsonb :signer_titles, null: false, default: {}
      t.timestamps
    end

    create_table :desk_clients do |t|
      t.references :account, null: false, foreign_key: true
      t.string :legal_name, null: false
      t.string :normalized_name, null: false
      t.string :trading_name
      t.string :country
      t.text :address
      t.string :tax_number
      t.string :normalized_tax_number
      t.jsonb :signers, null: false, default: []
      t.string :default_currency
      t.string :payment_terms
      t.string :status, null: false, default: 'confirmed'
      t.string :source, null: false
      t.bigint :source_document_id
      t.bigint :created_by_user_id
      t.bigint :confirmed_by_user_id
      t.datetime :confirmed_at
      t.datetime :archived_at
      t.timestamps
      t.index %i[account_id normalized_name], unique: true, where: 'archived_at IS NULL',
                                              name: 'index_desk_clients_one_per_name'
      t.index %i[account_id normalized_tax_number], unique: true,
                                                    where: 'archived_at IS NULL AND normalized_tax_number IS NOT NULL',
                                                    name: 'index_desk_clients_one_per_tax_number'
    end

    create_table :desk_documents do |t|
      t.references :account, null: false, foreign_key: true
      t.string :uuid, null: false, index: { unique: true }
      t.references :client, foreign_key: { to_table: :desk_clients }
      t.string :doc_type
      t.string :title
      t.string :number
      t.string :revision
      t.string :source, null: false, default: 'upload'
      t.string :filename
      t.string :file_sha256, null: false
      t.string :state, null: false, default: 'preparing'
      t.bigint :template_id
      t.bigint :submission_id
      t.text :last_error
      t.datetime :last_error_at
      t.datetime :processing_started_at
      t.bigint :created_by_user_id, null: false
      t.bigint :approved_by_user_id
      t.datetime :approved_at
      t.bigint :sent_by_user_id
      t.datetime :sent_at
      t.datetime :opened_at
      t.datetime :signed_at
      t.datetime :declined_at
      t.datetime :expired_at
      t.datetime :expire_at
      t.datetime :archived_at
      t.jsonb :reminders_sent, null: false, default: []
      t.datetime :expiry_warned_at
      t.string :follow_up_token
      t.datetime :checked_at
      t.timestamps
      t.index %i[account_id file_sha256], unique: true, name: 'index_desk_documents_one_per_file'
      t.index %i[account_id state]
    end

    create_table :desk_facts do |t|
      t.references :account, null: false, foreign_key: true
      t.references :document, null: false, foreign_key: { to_table: :desk_documents }
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.jsonb :source_ref, null: false, default: {}
      t.float :confidence
      t.string :status, null: false
      t.string :origin, null: false
      t.string :method
      t.string :run_id, null: false
      t.timestamps
    end

    create_table :desk_questions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :document, null: false, foreign_key: { to_table: :desk_documents }
      t.string :key, null: false
      t.string :kind, null: false
      t.text :prompt, null: false
      t.string :example
      t.jsonb :context, null: false, default: {}
      t.text :answer
      t.string :status, null: false, default: 'open'
      t.bigint :answered_by_user_id
      t.datetime :answered_at
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index %i[document_id key], unique: true
    end

    create_table :desk_number_registers do |t|
      t.references :account, null: false, foreign_key: true
      t.string :prefix, null: false
      t.integer :year, null: false
      t.integer :last_number, null: false, default: 0
      t.timestamps
      t.index %i[account_id prefix year], unique: true, name: 'index_desk_number_registers_one_per_series'
    end

    create_table :desk_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :document, foreign_key: { to_table: :desk_documents }
      t.references :client, foreign_key: { to_table: :desk_clients }
      t.string :actor, null: false
      t.bigint :user_id
      t.string :action, null: false
      t.jsonb :data, null: false, default: {}
      t.datetime :created_at, null: false
    end

    execute APPEND_ONLY_SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Contract Desk records are archived, never dropped'
  end
end
# rubocop:enable Metrics

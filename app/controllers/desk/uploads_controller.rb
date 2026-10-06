# frozen_string_literal: true

module Desk
  # Intake: one PDF becomes one desk document. The same file (same SHA-256) is the same intake: uploading it again
  # opens the document already made from it.
  class UploadsController < BaseController
    MAX_SIZE = 25.megabytes

    def new; end

    def create
      file = params[:file]

      return redirect_to(new_desk_upload_path, alert: 'Choose a PDF file to upload.') unless file.respond_to?(:read)

      data = file.read

      unless data.start_with?('%PDF-') && data.size <= MAX_SIZE
        return redirect_to(new_desk_upload_path, alert: 'Upload a PDF of up to 25 MB.')
      end

      sha256 = Digest::SHA256.hexdigest(data)

      if (existing = documents_scope.find_by(file_sha256: sha256))
        return redirect_to desk_document_path(existing), notice: 'This file was uploaded before: here is its document.'
      end

      document = create_document!(file, data, sha256)

      redirect_to desk_document_path(document), notice: 'Uploaded. The desk is reading the document.'
    rescue ActiveRecord::RecordNotUnique
      redirect_to desk_document_path(documents_scope.find_by!(file_sha256: sha256)),
                  notice: 'This file was uploaded before: here is its document.'
    end

    private

    def create_document!(file, data, sha256)
      filename = File.basename(file.original_filename.to_s).tr('/', '-').presence || 'document.pdf'

      document = Desk::Document.create!(account_id: current_account.id, created_by_user: current_user,
                                        source: 'upload', filename:, file_sha256: sha256,
                                        title: File.basename(filename, '.*'))
      document.source_file.attach(io: StringIO.new(data), filename:, content_type: 'application/pdf')
      document.log!('intake: uploaded', actor: 'person', user: current_user, data: { sha256:, bytes: data.size })

      Desk::ProcessDocumentJob.perform_async('document_id' => document.id)

      document
    end
  end
end

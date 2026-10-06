# frozen_string_literal: true

module Desk
  # Build: the WE Sign template (the uploaded PDF unchanged, the boxes placed per signer, the parties in signing
  # order) and its submission with every e-mail switched off. Nothing is sent here: the document is "ready to send"
  # and waits for a person's "Yes, send" (Desk::Sender).
  module SigningBuild
    FOLDER = 'Contract Desk'
    DocumentChanged = Class.new(StandardError)

    Result = Struct.new(:problems, :notes)

    module_function

    def call(document, slots)
      user = document.created_by_user
      template = document.template || create_template!(document, user)
      attachment = source_attachment(template)
      data = attachment.download

      verify_unchanged!(document, data)

      return from_editor(document, template.reload, slots, user) if placed_by_person?(document)

      placement = if document.source == 'generated'
                    from_layout(document, slots, attachment)
                  else
                    FieldPlacement.call(attachment:, data:, slots:, parties: Signers.parties(document))
                  end

      template.update!(submitters: slots.map { |s| { 'name' => s.label, 'uuid' => s.uuid } }, fields: placement.fields)
      document.log!('boxes placed', actor: 'system', data: { fields: placement.fields.size, notes: placement.notes,
                                                             problems: placement.problems })

      return Result.new(problems: placement.problems, notes: placement.notes) if placement.problems.any?

      create_submission!(document, template, slots.map { |s| submitter_attrs(s, user) }, user)

      Result.new(problems: [], notes: placement.notes)
    end

    # A document the desk drew itself: the boxes are where the renderer put them (Desk::VariationPdf), not guessed.
    def from_layout(document, slots, attachment)
      layout = document.facts.current.find_by(key: 'layout')&.value&.dig('fields').to_a
      boxes = layout.filter_map do |f|
        next unless slots.any? { |s| s.key == f['slot'] }

        FieldPlacement::Box.new(id: 0, page: f['page'], area: f['area'], kind: f['kind'], slot_key: f['slot'],
                                origin: 'layout')
      end
      problems = slots.filter_map do |slot|
        next if boxes.any? { |b| b.slot_key == slot.key && b.kind == 'signature' }

        "No signature box was drawn for #{slot.description}"
      end

      FieldPlacement::Result.new(fields: boxes.map { |b| FieldPlacement.build_field(b, slots, attachment) },
                                 problems:, notes: [])
    end

    # Once a person has placed boxes in the editor (after a "fix" question), their boxes are kept as they are and
    # only checked: every signer needs a signature box.
    def placed_by_person?(document)
      document.template && document.questions.answered.exists?(kind: 'fix_fields')
    end

    def from_editor(document, template, slots, user)
      problems = slots.filter_map do |slot|
        next if template.fields.any? { |f| f['submitter_uuid'] == slot.uuid && f['type'] == 'signature' }

        "No signature box was found for #{slot.description}"
      end

      return Result.new(problems:, notes: []) if problems.any?

      create_submission!(document, template, slots.map { |s| submitter_attrs(s, user) }, user)
      Result.new(problems: [], notes: ['The boxes were placed by a person in the editor.'])
    end

    def create_template!(document, user)
      template = Template.create!(
        account_id: document.account_id, author: user, name: document.name.truncate(200),
        folder: TemplateFolders.find_or_create_by_name(user, FOLDER),
        preferences: { 'submitters_order' => 'preserved', 'completed_notification_email_enabled' => false }
      )

      Tempfile.create(['desk', '.pdf'], binmode: true) do |file|
        file.write(document.source_file.download)
        file.rewind

        upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, type: 'application/pdf',
                                                        filename: document.filename.presence || 'document.pdf')
        documents, = Templates::CreateAttachments.call(template, { files: [upload] })

        template.update!(schema: documents.map { |d| { 'attachment_uuid' => d.uuid, 'name' => d.filename.base } })
      end

      document.update!(template:)
      document.log!('WE Sign template created', actor: 'system', data: { template_id: template.id })
      WebhookUrls.enqueue_events(template, 'template.created')
      SearchEntries.enqueue_reindex(template)

      template
    end

    def source_attachment(template)
      template.documents.find_by!(uuid: template.schema.first['attachment_uuid'])
    end

    # What a person approves is what is signed: the PDF in WE Sign must be the uploaded file, byte for byte.
    def verify_unchanged!(document, data)
      return if Digest::SHA256.hexdigest(data) == document.file_sha256

      raise DocumentChanged, 'The PDF in WE Sign differs from the uploaded file (an encrypted PDF is not accepted)'
    end

    def submitter_attrs(slot, user)
      # with no name printed for our side, whoever approves signs it; until then the preparer stands in (never e-mailed)
      stand_in = slot.own && slot.approver && slot.signer_user_id.nil?

      { uuid: slot.uuid, name: stand_in ? user.full_name : slot.name, email: stand_in ? user.email : slot.email }
    end

    def create_submission!(document, template, submitters, user)
      submission = Submissions.create_from_submitters(
        template:, user:, source: :invite, submitters_order: 'preserved',
        submissions_attrs: [{ name: document.name, submitters: }.with_indifferent_access],
        params: { 'send_email' => false }.with_indifferent_access
      ).first

      document.update!(submission:)
      document.log!('WE Sign submission created, e-mail off', actor: 'system',
                                                              data: { submission_id: submission.id })
      WebhookUrls.enqueue_events(submission, 'submission.created')

      submission
    end

    # After "Fix something": if the template was changed in the editor, the unsent submission is archived and a
    # new one made from the template as it is now, with the same people. Returns the problems that stop sending.
    def refresh!(document)
      template = document.template.reload
      submission = document.submission

      if submission.template_fields == template.fields && submission.template_submitters == template.submitters
        return []
      end

      known = submission.submitters.index_by(&:uuid)
      problems = template.submitters.filter_map do |party|
        next "#{party['name']}, added in the editor, has no e-mail address: remove it there" unless known[party['uuid']]
        next if template.fields.any? { |f| f['submitter_uuid'] == party['uuid'] && f['type'] == 'signature' }

        "#{party['name']} has no signature box"
      end

      return problems if problems.any?

      attrs = template.submitters.map do |party|
        { uuid: party['uuid'], name: known[party['uuid']].name, email: known[party['uuid']].email }
      end

      submission.update!(archived_at: Time.current)
      create_submission!(document, template, attrs, submission.created_by_user || document.created_by_user)
      document.log!('rebuilt after a change in the editor', actor: 'system',
                                                            data: { archived_submission_id: submission.id })

      []
    end
  end
end

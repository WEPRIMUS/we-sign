# frozen_string_literal: true

module Desk
  # "Yes, send". The only code that releases a desk document to its signers. It refuses to run without a person's
  # approval (Desk::Approval, made from that person's own signed-in request with two-factor sign-in) and refuses to
  # run inside any automated path (Desk::Automation: the desk's jobs and AI calls). With "sender signs on approval",
  # the approving person's saved signature is applied to the installation's own party at that moment.
  module Sender
    NotAllowed = Approval::NotAllowed

    module_function

    def call(document, approval, title: nil)
      raise NotAllowed, 'Automated code cannot send a document' if Automation.active?
      raise NotAllowed, 'Only a person can send' unless approval.is_a?(Approval)

      user = approval.user
      settings = Setting.for(document.account)

      raise NotAllowed, 'Not found' if document.account_id != user.account_id
      unless settings.may_send?(user)
        raise NotAllowed,
              'A manager approves before sending: you are not on the list of approvers'
      end

      claim!(document)

      begin
        send!(document, approval, user, settings, title)
      ensure
        Document.where(id: document.id).update_all(processing_started_at: nil)
      end
    end

    # One "Yes, send" at a time: a second click, or a second person at the same moment, is refused.
    def claim!(document)
      claimed = Document.where(id: document.id, state: 'ready_to_send', processing_started_at: nil)
                        .update_all(processing_started_at: Time.current)

      raise NotAllowed, 'This document is not ready to send, or is being sent now' unless claimed == 1

      document.reload
    end

    def send!(document, approval, user, settings, title)
      problems = SigningBuild.refresh!(document)
      raise NotAllowed, problems.join('. ') if problems.any?

      submission = document.submission.reload
      SigningBuild.verify_unchanged!(document, SigningBuild.source_attachment(document.template).download)

      # Signs now only if our side may be signed by this person: no name printed for it, or this person's name.
      own = own_submitter(document, submission, user) if settings.sender_signs_on_approval
      signature = UserConfigs.load_signature(user) if own

      raise NotAllowed, 'Save your signature in Profile first: it is applied when you approve' if own && !signature

      release!(submission)

      if own
        sign_own!(own, user, signature, title, approval.request)
        remember_title!(settings, user, title)
      else
        Submissions.send_signature_requests([submission])
      end

      token = SecureRandom.hex(8)
      now = Time.current

      document.transition!('sent', actor: 'person', user:, approval:, sent_by_user_id: user.id, sent_at: now,
                                   approved_by_user_id: user.id, approved_at: now, expire_at: submission.expire_at,
                                   follow_up_token: token, last_error: nil, last_error_at: nil)
      action = "approved and sent by #{user.full_name} (#{user.email})"
      action = "approved and signed by #{user.full_name} (#{user.email}) for #{own_party_name(submission, own)}" if own
      document.log!(action,
                    actor: 'person', user:, data: { ip: approval.request.remote_ip })

      FollowUpJob.perform_in(FollowUp::INTERVAL, 'document_id' => document.id, 'token' => token)

      document
    end

    def own_submitter(document, submission, user)
      slot = Signers.plan(document, Setting.for(document.account)).find { |s| s.own && s.signed_by?(user) }

      slot && submission.submitters.find { |s| s.uuid == slot.uuid }
    end

    def own_party_name(submission, own)
      submission.template_submitters.find { |s| s['uuid'] == own.uuid }&.dig('name')
    end

    # E-mail back on, and the 30 days of the signing links counted from now, not from when it was prepared.
    def release!(submission)
      submission.preferences = submission.preferences.merge('send_email' => true)
      submission.expire_at = Submission::DEFAULT_EXPIRE_IN.from_now
      submission.save!

      submission.submitters.each do |submitter|
        submitter.update!(preferences: submitter.preferences.merge('send_email' => true))
      end

      ProcessSubmissionExpiredJob.perform_at(submission.expire_at, 'submission_id' => submission.id,
                                                                   'expire_at' => submission.expire_at.to_i)
    end

    # Signs for the own party as the approving person, through WE Sign's own completion path (its audit records
    # the person's address, IP and browser). Completing it invites the next signer in order.
    def sign_own!(submitter, user, signature, title, request)
      return if submitter.completed_at?

      submitter.update!(email: user.email, name: user.full_name)
      copy = ActiveStorage::Attachment.create!(blob: signature.blob, name: 'attachments', record: submitter)

      values = submitter.submission.template_fields.each_with_object({}) do |field, acc|
        next if field['submitter_uuid'] != submitter.uuid || field['readonly']

        acc[field['uuid']] =
          case field['type']
          when 'signature' then copy.uuid
          when 'text' then { 'Name' => user.full_name, 'Title' => title.presence }[field['name']]
          end
      end

      params = ActionController::Parameters.new(values: values.compact, completed: 'true')

      Submitters::SubmitValues.call(submitter, params,
                                    request)
    end

    def remember_title!(settings, user, title)
      return if title.blank?

      settings.update!(signer_titles: settings.signer_titles.merge(user.id.to_s => title.to_s.truncate(100)))
    end
  end
end

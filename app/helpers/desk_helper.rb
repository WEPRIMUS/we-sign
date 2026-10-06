# frozen_string_literal: true

# Words and marks of the Contract Desk pages.
module DeskHelper
  DESK_STATES = {
    'preparing' => %w[Preparing badge-info], 'waiting_for_you' => ['Waiting for you', 'badge-warning'],
    'ready_to_send' => ['Ready to send', 'badge-info'], 'sent' => %w[Sent badge-info],
    'opened' => %w[Opened badge-warning], 'signed' => %w[Signed badge-success],
    'declined' => %w[Declined badge-error], 'expired' => %w[Expired badge-error],
    'archived' => %w[Archived badge-ghost]
  }.freeze

  DESK_FACT_STATUS = {
    'validated' => 'found in the text', 'candidate' => 'read from the page image',
    'unverified' => 'not found in the text: not used', 'confirmed' => 'given by a person'
  }.freeze

  # One colour per signer, the same on the page and in the list of recipients.
  DESK_PARTY_COLORS = %w[#2f6fde #d4572a #2d9b68 #9b4fd0 #c79a18 #d23f7b #1f9aa8 #6b7a2a].freeze

  def desk_state_badge(state, size: '')
    label, css = DESK_STATES.fetch(state.to_s, [state.to_s.humanize, 'badge-ghost'])

    tag.span(label, class: "badge #{css} bg-opacity-50 font-medium whitespace-nowrap #{size}")
  end

  def desk_state_label(state) = DESK_STATES.fetch(state.to_s, [state.to_s.humanize]).first

  # The document's number, with its revision unless the number already ends with it ("SP-VAR-2026-001-R1").
  def desk_number(document)
    revision = document.revision.to_s
    return document.number.to_s if revision.blank? || document.number.to_s.end_with?(revision)

    "#{document.number} rev. #{revision}"
  end

  def desk_doc_type(type) = type.to_s.tr('_', ' ').capitalize.presence || 'Not known yet'

  def desk_fact_status(fact)
    return 'computed by code' if fact.origin == 'rule'
    return 'from the register or our profile' if fact.origin == 'register'

    DESK_FACT_STATUS.fetch(fact.status, fact.status)
  end

  def desk_fact_mark(fact)
    text = [("p. #{fact.source_ref['page']}" if fact.source_ref['page']), desk_fact_status(fact)].compact.join(' · ')

    tag.span(text, class: 'text-xs text-base-content/60 whitespace-nowrap', title: fact.source_ref['quote'])
  end

  def desk_party_color(index) = DESK_PARTY_COLORS[index % DESK_PARTY_COLORS.size]

  def desk_time(time)
    return '' unless time

    l(time.in_time_zone(current_account.timezone), format: :short)
  end

  def desk_actor(event)
    case event.actor
    when 'person' then event.user&.full_name.presence || event.user&.email || 'A person'
    when 'ai' then 'AI'
    else 'System'
    end
  end

  # The page images of a template document, in order: [[index, url, width, height], ...].
  def desk_pages(attachment)
    images = attachment.preview_images.index_by { |i| i.filename.base.to_i }
    fallback = images.values.first&.metadata || Templates::ProcessDocument::US_LETTER_SIZE
    count = attachment.metadata.dig('pdf', 'number_of_pages') || images.size

    Array.new(count) do |index|
      image = images[index]
      meta = image&.metadata || fallback
      url = if image
              image.url(time: ActiveStorage::Attachment.service_url_time)
            else
              preview_document_page_path(attachment.signed_key, "#{index}#{Templates::ProcessDocument::PREVIEW_FORMAT}")
            end

      [index, url, meta['width'], meta['height']]
    end
  end
end

# frozen_string_literal: true

# rubocop:disable Metrics, Naming/MethodParameterName
module Desk
  # Draws a quotation and variation as a PDF with HexaPDF, in the house style of the brand pack
  # (Brand.document_style: font files and colours; plain defaults without one). It only lays out what it is given:
  # every number and date in `data` was computed by Desk::Variation, every passage written or approved there.
  # Returns [pdf_bytes, fields]: the signing boxes it drew, per signer, as fractions of their page (top left), so
  # the WE Sign document is built without guessing where anyone signs.
  class VariationPdf
    PAGE_W = 595.28
    PAGE_H = 841.89
    LEFT = 57.0
    RIGHT = 56.0
    GUTTER = 136.0
    CONTENT_W = PAGE_W - LEFT - RIGHT
    ROW = 26.0
    SIGN_ROW = 52.0

    DEFAULTS = {
      'ink' => '#1b2230', 'navy' => '#2b4a7a', 'accent' => '#b21a1a', 'slate' => '#4e5667', 'rule' => '#d5d0c6',
      'hair' => '#e6e2da', 'band' => '#141d2e', 'on_band' => '#f7f5f0', 'on_band_muted' => '#9aa3b5',
      'paper' => '#ffffff'
    }.freeze

    def self.call(data) = new(data).render

    def initialize(data)
      @data = data
      @style = DEFAULTS.merge(Brand.document_style.slice(*DEFAULTS.keys))
      @fields = []
    end

    def render
      @composer = HexaPDF::Composer.new(skip_page_creation: true)
      @doc = @composer.document
      setup_fonts
      setup_styles
      setup_pages

      @composer.new_page(:cover)
      @composer.new_page(:default)
      body
      signature_page
      stamp_page_numbers

      io = StringIO.new
      @composer.write(io)

      [io.string, @fields]
    end

    private

    # Fonts of the pack (static TrueType files named in document_style), else the PDF standard Helvetica.
    def setup_fonts
      files = %w[font_regular font_medium font_semibold].to_h do |key|
        file = Brand.document_style[key]
        [key, file && Brand.file?(file) ? Brand.path(file) : nil]
      end

      if files.values.all?
        @doc.config['font.map'] = { 'DocSans' => { none: files['font_regular'], bold: files['font_semibold'] },
                                    'DocMedium' => { none: files['font_medium'] } }
        @font = { regular: ['DocSans', false], medium: ['DocMedium', false], semibold: ['DocSans', true] }
      else
        @font = { regular: ['Helvetica', false], medium: ['Helvetica', true], semibold: ['Helvetica', true] }
        # the standard Helvetica has few characters (no middle dot): anything it lacks is drawn as a hyphen
        @doc.config['font.on_missing_glyph'] = ->(_char, font) { font.decode_utf8('-').first }
      end
    end

    # A font as style properties, and set on a canvas: [name, bold] from the table above.
    def style_font(key) = { font: @font[key][0], font_bold: @font[key][1] }

    def set_font(canvas, key, size)
      name, bold = @font[key]
      canvas.font(name, size:, variant: bold ? :bold : :none)
    end

    def color(name) = @style[name].to_s.delete('#').scan(/../).map { |hex| hex.to_i(16) }

    def setup_styles
      line = { type: :proportional, value: 1.55 }
      c = @composer

      c.style(:base, **style_font(:regular), font_size: 9.8, line_spacing: line, fill_color: color('ink'))
      c.style(:body, base: :base, padding: [0, 0, 9, GUTTER])
      c.style(:opening, base: :base, padding: [0, 0, 14, GUTTER], fill_color: color('slate'))
      c.style(:h2, base: :base, **style_font(:regular), font_size: 18.5, line_spacing: 1.2, padding: [0, 0, 12, GUTTER])
      c.style(:label, base: :base, **style_font(:medium), font_size: 6.6, character_spacing: 1.1,
                      fill_color: color('slate'))
      c.style(:cell, base: :base, font_size: 9.5)
      c.style(:cell_strong, base: :cell, **style_font(:medium))
      c.style(:list, base: :base, padding: [0, 0, 9, GUTTER])
    end

    def setup_pages
      data = @data

      @composer.page_style(:cover, page_size: [0, 0, PAGE_W, PAGE_H]) do |canvas, style|
        cover(canvas)
        style.frame = style.create_frame(canvas.context, [PAGE_H - 40, 40, 20, 40])
      end

      @composer.page_style(:default, page_size: [0, 0, PAGE_W, PAGE_H], next_style: :default) do |canvas, style|
        paper(canvas)
        logo(canvas, LEFT, PAGE_H - 56, 86)
        set_font(canvas, :regular, 7.2).fill_color(color('slate'))
        text_right(canvas, data[:running_title], PAGE_W - RIGHT, PAGE_H - 44, 7.2)
        canvas.text(data[:footer_left], at: [LEFT, 38])
        canvas.stroke_color(color('rule')).line_width(0.5).line(LEFT, 52, PAGE_W - RIGHT, 52).stroke
        style.frame = style.create_frame(canvas.context, [104, RIGHT, 78, LEFT])
      end
    end

    def paper(canvas)
      canvas.fill_color(color('paper')).rectangle(0, 0, PAGE_W, PAGE_H).fill
    end

    def logo(canvas, x, y_top, width)
      file = Brand.document_style['logo']
      return unless file && Brand.file?(file)

      image = @doc.images.add(Brand.path(file))
      height = width * image.height / image.width.to_f
      canvas.image(image, at: [x, y_top - height], width:, height:)
    end

    def text_right(canvas, text, x_right, y, size, font: :regular)
      width = text_width(text, size, font)
      set_font(canvas, font, size).text(text, at: [x_right - width, y])
    end

    def text_width(text, size, font = :regular)
      name, bold = @font[font]
      wrapper = @doc.fonts.add(name, variant: bold ? :bold : :none)
      wrapper.decode_utf8(text.to_s).sum { |glyph| glyph.respond_to?(:width) ? glyph.width : 0 } * size / 1000.0
    end

    def spaced(text) = text.to_s.upcase

    # The cover: the logo, the confidentiality mark, the eyebrow and title, and the band with the facts.
    def cover(canvas)
      d = @data
      paper(canvas)
      logo(canvas, LEFT, PAGE_H - 56, 100)
      set_font(canvas, :medium, 6.6).fill_color(color('accent'))
      canvas.character_spacing(1.4) do
        text_right(canvas, 'PRIVATE & CONFIDENTIAL', PAGE_W - RIGHT, PAGE_H - 71, 6.6, font: :medium)
      end

      set_font(canvas, :medium, 6.6).fill_color(color('slate'))
      canvas.character_spacing(1.4) { canvas.text(spaced(d[:eyebrow]), at: [LEFT, 578]) }
      canvas.fill_color(color('accent')).rectangle(LEFT, 559, 45, 2.2).fill

      y = 515
      set_font(canvas, :regular, 30).fill_color(color('ink')).text(d[:title_line], at: [LEFT, y])
      d[:title_lines].each do |line|
        y -= 41
        canvas.fill_color(color('navy')).text(line, at: [LEFT, y])
      end

      y -= 30
      text_at(canvas, d[:subtitle], LEFT, y, 330, 60, font_size: 11, line_spacing: 1.55, fill_color: color('slate'))

      band = 270
      canvas.fill_color(color('band')).rectangle(0, 0, PAGE_W, band).fill
      [[:prepared_for, 'PREPARED FOR', LEFT, band - 50], [:prepared_by, 'PREPARED BY', 315, band - 50],
       [:reference, 'REFERENCE', LEFT, band - 114], [:date_text, 'DATE', 315, band - 114],
       [:status, 'STATUS', LEFT, band - 163]].each do |key, label, x, y_label|
        set_font(canvas, :medium, 6.4).fill_color(color('on_band_muted'))
        canvas.character_spacing(1.4) { canvas.text(label, at: [x, y_label]) }
        text_at(canvas, d[key].to_s, x, y_label - 8, 230, 50, font_size: 10, line_spacing: 1.45,
                                                              fill_color: color('on_band'))
      end
    end

    # Wrapped text placed with its top at y, inside a frame of the given size.
    def text_at(canvas, text, x, y_top, width, height, **style)
      frame = HexaPDF::Layout::Frame.new(x, y_top - height, width, height, context: canvas.context)
      result = frame.fit(@doc.layout.text_box(text, **style_font(:regular), **style))
      frame.draw(canvas, result) if result.success?
    end

    # The body: the opening line, then the numbered sections.
    def body
      @composer.text(@data[:opening], style: :opening)

      @data[:sections].each_with_index do |section, index|
        rule
        heading(format('%02d', index + 1), section[:title])
        section[:blocks].each { |block| draw_block(block) }
      end
    end

    def rule
      @composer.box(:base, height: 30.6, style: { padding: [12, 0, 18, 0], underlays: [rule_line] })
    end

    def rule_line
      rule = color('rule')
      ->(canvas, box) { canvas.fill_color(rule).rectangle(0, 18, box.width, 0.6).fill }
    end

    def heading(number, title)
      navy = color('navy')
      accent = color('accent')
      regular = @font[:regular][0]

      @composer.text(title, style: :h2, box_style: {
                       padding: [0, 0, 12, GUTTER],
                       underlays: [lambda do |canvas, box|
                         canvas.font(regular, size: 18.5).fill_color(navy).text(number, at: [0, box.height - 17])
                         canvas.fill_color(accent).rectangle(23.5, box.height - 17, 3.6, 8.5).fill
                       end]
                     })
    end

    def draw_block(block)
      case block[:type]
      when :para
        parts = []
        parts << { text: "#{block[:label]} ", **style_font(:medium) } if block[:label].present?
        parts << { text: block[:text].to_s }
        @composer.formatted_text(parts, style: :body)
      when :bullets
        texts = block[:items]
        @composer.list(marker_type: :disc, item_spacing: 5, content_indentation: 14, style: :list) do |list|
          texts.each { |text| list.text(text, style: :base) }
        end
      when :table
        table(block)
      end
    end

    # A full-width table: a small upper-case header, hairlines between rows, the last row strong when it is a total.
    def table(block)
      header = block[:header].map { |h| spaced(h) }
      rows = block[:rows]
      strong_last = block[:total]
      hair = color('hair')
      ink = color('ink')

      head = { border: { width: [0, 0, 0.8, 0], color: ink }, padding: [2, 6, 6, 0] }
      line = { border: { width: [0, 0, 0.5, 0], color: hair }, padding: [7, 6, 7, 0] }
      columns = 0..(header.size - 1)

      @composer.table([header] + rows, column_widths: block[:widths], margin: [4, 0, 14, 0]) do |args|
        args[0, columns] = { style: :label, cell: head }
        args[1..rows.size, columns] = { style: :cell, cell: line }
        args[1..rows.size, 0] = { style: :cell_strong, cell: line }
        args[rows.size, columns] = { style: :cell_strong, cell: line } if strong_last
      end
    end

    # The signature page: a heading and the execution clause in the column, then a two-column table drawn at known
    # places, so that each signing box is placed exactly. Our company on the left, the client on the right; further
    # signers of the client below, in the right column.
    def signature_page
      s = @data[:signature]
      @composer.new_page(:default)
      @composer.text(s[:heading], style: :h2)
      @composer.text(s[:execution], style: :body)

      canvas = @doc.pages[-1].canvas(type: :overlay)
      page_index = @doc.pages.count - 1
      top = @composer.y - 18
      col_own = LEFT
      col_client = LEFT + (CONTENT_W / 2) + 6
      col_w = (CONTENT_W / 2) - 6

      set_font(canvas, :medium, 6.6).fill_color(color('slate'))
      canvas.character_spacing(1.2) do
        canvas.text(spaced("For #{s[:own][:party]}"), at: [col_own, top])
        canvas.text(spaced("For #{s[:client][:party]}"), at: [col_client, top])
      end
      canvas.stroke_color(color('ink')).line_width(0.8).line(LEFT, top - 8, PAGE_W - RIGHT, top - 8).stroke

      block(canvas, page_index, col_own, col_w, top - 8, s[:own][:signers].first)
      y = top - 8
      s[:client][:signers].each do |signer|
        y = block(canvas, page_index, col_client, col_w, y, signer)
      end
    end

    # One signer's rows: Name, Title, Date, Signature. A printed value is drawn; a blank one gets a box for the signer.
    # Returns the y under the block.
    def block(canvas, page_index, x, width, y_top, signer)
      y = y_top
      [['Name', signer[:name], 'name'], ['Title', signer[:title], 'title'], ['Date', nil, 'date'],
       ['Signature', nil, 'signature']].each do |label, value, kind|
        height = kind == 'signature' ? SIGN_ROW : ROW
        baseline = y - 17
        set_font(canvas, :medium, 9.5).fill_color(color('ink')).text("#{label}:", at: [x, baseline])
        label_w = text_width("#{label}: ", 9.5, :medium)
        set_font(canvas, :regular, 9.5).text(value.to_s, at: [x + label_w, baseline]) if value.present?

        if value.blank?
          box_h = kind == 'signature' ? 40.0 : 18.0
          box_y_bottom = kind == 'signature' ? y - height + 6 : baseline - 5
          add_field(signer[:slot], kind, page_index, x + label_w, box_y_bottom, width - label_w - 4, box_h)
        end

        y -= height
        canvas.stroke_color(color('hair')).line_width(0.5).line(x, y, x + width, y).stroke
      end

      y
    end

    def add_field(slot, kind, page, x, y_bottom, width, height)
      @fields << { 'slot' => slot, 'kind' => kind, 'page' => page,
                   'area' => { 'x' => (x / PAGE_W).round(5), 'y' => ((PAGE_H - y_bottom - height) / PAGE_H).round(5),
                               'w' => (width / PAGE_W).round(5), 'h' => (height / PAGE_H).round(5) } }
    end

    # "Page n of N" and the reference on every page after the cover, once the number of pages is known.
    def stamp_page_numbers
      total = @doc.pages.count

      @doc.pages.each_with_index do |page, index|
        next if index.zero?

        canvas = page.canvas(type: :overlay)
        canvas.fill_color(color('slate'))
        text_right(canvas, "#{@data[:reference]}    Page #{index + 1} of #{total}", PAGE_W - RIGHT, 38, 7.2)
      end
    end
  end
end
# rubocop:enable Metrics, Naming/MethodParameterName

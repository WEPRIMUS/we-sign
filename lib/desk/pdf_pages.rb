# frozen_string_literal: true

module Desk
  # What the desk sees of a PDF: the text of each page, the text cut into positioned segments (for labels and party
  # headings), and page images for the AI. Coordinates are fractions of the page, from the top left, like the
  # fields of a template.
  module PdfPages
    Segment = Struct.new(:text, :x, :y, :endx, :endy) do
      def center_y = (y + endy) / 2
    end

    Page = Struct.new(:index, :text, :segments)

    LINE_GAP = 0.006 # characters closer than this vertically are on one line
    WORD_GAP = 0.025 # a horizontal gap wider than this starts a new segment (another column)
    IMAGE_WIDTH = 1240
    MAX_IMAGE_PAGES = 10

    module_function

    def read(data)
      doc = Pdfium::Document.open_bytes(data)

      Array.new(doc.page_count) do |index|
        page = doc.get_page(index)

        Page.new(index, page.text.to_s, segments(page.text_nodes))
      ensure
        page&.close
      end
    ensure
      doc&.close
    end

    def text_layer?(pages) = pages.sum { |p| p.text.strip.size } > 40

    def segments(nodes)
      lines = []

      nodes.each do |node|
        next if node.content.match?(/\A[\r\n]\z/)

        line = lines.find { |l| (l[:endy] - node.endy).abs < LINE_GAP }
        line ||= { endy: node.endy, nodes: [] }.tap { |l| lines << l }
        line[:nodes] << node
      end

      lines.sort_by { |l| l[:endy] }.flat_map { |line| split_line(line[:nodes].sort_by(&:x)) }
    end

    def split_line(nodes)
      groups = nodes.slice_when { |a, b| b.x - a.endx > WORD_GAP }

      groups.filter_map do |group|
        text = group.map(&:content).join.squish
        next if text.blank?

        Segment.new(text, group.map(&:x).min, group.map(&:y).min, group.map(&:endx).max, group.map(&:endy).max)
      end
    end

    # The pages the AI is shown: all of them up to MAX_IMAGE_PAGES, otherwise the first and the last half of that
    # (signature pages are at the end). Returns [[page_index, jpeg_bytes], ...].
    def images(data, indexes: nil, boxes: {})
      doc = Pdfium::Document.open_bytes(data)
      indexes ||= image_indexes(doc.page_count)

      indexes.map do |index|
        page = doc.get_page(index)
        bytes, width, height = page.render_to_bitmap(width: IMAGE_WIDTH)
        image = Vips::Image.new_from_memory_copy(bytes, width, height, 4, :uchar).extract_band(0, n: 3)
        image = draw_boxes(image, boxes[index]) if boxes[index].present?

        [index, image.write_to_buffer('.jpg', Q: 80)]
      ensure
        page&.close
      end
    ensure
      doc&.close
    end

    def image_indexes(count)
      return (0...count).to_a if count <= MAX_IMAGE_PAGES

      half = MAX_IMAGE_PAGES / 2

      (0...half).to_a + ((count - half)...count).to_a
    end

    # Numbered rectangles over the page, so that the AI can say which box is which.
    def draw_boxes(image, boxes)
      boxes.each do |number, area|
        left = (area['x'] * image.width).round
        top = (area['y'] * image.height).round
        width = [(area['w'] * image.width).round, 4].max
        height = [(area['h'] * image.height).round, 4].max

        image = image.draw_rect([220, 30, 30], left, top, width, height, fill: false)
        image = image.draw_rect([220, 30, 30], left + 1, top + 1, width - 2, height - 2, fill: false)

        label = Vips::Image.text(number.to_s, dpi: 110, font: 'sans bold')
        label_top = [top - label.height - 2, 0].max
        image = image.draw_rect([255, 255, 255], left, label_top, label.width + 6, label.height + 2, fill: true)
        image = image.draw_image((label > 128).ifthenelse([220, 30, 30], [255, 255, 255]), left + 3, label_top + 1)
      end

      image
    end

    def data_uri(jpeg) = "data:image/jpeg;base64,#{Base64.strict_encode64(jpeg)}"
  end
end

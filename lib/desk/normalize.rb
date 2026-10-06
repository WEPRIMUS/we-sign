# frozen_string_literal: true

module Desk
  # Deterministic keys for matching: a company name without its legal form and punctuation, a tax number of
  # letters and digits only, a person's name in lower case.
  module Normalize
    LEGAL_FORMS = %w[
      llc fze fzc fzco fzllc fz llcfz pjsc psc pty ltd limited inc incorporated co company corp corporation plc
      gmbh ag sa sarl spa bv nv wll est establishment llp lp sole proprietorship
    ].to_set.freeze

    module_function

    def name(text)
      words = text.to_s.downcase.delete('.').gsub('&', ' and ').gsub(/[^\p{L}\p{N}]+/, ' ').split
      words.shift while words.first == 'the'
      words.pop while words.size > 1 && LEGAL_FORMS.include?(words.last)

      words.join(' ').presence
    end

    # The number alone: labels written before it ("ABN", "TRN", "VAT No.") and separators are left out.
    TAX_LABELS = /\b(?:ABN|ACN|ARBN|TRN|VAT|GST|TIN|CR|TAX|REG(?:ISTRATION)?|NO|NUMBER)\b\.?/

    def tax(text) = text.to_s.upcase.gsub(TAX_LABELS, '').gsub(/[^A-Z0-9]/, '').presence

    def person(text) = text.to_s.downcase.gsub(/[^\p{L}\p{N}]+/, ' ').squish.presence

    # One normalized name contains the other on word boundaries ("najd falcon drilling services" in
    # "first party najd falcon drilling services"); a name of one short word never matches by containment.
    def same_company?(left, right)
      return false if left.blank? || right.blank?
      return true if left == right

      short, long = [left, right].sort_by(&:size)

      short.size >= 6 && " #{long} ".include?(" #{short} ")
    end
  end
end

# frozen_string_literal: true

# WE Sign: config/locales/i18n.yml names the product "DocuSeal" in about 300 strings, and this fork does not
# edit that file (upstream changes it constantly). Translations are rewritten as they are looked up instead:
# the upstream name becomes Docuseal.product_name and the vendor's support address becomes ours.
#
# Left as they are: "DocuSeal Pro" and "DocuSeal Console" (the vendor's paid products, not this product) and
# the keys in KEEP (a certificate service the vendor runs, and the vendor's 21 CFR Part 11 wording: renaming
# that one would put a compliance claim under our name that we have not established).
#
# The attribution lines are not affected. They receive the name as the %{product_name} argument, which is
# interpolated after the lookup, and their views pass Docuseal::UPSTREAM_NAME.
module WesignBrandI18n
  UPSTREAM_NAME = /DocuSeal(?! (?:Pro|Console)\b)/
  VENDOR_SUPPORT_EMAIL = 'support@docuseal.com'
  KEEP = /docuseal_trusted_signature|trusted_certificate_provided_by_docu_seal|21_cfr_part_11/

  def self.rebrand(entry, key)
    case entry
    when String
      return entry if !entry.match?(/docuseal/i) || key.to_s.match?(KEEP)

      entry.gsub(UPSTREAM_NAME, Docuseal.product_name).gsub(VENDOR_SUPPORT_EMAIL, Docuseal::SUPPORT_EMAIL)
    when Hash
      entry.to_h { |k, v| [k, rebrand(v, k)] }
    else
      entry
    end
  end

  protected

  def lookup(locale, key, scope = [], options = {})
    WesignBrandI18n.rebrand(super, key)
  end
end

I18n::Backend::Simple.prepend(WesignBrandI18n)

# NOTICE - WE Sign (DocuSeal base)

**This repository is a modified version of DocuSeal**, prepared by WE PRIMUS Creative Technologies as the
base of its self-hosted e-signature product, WE Sign.

- Upstream project: https://github.com/docusealco/docuseal
- Modified from upstream commit `44dcc7f312f0f6ca30d8bb9630117fa0c99bd987` (tag `3.3.0`)
- The changes are the difference between this repository and DocuSeal 3.3.0 (upstream commit `44dcc7f`).
- "DocuSeal" is the name of the upstream project. WE Sign is not endorsed by or affiliated with it.

## What this fork changes in the interface (branding layer, 30 Sep 2026)

How the product works is not changed by this layer. The record of copied files is [`ASSET-SOURCES.md`](ASSET-SOURCES.md).

**Name.** The product is shown as "WE Sign". The name is one setting: `PRODUCT_NAME` in `lib/docuseal.rb`, read from the
environment variable `PRODUCT_NAME`. Upstream's language file (`config/locales/i18n.yml`) is not edited; its "DocuSeal"
occurrences are replaced when a translation is looked up (`config/initializers/wesign_brand.rb`).

**The DocuSeal credit is kept, in a shortened form.** By decision of the product owner (30 Sep 2026) it reads only
"Powered by DocuSeal": plain text, no link on the name, nothing after it. The name is a separate constant
(`Docuseal::UPSTREAM_NAME`) so that it cannot follow the product name. It is shown:

- on every signer-facing page, on the completion screen (`app/javascript/submission_form/completed.vue`), at the foot of
  every staff page and on the landing page, each time with the source-offer link beside it (see below);
- at the foot of the sign-in, two-factor, password-reset and invitation pages, without the source-offer link;
- at the foot of every e-mail, as the line "Powered by DocuSeal" in every mode;
- in the header of the audit PDF, under the product name;
- in the PDF Creator field, which reads "WE Sign (built on DocuSeal)";
- on the printable QR sheet of a shared link, as the same plain line.

Changed with the name: the reason written into the digital signature of a signed document names the signers and the
product, "Signed by <signers> with WE Sign", and the seal of the audit log reads "Audit log sealed with WE Sign"
(upstream: "Signed with DocuSeal.com" in both; `lib/submissions/generate_result_attachments.rb`,
`lib/submissions/generate_audit_trail.rb`). The self-made signing certificate created at first-run setup is issued to
the brand pack's legal name, or to the product name when the pack has none (`app/controllers/setup_controller.rb`).
Unchanged: the webhook User-Agent, the "DocuSeal" watermark of the stamp field.

**The identity beside it comes from a brand pack.** Each installation carries its own logo, icons, colours, typeface,
corner radius and names: one folder under `brands/`, chosen by the environment variable `BRAND` when the application
starts (`lib/brand.rb`; how to add one: `README.md`, "Brand packs"). The default pack, `we-primus`, is the product's
own look: WE PRIMUS lockup and monogram, the Onest typeface, the WE PRIMUS product palette, corners of 4px on the
sign-in pages. Client brand packs are installation data and are not part of this repository.
A pack may show its logo alone, with no product name beside it (`logo_leads_alone`), choose what the in-app headers
show: the logo and the product name, the logo alone or the product name alone (`header`; the header of the audit PDF
follows it), add one line of plain text under the attribution line of staff and signer pages (`footer_credit`), put
its legal name in the header of the audit PDF (`legal_name`), and carry the builder's signature in the bottom-right
corner of the sign-in photograph: the builder's name, in words or as its logo, and a support line with its address
(`builder_credit`, `builder_logo`, `support_email`). The default pack shows the product name alone in its in-app headers and "WE PRIMUS" under the
attribution line; its sign-in panel keeps the logo with the product name.
A pack may also carry an opening film, played whole once per browser session right after a successful staff sign-in,
before the dashboard is seen (the owner's decision, 30 Sep 2026). It never plays for a failed sign-in, on a signer
page, or for someone who asked for reduced motion; a click or a key skips it. The sign-in itself is not changed by it:
the page only listens for the result.
A pack never changes the DocuSeal credit or the source offer: they are the same in every pack.

**One decided exception to the corner rule of every pack.** Sign-in panel: glass treatment and tablet-like corner
radius, decided by the owner on 30 Sep 2026. On the staff sign-in, two-factor, password-reset and invitation pages the
panel is white at 35% over a blurred backdrop, with 24px corners and no border; its fields and button use 12px. The
rest of these pages keeps the pack's radius. Where the browser has no `backdrop-filter`, and on phones and narrow
windows, the panel is plain paper. The owner designed this panel and it stays as it is in every pack, also where a
pack's brand kit allows no glass effect or only smaller corners: it is the owner's exception to those rules, for this
panel only.

**The in-app pages have the product's own look, in every pack** (the owner's decision, 30 Sep 2026). On every page
after sign-in, staff and signer, the owner overrides the corner rules of the brand kits (WE PRIMUS: 5px and 4px):
controls have 8px corners, cards, panels and dialogs 12px, and avatars, toggles and pills are round. Each screen has
one solid main action and soft secondary ones, button labels are not upper-case, and titles and fields are lighter. A
pack still sets the colours, the font and the logos. The sign-in pages keep each pack's own corners.

**Source offer (AGPL-3.0 section 13).** A "Source code" link stands next to the credit on the signer pages, the
completion screen and the staff pages, not on the sign-in pages. Its address is one setting: `SOURCE_CODE_URL` (default
`https://github.com/WEPRIMUS/we-sign`).

**Removed: vendor promotion and hand-offs.** The console redirect (it sent the staff browser to the vendor's console with
a token signed by this installation's secret) with its `/upgrade` and `/manage` addresses; the "Upgrade", "Plans",
"Console", "Learn more" and "Unlock with DocuSeal Pro" links and notices (the places now say "Not included in this
edition."); the newsletter page that posted the administrator's e-mail address to the vendor (first-run setup now goes
straight to the dashboard); the GitHub, Discord and chat links in the staff menu; the embedding snippets; the vendor's
default sender and support addresses (`SUPPORT_EMAIL`, `SMTP_FROM`); the vendor's social-media tags and icons.

## Licence

GNU Affero General Public License version 3 (AGPL-3.0), full text in [`LICENSE`](LICENSE), together with
the additional term in [`LICENSE_ADDITIONAL_TERMS`](LICENSE_ADDITIONAL_TERMS), quoted here in full:

> In accordance with Section 7(b) of the GNU Affero General Public License,
> a covered work must retain the original DocuSeal attribution in interactive
> user interfaces.

`LICENSE`, `LICENSE_ADDITIONAL_TERMS` and every upstream copyright notice are kept exactly as upstream
published them. The DocuSeal credit and the DocuSeal name always stay in the user interfaces: by decision of the
product owner they are shown as the plain line "Powered by DocuSeal", the name not linked, in every brand pack.

Under AGPL-3.0 section 13, people who use a running instance over a network must be offered the source of
the version that is running, including our changes. That offer is the "Source code" link, which stays on the signer
pages and the staff pages.

# WE Sign

WE Sign is a self-hosted e-signature system: staff upload a document, place the fields, and send it; each signer
confirms a code sent by e-mail, fills in and signs in the browser, and receives the signed PDF with its audit record.
It is built by WE PRIMUS Creative Technologies.

## Based on DocuSeal

WE Sign is a modified version of [DocuSeal](https://github.com/docusealco/docuseal), version 3.3.0 (upstream commit
`44dcc7f312f0f6ca30d8bb9630117fa0c99bd987`). What this repository changes is the difference between it and that
commit; [`NOTICE-WE-SIGN.md`](NOTICE-WE-SIGN.md) describes it. Upstream's own README is kept unchanged as
[`README.DocuSeal.md`](README.DocuSeal.md).

"DocuSeal" is the name of the upstream project. WE Sign is not endorsed by or affiliated with it.

## Licence

GNU Affero General Public License version 3 ([`LICENSE`](LICENSE)), with the additional term under its section 7(b)
in [`LICENSE_ADDITIONAL_TERMS`](LICENSE_ADDITIONAL_TERMS): a covered work must retain the original DocuSeal
attribution in its interactive user interfaces. WE Sign shows it on every page as the plain line "Powered by
DocuSeal", in every brand pack.

Under section 13 of the licence, whoever uses a running instance over a network must be offered the source of the
version that is running. WE Sign makes that offer with the "Source code" link beside the attribution line on the signer
and staff pages; its address is the setting `SOURCE_CODE_URL`. If you run a modified copy, point it at your source.

Upstream's notice: unless otherwise noted, all files © 2023-2026 DocuSeal LLC.

## Run it with Docker

Docker with Compose v2 is all it needs. The image is built from this repository's own [`Dockerfile`](Dockerfile);
it is not the upstream image `docuseal/docuseal`.

[`docker-compose.wesign.local.yml`](docker-compose.wesign.local.yml) is a complete trial on one machine, reachable only
from that machine:

| Service | Image | Address |
| --- | --- | --- |
| Application | built from `Dockerfile` | not published; reached through the proxy |
| PostgreSQL | `postgres:18.6` | not published |
| Proxy (HTTPS) | `caddy:2.11.4` | https://127.0.0.1:3141 |
| Mail catcher | `axllent/mailpit:v1.31.3` | http://127.0.0.1:8141 (every outgoing e-mail lands here) |

```sh
# once: the settings file, then replace every __NAME__ in it
cp .env.wesign.example .env.wesign.local
#   SECRET_KEY_BASE               openssl rand -hex 64
#   WESIGN_DB_SUPERUSER_PASSWORD  openssl rand -hex 24
#   WESIGN_DB_APP_PASSWORD        openssl rand -hex 24  (a different value; letters and digits only)

# build the image and start the four containers
docker compose --env-file .env.wesign.local -f docker-compose.wesign.local.yml up -d --build

# all four "healthy"?
docker compose --env-file .env.wesign.local -f docker-compose.wesign.local.yml ps
```

Open https://127.0.0.1:3141. The certificate comes from Caddy's own local authority, which no browser trusts, so the
browser warns once. A new installation opens `/setup`: it creates the first administrator and the signing
certificate, issued to the brand pack's `legal_name` (to the product name when the pack has none) and its
`legal_country` (no country when the pack has none).

The application runs with `FORCE_SSL=true`: it builds https links, marks every cookie Secure and sends an HSTS header.
It must run behind TLS, because the cookie that records a signer's accepted e-mail code is Secure: over plain HTTP no
signer gets past the code. `.env.wesign.local` is ignored by git and by the Docker build; never commit it.

| Setting | Default | What it does |
| --- | --- | --- |
| `APP_URL` | none | The public address; every link in every e-mail is built from it |
| `BRAND` | `we-primus` | The brand pack (below). An unknown name stops the application at start |
| `PRODUCT_NAME` | `WE Sign` | The product name wherever a user sees it |
| `SOURCE_CODE_URL` | `https://github.com/WEPRIMUS/we-sign` | The "Source code" link (licence section 13) |
| `SUPPORT_EMAIL` | `support@example.com` | The support address shown to staff; the sender when no SMTP sender is set |
| `SMTP_FROM` | none | Sender name and address of every e-mail |

A real installation also needs: TLS at its own reverse proxy (the trial's Caddy and Mailpit are for the trial only),
a real SMTP relay (every signer must receive a code by e-mail, so without mail nobody can sign), `SECRET_KEY_BASE`
kept safe (the signing certificate in the database is encrypted with a key derived from it), backups of the database
and the data volume taken together, and a fresh instance kept unreachable until `/setup` is done.

The test suite runs in Docker against a throw-away PostgreSQL, with no ports, volumes or secrets:

```sh
docker compose -f docker-compose.wesign.test.yml run --build --rm wesign-ds-test
```

## Brand packs

One image serves every installation. What differs between installations is a brand pack: one folder under `brands/`
with the logo, icons, colours, typeface, corners, sign-in photograph and names, chosen by `BRAND` when the
application starts ([`lib/brand.rb`](lib/brand.rb)). Only the chosen pack is served to browsers, under
`/brand/<name>-<digest>/`, and of it only what a page uses (`.css`, `.png`, `.webp`, `.woff2`, `.mp4`): never `pack.yml`
or a licence text. The JavaScript and CSS bundles are the same for every pack: they read its variables.

This repository holds the default pack, `we-primus`. Client brand packs are installation data and are not part of
this repository.

To add a pack:

1. **Copy** `brands/we-primus` to `brands/<name>`: lower-case letters, digits and hyphens.
2. **Replace the files** with the client's, under the same names (table below), copied from the client's brand kit
   unchanged. Keep a record of each file's source and SHA-256; this repository's own record is
   [`ASSET-SOURCES.md`](ASSET-SOURCES.md).
3. **Edit `pack.yml`** (options below).
4. **Edit `theme.css`**: every variable in its `html:root` block. Theme colours are written `H S% L%` (no `hsl()`,
   no commas), the `--brand-*` colours `R G B`. If the font changes, put its `.woff2` file and its licence in the
   folder and name it in the `@font-face` rule. Nothing may be loaded from another host.
5. **Check it**: `docker compose -f docker-compose.wesign.test.yml run --build --rm wesign-ds-test bundle exec rspec spec/requests/wesign_brand_pack_spec.rb`.
   It loads every pack under `brands/` and fails on a missing file, name or variable.
6. **Run it**: set `BRAND=<name>` and run the `up -d --build` line once, so that the folder gets into the image.
   After that, switching packs is `BRAND` and `up -d`.

| `pack.yml` option | Needed | What it does |
| --- | --- | --- |
| `public_name` | yes | The alternative text of the logo |
| `page_color` | yes | Hex colour of the page (`--b1` in `theme.css`): browser toolbar, web app manifest, bands of the audit PDF |
| `legal_name` | no | The legal entity of the installation: printed in the header of the audit PDF, and the name the first-run signing certificate is issued to |
| `legal_country` | no | The country of that legal entity, as a two-letter ISO 3166 code in capitals (`AE`; Norway in quotes, `"NO"`): the `C=` of the first-run signing certificate. Without it the certificate names no country. Any other value stops the application at start |
| `logo_leads_alone` | no | `true`: no product name stands beside the logo on the sign-in panel, nor in the in-app headers unless `header` says otherwise |
| `header` | no | What the in-app headers show (staff, signer, start-form and QR pages, and the header of the audit PDF): `logo_and_name` (the default), `logo` (the default when `logo_leads_alone` is `true`) or `name`. Any other value stops the application at start. The sign-in panel follows `logo_leads_alone` only |
| `footer_credit` | no | One line of plain text under the attribution line of staff and signer pages, centred, in the same size and colour. The attribution line itself does not change |
| `builder_credit`, `support_email` | no | The builder's signature and a support line with its address, in the bottom-right corner of the sign-in photograph (where the photograph fills the page; on phones only the support line shows, under the form) |
| `builder_logo` | no | A file in the pack: the builder's logo, shown in that corner in place of the name, with `builder_credit` as its alternative text, never a link. A name that is not a file in the pack stops the application at start |

| File | Needed | Format | Where it shows |
| --- | --- | --- | --- |
| `pack.yml` | yes | text | names and page colour |
| `theme.css` | yes | text | colours and font on every page; corners and bold weight on the sign-in pages |
| `logo-light.png` | yes | PNG on a transparent ground, 600 px wide or more | sign-in panel; the headers of staff, signer, start-form and QR pages (28 to 56 px high) and of the audit PDF (28 pt high), unless `header` is `name` |
| `logo-dark.png` | no | the same, for dark surfaces | no page has a dark surface yet |
| `mark.png` | no | compact mark, PNG, 200 px high or more | template builder, document view, upload screen (28 to 50 px high); without it, `logo-light.png` |
| `favicon-32.png` | no | PNG, 32 x 32 px | browser tab; without it, `icon-192.png` |
| `favicon-16.png` | no | PNG, 16 x 16 px, drawn for that size | browser tab at 16 px, offered beside `favicon-32.png` |
| `apple-touch-icon.png` | yes | PNG, 180 x 180 px, opaque | home-screen icon on iOS |
| `icon-192.png`, `icon-512.png` | yes | PNG, 192 and 512 px square | web app manifest, browser tab, link preview |
| `login-photo-1920.webp`, `-2560.webp`, `-3840.webp` | no, all three or none | WebP, 16:9: 1920 x 1080, 2560 x 1440, 3840 x 2160 px; the subject right of the middle (the glass panel covers the left third) | sign-in, two-factor, password-reset and invitation pages; without them the page is plain |
| a font and its licence | no | `.woff2`, named in `theme.css` | every page |
| the file named by `builder_logo` | no | PNG on a transparent ground, the builder's logo for light surfaces, unchanged from its kit | the corner of the sign-in photograph, 216 px wide |
| `opening.mp4` | no | MP4 (H.264, AAC), 16:9, the index at the front, under 1 MB; with it `--brand-opening-color` in `theme.css`, the colour of the film's own field | played once per browser session right after a successful staff sign-in; never on a failed sign-in, a signer page, or with reduced motion |

A pack cannot change the product name (`PRODUCT_NAME`), the line "Powered by DocuSeal", the "Source code" link, or the
glass panel of the sign-in page.

## Security

Report a vulnerability by e-mail to support@we-primus.com, not in a public issue: see [`SECURITY.md`](SECURITY.md).

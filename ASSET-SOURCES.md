# ASSET-SOURCES - WE Sign (DocuSeal base)

Every file in this repository that was copied or made from material outside it, with its source and its licence.
Files copied from a brand kit are unchanged: each SHA-256 below was computed on the copy in this repository and
matches the kit's own manifest.

The files of a brand live in its brand pack, one folder under `brands/` (`README.md`, "Brand packs"). A pack gives its
files fixed names (`logo-light.png`, `icon-192.png`, ...), so a copy is renamed; its bytes are not changed.

## A. WE PRIMUS brand kit: pack `brands/we-primus`

Source: the brand kit of WE PRIMUS Creative Technologies, the builder of WE Sign. The paths below are inside that kit.

| File in this repository | Source in the kit | Use | SHA-256 |
| --- | --- | --- | --- |
| `brands/we-primus/logo-light.png` | `assets\logos\web\we-primus-primary.png` | Primary lockup on light surfaces: the sign-in panel. The pack's in-app headers and the header of the audit PDF show the product name alone (`header: name` in `pack.yml`) | `5392d9254d92a34b61c809762b6bd301a3986f01519c7c369f70e75172643399` |
| `brands/we-primus/logo-dark.png` | `assets\logos\web\we-primus-reversed.png` | Reversed lockup, the pack's logo for dark surfaces. No page has a dark surface today, so no page shows it. | `3dce101ee1f2f78db2e8108f2922acf8a796f88a7d1bf2d3ed290786ab60084f` |
| `brands/we-primus/mark.png` | `assets\monograms\we-monogram-sage.png` | Compact monogram where the lockup does not fit: template builder, document view header, upload/processing screen | `0179bcb7de56156aaaac6dff087d2b04188f912f24417e68450251b1892389af` |
| `brands/we-primus/favicon-32.png` | `assets\icons\favicon-32.png` | Favicon (`<link rel="icon">`), and what `/favicon.ico` redirects to (the name browsers request when a response has no icon link: a PDF or an image opened in a tab) | `c5d95a5340cd909323aaff65820525f8a4ad9a02abda7fae1062750dab521024` |
| `brands/we-primus/apple-touch-icon.png` | `assets\icons\apple-touch-icon.png` | Apple touch icon | `74d52a75193a6b17e4a0e7b55a5baa9ed42118015db9b6ed0995a15d19965aa9` |
| `brands/we-primus/icon-192.png` | `assets\icons\we-primus-icon-192.png` | Application icon 192 (web app manifest, icon link) | `cb19939d59a4b5385045227a0aec4b87090134948ead1373dbc0e55572126678` |
| `brands/we-primus/icon-512.png` | `assets\icons\we-primus-icon-512.png` | Application icon 512 (web app manifest, link-preview image) | `a516a9a843f13c0624ed7077d10bdd7c3fa7f27d31fb0ca23278feb05157336e` |
| `brands/we-primus/onest-latin.woff2` | `assets\fonts\onest-latin.woff2` | Onest variable font (weight 100-900), Latin subset, SIL Open Font License 1.1. Notice beside it: `brands/we-primus/OFL-Onest.txt`. | `67849bcc11e02177442da14ad954bfe1cc709553dad137b5003449b303e83fc3` |

Colours are not copied files: the values of the kit's design tokens and its product palette are written into
`brands/we-primus/theme.css` (and, as the defaults the bundles are built with, into `tailwind.config.js`).

## B. Sign-in photograph

One picture is shipped, at three widths, so that a screen downloads no more than it can show. It is a pack file:
each pack that shows it holds its own copy, and a pack without it gets a plain sign-in page.

| File in `brands/we-primus/` | Pixels | Size | SHA-256 |
| --- | --- | --- | --- |
| `login-photo-1920.webp` | 1920 x 1080 | 176 KB | `b7232ceedd088d72393c8511b7f1dc7bff812b1e0949324facc22de4cb8f0f03` |
| `login-photo-2560.webp` | 2560 x 1440 | 226 KB | `e9656b0ca137fa2920388827ca53945b8f4cd5a610262f7820ead2236c5f5659` |
| `login-photo-3840.webp` | 3840 x 2160 | 311 KB | `6a72c2b447fa7170f3a210ad4b7b5cd723f74576b27865ba04bf37a9a60a2535` |

Source: an image made for WE Sign with xAI's Grok image generation (30 September 2026, 3840 x 2160 px), under xAI's
terms for generated images. It is not a stock photograph. Before use it was retouched to paint out the lettering of
a real company's name on a tower at the top-left (about 120 x 32 px). Neither the generated original nor the
retouched master is in this repository.

What was done to the retouched master to make the shipped files (no upscaling, no sharpening; the 2560 and 1920 files
are Lanczos downscales of the 3840 result; WebP quality 80 / 84 / 86):

- sky and water (hue 170-235 in the window area, above the desk and outside the tablet): saturation x0.80;
- plant greens (hue 55-115): hue pulled 35% toward 100, saturation unchanged;
- teal accents (hue 150-205) inside the tablet and the notebook only: hue pulled 60% toward 174, the hue of dark
  teal `#0B2523`, value x0.97;
- unchanged (measured, 0/255): the jacket, the hands, the wooden desk; the laptop and the mug change by at most 5/255.

The photograph is found by its three file names (`app/views/layouts/devise.html.erb`). To replace it in a pack, put
files of the same names and widths in the pack's folder; if the subject sits elsewhere in the picture, adjust the two
`object-position` values of `.we-auth-photo` in `app/javascript/brand/brand.scss` (they apply to every pack).

## C. Files written for this fork (not copied)

- `config/initializers/wesign_brand.rb`, `config/locales/wesign_brand.yml` - the naming mechanism and the fork's own strings
- `lib/brand.rb` - the brand pack of the installation: which one, its files, its names
- `brands/<pack>/pack.yml`, `brands/<pack>/theme.css` - a pack's names, and its colours, font and corners
- `app/javascript/brand/brand.scss` - readable-text rules and the sign-in page, for every pack
- `app/javascript/brand/opening.js` - plays a pack's opening film after a successful sign-in
- `brands/we-primus/OFL-Onest.txt` - the font's copyright line (as embedded in the font file) and the OFL 1.1 text
- `app/views/layouts/devise.html.erb` - layout of the sign-in, two-factor, password-reset and invitation pages
- `spec/fixtures/brands/sample/` - a stand-in brand pack for the tests only: plain colours, and images of one colour
  generated for the tests

## D. Files removed because they were vendor branding or vendor hand-offs, or were replaced by a pack

All are in upstream DocuSeal 3.3.0 (commit `44dcc7f3`).

- `public/favicon.ico` of this fork (a copy of the WE PRIMUS favicon): `/favicon.ico` now redirects to the icon of the
  selected pack
- Vendor icons and images in `public/`: `favicon.svg`, `favicon-16x16.png`, `favicon-32x32.png`, `favicon-96x96.png`,
  `apple-icon-180x180.png`, `apple-touch-icon.png`, `apple-touch-icon-precomposed.png`, `logo.svg`, `preview.png`
- `app/controllers/console_redirect_controller.rb` (sent the staff browser to the vendor's console with a signed token)
- `app/controllers/newsletters_controller.rb`, `app/views/newsletters/show.html.erb`, `spec/system/newsletters_spec.rb`
  (posted the administrator's e-mail address to the vendor)
- `app/views/shared/_github.html.erb` (the vendor's GitHub star badge)

Kept in the repository: `lib/pdf_icons/stamp-logo.png` (the "DocuSeal" watermark drawn inside a stamp field of a signed
document; still used) and `lib/pdf_icons/logo.png` (the vendor's round mark; no longer drawn, the audit PDF credits
DocuSeal by name, in plain text).

## E. Downloaded when the image is built (not in the repository)

The `Dockerfile` downloads from GitHub, as upstream does, the fonts GoNotoKurrent Regular and Bold and Dancing Script
with their licence texts, the field-detection model and the PDF engine (pdfium). The fonts, the model and the engine
are checked against a SHA-256 written in the `Dockerfile`, and a changed file fails the build; the two licence texts
are not checked.

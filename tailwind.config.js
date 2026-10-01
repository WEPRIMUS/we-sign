const defaultTheme = require('tailwindcss/defaultTheme')

// WE Sign: the colours below are the WE PRIMUS product palette (brand-systems/we-primus,
// SESSION-BRAND-CONTRACT.md and tokens/we-primus-tokens.css). They are only the build-time defaults: the
// stylesheet of the selected brand pack (brands/<pack>/theme.css, loaded on every page) sets every one of them
// again at run time, together with the --brand-* variables used here. The theme keeps its upstream name so no
// layout has to change.
const we = {
  teal: '#0B2523', // dark teal: main buttons and dark fields
  green: '#A6E243', // light green: active state; text on it is dark teal
  slate: '#324441', // --we-ink-soft
  coral: '#f07456', // fill only, never text on a light surface (2.9:1)
  blue: '#0da1de',
  amber: '#e6b14e',
  ink: '#0b2826', // --we-ink
  canvas: '#f6f8f2', // --we-canvas
  paper: '#fcfdfa', // --we-paper
  paperWarm: '#f0efe2', // --we-paper-warm
  sage: '#deeadd', // --we-surface-sage
  // corners: the shared modern layer (brand.scss), the pack's own corners on the sign-in pages
  radius: 'var(--radius-control)', // controls: buttons, fields, badges, menus
  radiusBox: 'var(--radius-box)', // cards, panels, dialogs
  radiusFull: 'var(--radius-full)' // avatars, toggles, pills, dots
}

module.exports = {
  future: {
    hoverOnlyWhenSupported: true
  },
  plugins: [
    require('daisyui')
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['var(--brand-font)', ...defaultTheme.fontFamily.sans]
      },
      fontWeight: {
        bold: 'var(--weight-bold)' // section titles and bold text (brand.scss)
      },
      // raised surfaces (bg-white and the like): white, or the pack's own paper white
      colors: {
        white: 'rgb(var(--brand-raised) / <alpha-value>)'
      },
      // secondary copy: upstream's gray-500 is 4.1:1 on the warm surface, the pack's muted tone is readable;
      // text-white is the text on dark buttons
      textColor: {
        gray: { 500: 'rgb(var(--brand-muted) / <alpha-value>)' },
        white: 'rgb(var(--brand-on-dark) / <alpha-value>)'
      },
      borderRadius: {
        DEFAULT: we.radius,
        md: we.radius,
        lg: we.radius,
        xl: we.radiusBox,
        '2xl': we.radiusBox,
        '3xl': we.radiusBox,
        full: we.radiusFull
      }
    }
  },
  daisyui: {
    themes: [
      {
        docuseal: {
          'color-scheme': 'light',
          primary: we.green,
          'primary-content': we.teal,
          secondary: we.slate,
          'secondary-content': we.paper,
          accent: we.amber,
          'accent-content': we.teal,
          neutral: we.teal,
          'neutral-content': we.paper,
          'base-100': we.canvas,
          'base-200': we.paperWarm,
          'base-300': we.sage,
          'base-content': we.ink,
          info: we.blue,
          'info-content': we.teal,
          success: we.green,
          'success-content': we.teal,
          warning: we.amber,
          'warning-content': we.teal,
          error: we.coral,
          'error-content': we.teal,
          '--rounded-box': we.radiusBox,
          '--rounded-btn': we.radius,
          '--rounded-badge': we.radius,
          '--tab-border': '2px',
          '--tab-radius': we.radius
        }
      }
    ]
  }
}

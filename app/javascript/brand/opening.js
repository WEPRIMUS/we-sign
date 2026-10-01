// WE Sign: the opening of a brand pack. A pack that holds opening.mp4 (its approved logo reveal, with sound)
// has it played once per browser session, right after a successful staff sign-in and before the dashboard is
// seen. The sign-in pages name the film in <meta name="brand-opening"> (app/views/layouts/devise.html.erb);
// a pack without one has no such tag and nothing here runs.
//
// The sign-in form is submitted by Turbo exactly as before: this file only listens, it never submits and never
// touches the request. Turbo swaps <body> for the dashboard while the panel, which hangs on <html>, stays.
// The film is used whole: nothing over it, never cropped (object-fit: contain), it ends on its last frame.

const PLAYED = 'brand-opening-played'

let video = null
let form = null

const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches
const played = () => { try { return !!window.sessionStorage.getItem(PLAYED) } catch { return true } }
const isSignIn = (el) => form && el?.method === 'post' && new URL(el.action).pathname === form

// On a sign-in page: fetch the film ahead of the click, so that it starts at once.
function prepare () {
  const meta = document.querySelector('meta[name="brand-opening"]')

  if (!meta || video || played() || reducedMotion()) return

  form = meta.dataset.form
  video = Object.assign(document.createElement('video'), { src: meta.content, preload: 'auto', playsInline: true })
  video.load()
}

// Browsers let a page play sound only from a click or a key press, and Safari wants the element itself touched
// inside that gesture. So the film is started and paused at once while the form is being sent; nothing is seen
// or heard yet.
function unlock (event) {
  if (!video || !isSignIn(event.target)) return

  video.play()?.catch(() => {})
  video.pause()
}

// Only when the sign-in has succeeded: the answer is a redirect away from the sign-in page. A wrong password or
// a two-factor prompt comes back as the sign-in page and shows nothing.
function open (event) {
  const response = event.detail.fetchResponse?.response

  if (!video || !isSignIn(event.target) || !event.detail.success) return
  if (!response?.redirected || new URL(response.url).pathname === form) return

  const film = video
  const panel = Object.assign(document.createElement('div'), { className: 'brand-opening' })
  const finish = () => {
    if (panel.classList.contains('done')) return

    panel.classList.add('done')
    film.pause()
    window.removeEventListener('keydown', finish)
    setTimeout(() => panel.remove(), 500)
  }

  video = null
  try { window.sessionStorage.setItem(PLAYED, '1') } catch { /* private mode: it plays again next time */ }

  film.addEventListener('ended', finish)
  film.addEventListener('error', finish) // the file is missing: carry on without it
  panel.addEventListener('click', finish) // a click skips it
  window.addEventListener('keydown', finish) // so does any key
  panel.append(film)
  document.documentElement.append(panel)

  film.currentTime = 0
  // If the browser still refuses the sound, play it silent rather than not at all.
  film.play().catch(() => { film.muted = true; film.play().catch(finish) })
}

document.addEventListener('turbo:load', prepare)
document.addEventListener('submit', unlock, true)
document.addEventListener('turbo:submit-end', open)

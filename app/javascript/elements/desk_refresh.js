// Contract Desk: reloads the page every few seconds while the desk is working on something shown on it. A repeating
// timer, because Turbo refreshes the same page by morphing it and keeps this element (it is not connected again).
// Leaving the page, or a refresh after which nothing is being prepared, removes the element, which stops it.
export default class extends HTMLElement {
  connectedCallback () {
    this.interval = setInterval(() => window.Turbo.visit(window.location.href, { action: 'replace' }), 6000)
  }

  disconnectedCallback () {
    clearInterval(this.interval)
  }
}

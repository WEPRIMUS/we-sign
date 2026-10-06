// Contract Desk question forms: "+ Add another" copies the blank row kept in the <template>; the remove button takes
// its row out.
export default class extends HTMLElement {
  connectedCallback () {
    this.addEventListener('click', this.onClick)
  }

  disconnectedCallback () {
    this.removeEventListener('click', this.onClick)
  }

  onClick = (event) => {
    const add = event.target.closest('[data-add-row]')
    const remove = event.target.closest('[data-remove-row]')

    if (add) {
      const rows = this.querySelector('[data-rows]')

      rows.append(this.querySelector('template').content.cloneNode(true))
      rows.lastElementChild.querySelector('input, select, textarea').focus()
    } else if (remove) {
      remove.closest('[data-row]').remove()
    }
  }
}

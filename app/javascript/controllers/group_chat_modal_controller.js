import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["nameInput", "searchInput", "selectedPills", "contactList", "contactItem"]

  connect() {
    this._selectedIds = new Set()
  }

  filterContacts() {
    const query = this.searchInputTarget.value.toLowerCase()
    this.contactItemTargets.forEach(item => {
      const name = item.dataset.contactName.toLowerCase()
      item.style.display = name.includes(query) ? "" : "none"
    })
  }

  toggleContact(e) {
    const btn = e.currentTarget
    const userId = btn.dataset.userId
    const name = btn.dataset.contactName
    const checkIcon = btn.querySelector("[data-check-icon]")

    if (this._selectedIds.has(userId)) {
      this._selectedIds.delete(userId)
      checkIcon?.classList.add("hidden")
      // Remove hidden input and pill
      this.selectedPillsTarget.querySelector(`[data-pill-id="${userId}"]`)?.remove()
      this.element.querySelector(`input[value="${userId}"][name="group_chat[member_ids][]"]`)?.remove()
    } else {
      this._selectedIds.add(userId)
      checkIcon?.classList.remove("hidden")
      // Add hidden input
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "group_chat[member_ids][]"
      input.value = userId
      this.element.querySelector("form").appendChild(input)
      // Add pill
      const pill = document.createElement("span")
      pill.dataset.pillId = userId
      pill.className = "inline-flex items-center bg-gray-700 text-gray-200 text-xs px-2 py-1 rounded-full"
      pill.innerHTML = `${this._escapeHtml(name)} <button type="button" class="ml-1 text-gray-400 hover:text-white" data-remove-user="${userId}">&times;</button>`
      pill.querySelector("button").addEventListener("click", () => {
        this._selectedIds.delete(userId)
        checkIcon?.classList.add("hidden")
        pill.remove()
        this.element.querySelector(`input[value="${userId}"][name="group_chat[member_ids][]"]`)?.remove()
      })
      this.selectedPillsTarget.appendChild(pill)
    }
  }

  _escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

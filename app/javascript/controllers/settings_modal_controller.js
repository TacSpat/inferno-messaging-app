import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay", "content", "nav"]

  connect() {
    this.handleEsc = (e) => { if (e.key === "Escape") this.close() }
    this.handleOpen = () => this.open()
    document.addEventListener("keydown", this.handleEsc)
    document.addEventListener("open-settings", this.handleOpen)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleEsc)
    document.removeEventListener("open-settings", this.handleOpen)
  }

  open() {
    this.overlayTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.loadSection("my-account")
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  closeOnBackdrop(e) {
    if (e.target === this.overlayTarget) this.close()
  }

  showNav() {
    const sidebar = this.overlayTarget.querySelector(".settings-sidebar-mobile")
    if (sidebar) {
      sidebar.style.cssText = "display:flex !important;position:fixed;inset:0;z-index:95;width:100%;min-width:100%;"
    }
  }

  async navigate(e) {
    e.preventDefault()
    const section = e.currentTarget.dataset.section
    // On mobile, hide nav overlay after selection
    const sidebar = this.overlayTarget.querySelector(".settings-sidebar-mobile")
    if (sidebar && window.innerWidth < 768) {
      sidebar.style.cssText = ""
    }
    this.loadSection(section)
  }

  async loadSection(section) {
    this.navTarget.querySelectorAll("[data-section]").forEach(el => {
      el.classList.toggle("bg-gray-700", el.dataset.section === section)
      el.classList.toggle("text-white", el.dataset.section === section)
    })

    try {
      const res = await fetch(`/settings/${section}`, {
        headers: { "Accept": "text/html", "X-Requested-With": "XMLHttpRequest" }
      })
      if (res.ok) {
        this.contentTarget.innerHTML = await res.text()
      }
    } catch (err) {
      console.error("Failed to load settings section:", err)
    }
  }

  async submitForm(e) {
    console.log("[settings-modal] submitForm triggered")
    e.preventDefault()
    const form = e.target
    const formData = new FormData(form)
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      const res = await fetch(form.action, {
        method: "PATCH",
        body: formData,
        headers: {
          "X-CSRF-Token": csrf,
          "X-Requested-With": "XMLHttpRequest"
        }
      })
      const html = await res.text()
      this.contentTarget.innerHTML = html
      if (res.ok) {
        this.showToast("Changes saved!")
        // Reload page after short delay to reflect changes
        setTimeout(() => window.location.assign(window.location.pathname), 1000)
      }
    } catch (err) {
      console.error("Save failed:", err)
    }
  }

  showToast(msg) {
    const toast = document.createElement("div")
    toast.className = "fixed bottom-6 right-6 bg-green-600 text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium"
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 2000)
  }
}

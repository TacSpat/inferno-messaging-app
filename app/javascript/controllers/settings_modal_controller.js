import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay", "content", "nav", "sidebar"]

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

    // On mobile, show sidebar first so user can pick a section
    if (window.innerWidth < 768) {
      this.showNav()
    } else {
      this.loadSection("my-account")
    }
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    // Reset sidebar state
    if (this.hasSidebarTarget) {
      this.sidebarTarget.style.cssText = ""
    }
  }

  closeOnBackdrop(e) {
    if (e.target === this.overlayTarget) this.close()
  }

  showNav() {
    if (!this.hasSidebarTarget) return
    this.sidebarTarget.style.cssText = "display:flex !important;position:fixed;inset:0;z-index:95;width:100%;min-width:100%;justify-content:flex-start;background-color:#141312;"
  }

  async navigate(e) {
    e.preventDefault()
    const section = e.currentTarget.dataset.section
    // On mobile, hide nav overlay after selection
    if (this.hasSidebarTarget && window.innerWidth < 768) {
      this.sidebarTarget.style.cssText = ""
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
        setTimeout(() => window.location.assign(window.location.pathname), 1000)
      }
    } catch (err) {
      console.error("Save failed:", err)
    }
  }

  showToast(msg) {
    const toast = document.createElement("div")
    toast.className = "fixed bottom-6 right-6 bg-green-600 text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium context-pop"
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.3s"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 2000)
  }
}

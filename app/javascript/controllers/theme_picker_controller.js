import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { current: String }

  connect() {
    if (this.currentValue) {
      document.documentElement.dataset.theme = this.currentValue
      localStorage.setItem("theme", this.currentValue)
    }

    this._overlay = document.getElementById("settings-overlay")
    this._frame = this._overlay?.querySelector("turbo-frame")
    this._contentArea = this._frame?.querySelector(".flex-1.overflow-y-auto")
    this._sidebar = this._frame?.querySelector("[data-settings-sidebar-target='sidebar']")

    // Nuke ALL backgrounds in the settings overlay chain so the app shows through
    if (this._overlay) {
      this._overlay.classList.remove("bg-gray-900")
      this._overlay.style.backgroundColor = "transparent"
      this._overlay.style.backdropFilter = "none"
    }
    // Walk every element between overlay and our controller, clear any bg (skip sidebar)
    this._clearedBgs = []
    let el = this.element
    while (el && el !== document.body) {
      if (el === this._sidebar) { el = el.parentElement; continue }
      const bg = getComputedStyle(el).backgroundColor
      if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") {
        this._clearedBgs.push({ el, classes: [], style: el.style.backgroundColor })
        for (const cls of el.classList) {
          if (cls.startsWith("bg-")) {
            el.classList.remove(cls)
            this._clearedBgs[this._clearedBgs.length - 1].classes.push(cls)
          }
        }
        el.style.backgroundColor = "transparent"
      }
      el = el.parentElement
    }

    // Add pull tab to sidebar
    if (this._sidebar) {
      this._sidebarCollapsed = false
      this._sidebar.style.transition = "transform 0.3s ease, margin-right 0.3s ease"

      this._pullTab = document.createElement("button")
      this._pullTab.type = "button"
      this._pullTab.className = "hidden md:flex absolute top-1/2 -translate-y-1/2 -right-5 w-5 h-12 items-center justify-center bg-gray-800 border border-gray-700 border-l-0 rounded-r-lg text-gray-400 hover:text-white hover:bg-gray-700 transition cursor-pointer z-10"
      this._pullTab.innerHTML = '<svg class="w-3.5 h-3.5 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>'
      this._pullTab.addEventListener("click", () => this._toggleSidebar())
      this._sidebar.style.position = "relative"
      this._sidebar.appendChild(this._pullTab)
    }

    // Intercept form submit — keep transparency through the Turbo reload
    this._form = this.element.querySelector("form")
    if (this._form) {
      this._submitHandler = (e) => {
        if (this._submitting) return
        this._submitting = true
        // Mark that we're saving so disconnect() doesn't restore backgrounds
      }
      this._form.addEventListener("submit", this._submitHandler)
    }
  }

  _toggleSidebar() {
    if (!this._sidebar) return
    if (this._sidebarCollapsed) {
      this._expandSidebar()
    } else {
      this._collapseSidebar()
    }
  }

  _collapseSidebar() {
    if (!this._sidebar) return
    this._sidebarCollapsed = true
    this._sidebar.style.transform = "translateX(-100%)"
    this._sidebar.style.marginRight = "-14rem"
    if (this._pullTab) {
      this._pullTab.querySelector("svg").style.transform = "rotate(180deg)"
    }
  }

  _expandSidebar() {
    if (!this._sidebar) return
    this._sidebarCollapsed = false
    this._sidebar.style.transform = ""
    this._sidebar.style.marginRight = ""
    if (this._pullTab) {
      this._pullTab.querySelector("svg").style.transform = ""
    }
  }

  preview(e) {
    const theme = e.target.value
    const apply = () => { document.documentElement.dataset.theme = theme }

    if (document.startViewTransition) {
      document.startViewTransition(apply)
    } else {
      apply()
    }
  }

  disconnect() {
    if (this._form && this._submitHandler) {
      this._form.removeEventListener("submit", this._submitHandler)
    }

    // If we're saving, the appearance page reloads — keep everything transparent
    if (this._submitting) {
      // Update currentValue to the newly selected theme
      const checked = this._form?.querySelector("input[name='theme']:checked")
      if (checked) {
        document.documentElement.dataset.theme = checked.value
        localStorage.setItem("theme", checked.value)
      }
      // Clean up pull tab only (new controller will re-create it)
      if (this._pullTab) {
        this._pullTab.remove()
        this._pullTab = null
      }
      return
    }

    document.documentElement.dataset.theme = this.currentValue
    if (this._overlay) {
      this._overlay.style.backgroundColor = ""
      this._overlay.style.backdropFilter = ""
    }
    // Restore all cleared backgrounds
    if (this._clearedBgs) {
      for (const entry of this._clearedBgs) {
        entry.classes.forEach(cls => entry.el.classList.add(cls))
        entry.el.style.backgroundColor = entry.style
      }
      this._clearedBgs = null
    }
    if (this._sidebar) {
      this._sidebar.style.transition = ""
      this._sidebar.style.transform = ""
      this._sidebar.style.marginRight = ""
      this._sidebar.style.position = ""
      if (this._pullTab) {
        this._pullTab.remove()
        this._pullTab = null
      }
    }
  }
}

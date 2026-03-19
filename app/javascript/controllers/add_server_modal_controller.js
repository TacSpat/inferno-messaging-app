import { Controller } from "@hotwired/stimulus"
import { fetchDiscoverServers } from "../lib/server_discover"

export default class extends Controller {
  static targets = ["modal"]

  connect() {
    // Teleport modal to <body> so it escapes the server rail's CSS transform,
    // which creates a containing block that breaks fixed positioning on mobile.
    this._modal = this.modalTarget
    document.body.appendChild(this._modal)

    // Re-bind backdrop click since Stimulus actions don't work outside the controller element
    this._backdropHandler = (e) => {
      if (e.target === this._modal) this.close()
    }
    this._modal.addEventListener("click", this._backdropHandler)

    // Re-bind close button since Stimulus actions don't work outside the controller element
    const closeBtn = this._modal.querySelector("[data-dismiss='modal']")
    if (closeBtn) {
      this._closeHandler = () => this.close()
      closeBtn.addEventListener("click", this._closeHandler)
    }

    this._discoverList = this._modal.querySelector("[data-discover-list]")
  }

  disconnect() {
    if (this._modal) {
      this._modal.removeEventListener("click", this._backdropHandler)
      this._modal.remove()
      this._modal = null
    }
  }

  open() {
    this._modal.classList.remove("hidden")
    if (this._discoverList) {
      fetchDiscoverServers(this._discoverList)
    }
  }

  close() {
    this._modal.classList.add("hidden")
  }

  keydown(e) {
    if (e.key === "Escape") {
      if (this._modal.classList.contains("hidden")) return
      this.close()
    }
  }
}

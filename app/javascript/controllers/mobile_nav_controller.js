import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["serverRail", "channelSidebar", "memberSidebar", "backdrop"]

  connect() {
    this.sidebarOpen = false
    this.membersOpen = false

    // Close sidebars when a Turbo Frame renders (channel/conversation switch)
    this._onFrameRender = () => {
      if (this.sidebarOpen || this.membersOpen) this.closeAll()
    }
    document.addEventListener("turbo:before-frame-render", this._onFrameRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-frame-render", this._onFrameRender)
  }

  toggleSidebar() {
    this.sidebarOpen = !this.sidebarOpen
    this._updateSidebar()
  }

  toggleMembers() {
    this.membersOpen = !this.membersOpen
    this._updateMembers()
  }

  closeAll() {
    this.sidebarOpen = false
    this.membersOpen = false
    this._updateSidebar()
    this._updateMembers()
  }

  _updateSidebar() {
    if (this.hasServerRailTarget) {
      this.serverRailTarget.classList.toggle("mobile-sidebar-open", this.sidebarOpen)
    }
    if (this.hasChannelSidebarTarget) {
      this.channelSidebarTarget.classList.toggle("mobile-sidebar-open", this.sidebarOpen)
    }
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.toggle("hidden", !this.sidebarOpen && !this.membersOpen)
    }
    document.body.classList.toggle("overflow-hidden", this.sidebarOpen || this.membersOpen)
  }

  _updateMembers() {
    if (this.hasMemberSidebarTarget) {
      this.memberSidebarTarget.classList.toggle("mobile-members-open", this.membersOpen)
    }
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.toggle("hidden", !this.sidebarOpen && !this.membersOpen)
    }
    document.body.classList.toggle("overflow-hidden", this.sidebarOpen || this.membersOpen)
  }
}

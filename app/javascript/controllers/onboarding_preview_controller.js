import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    serverName: String,
    serverIcon: String,
    serverDescription: String,
    memberCount: Number
  }

  open() {
    const rules = this._getRules()
    const roles = this._getSelectedRoles()
    const channels = this._getSelectedChannels()

    // Build step list
    const steps = []
    if (rules.length) steps.push(this._buildRulesStep(rules))
    if (roles.length) steps.push(this._buildRolesStep(roles))
    steps.push(this._buildChannelsStep(channels))

    const stepLabels = []
    if (rules.length) stepLabels.push("Rules")
    if (roles.length) stepLabels.push("Roles")
    stepLabels.push("Channels")

    this._currentStep = 0
    this._steps = steps

    // Build overlay
    const overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-[100] flex items-center justify-center bg-black/80 backdrop-blur-sm"
    overlay.dataset.onboardingOverlay = true

    const iconHtml = this.serverIconValue
      ? `<img src="${this.serverIconValue}" class="w-16 h-16 rounded-2xl object-cover mx-auto mb-3">`
      : `<div class="w-16 h-16 rounded-2xl bg-gray-700 flex items-center justify-center text-2xl font-bold text-white mx-auto mb-3">${this._esc(this.serverNameValue[0]?.toUpperCase())}</div>`

    const descHtml = this.serverDescriptionValue
      ? `<p class="text-sm text-gray-400 mt-1 max-w-sm mx-auto">${this._esc(this.serverDescriptionValue)}</p>`
      : ""

    // Step indicators
    let indicatorsHtml = ""
    if (stepLabels.length > 1) {
      indicatorsHtml = `<div class="flex items-center justify-center gap-2 mb-6" data-indicators>`
      stepLabels.forEach((label, i) => {
        const dotCls = i === 0 ? "bg-accent text-white" : "bg-gray-700 text-gray-500"
        const labelCls = i === 0 ? "text-white" : "text-gray-500"
        indicatorsHtml += `
          <div class="flex items-center gap-2">
            <div class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold transition ${dotCls}" data-dot="${i}">${i + 1}</div>
            <span class="text-xs font-medium transition hidden sm:inline ${labelCls}" data-label="${i}">${label}</span>
          </div>`
        if (i < stepLabels.length - 1) indicatorsHtml += `<div class="flex-1 h-px bg-gray-700 max-w-8"></div>`
      })
      indicatorsHtml += `</div>`
    }

    overlay.innerHTML = `
      <div class="w-full max-w-lg mx-4 max-h-[90vh] overflow-y-auto">
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center gap-2">
            <svg class="w-4 h-4 text-accent-light" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>
            <span class="text-sm text-accent-light font-medium">Preview</span>
          </div>
          <button type="button" data-close class="flex items-center justify-center w-8 h-8 rounded-full border border-gray-600 text-gray-400 hover:text-white hover:border-gray-400 transition cursor-pointer">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
          </button>
        </div>

        <div class="text-center mb-8">
          ${iconHtml}
          <h1 class="text-2xl font-bold text-white">Welcome to ${this._esc(this.serverNameValue)}</h1>
          ${descHtml}
        </div>

        ${indicatorsHtml}

        <div data-steps-container>
          ${steps.map((html, i) => `<div data-step="${i}" class="${i > 0 ? 'hidden' : ''}">${html}</div>`).join("")}
        </div>

        <div class="text-center mt-4">
          <span class="text-xs text-gray-500">Skip for now</span>
        </div>
      </div>
    `

    // Wire up events
    overlay.querySelectorAll("[data-close]").forEach(btn => btn.addEventListener("click", () => overlay.remove()))
    overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove() })
    overlay.querySelectorAll("[data-nav-next]").forEach(btn => btn.addEventListener("click", () => this._goTo(overlay, this._currentStep + 1)))
    overlay.querySelectorAll("[data-nav-prev]").forEach(btn => btn.addEventListener("click", () => this._goTo(overlay, this._currentStep - 1)))

    // Rules checkbox
    const rulesCheck = overlay.querySelector("[data-rules-check]")
    const rulesNext = overlay.querySelector("[data-rules-next]")
    if (rulesCheck && rulesNext) {
      rulesCheck.addEventListener("change", () => { rulesNext.disabled = !rulesCheck.checked })
    }

    document.addEventListener("keydown", function handler(e) {
      if (e.key === "Escape") { document.removeEventListener("keydown", handler); overlay.remove() }
    })

    document.body.appendChild(overlay)
  }

  _goTo(overlay, step) {
    if (step < 0 || step >= this._steps.length) return
    overlay.querySelectorAll("[data-step]").forEach(el => el.classList.add("hidden"))
    overlay.querySelector(`[data-step="${step}"]`).classList.remove("hidden")

    overlay.querySelectorAll("[data-dot]").forEach(dot => {
      const i = parseInt(dot.dataset.dot)
      dot.classList.toggle("bg-accent", i <= step)
      dot.classList.toggle("text-white", i <= step)
      dot.classList.toggle("bg-gray-700", i > step)
      dot.classList.toggle("text-gray-500", i > step)
    })
    overlay.querySelectorAll("[data-label]").forEach(label => {
      const i = parseInt(label.dataset.label)
      label.classList.toggle("text-white", i === step)
      label.classList.toggle("text-gray-500", i !== step)
    })

    this._currentStep = step
  }

  _getRules() {
    const textarea = this.element.querySelector('textarea[name="server[onboarding_rules]"]')
    if (!textarea) return []
    return textarea.value.split("\n").map(r => r.trim()).filter(Boolean)
  }

  _getSelectedRoles() {
    const checks = this.element.querySelectorAll('input[name="server[self_assignable_role_ids][]"]:checked')
    return Array.from(checks).map(cb => {
      const label = cb.closest("label")
      const dot = label?.querySelector("span.rounded-full")
      const name = label?.querySelector("span.text-white")
      return { color: dot?.style.backgroundColor || "#fff", name: name?.textContent || "" }
    })
  }

  _getSelectedChannels() {
    const checks = this.element.querySelectorAll('input[name="server[default_channel_ids][]"]:checked')
    return Array.from(checks).map(cb => {
      const label = cb.closest("label")
      const name = label?.querySelector("span.text-white")
      return { name: name?.textContent || "" }
    })
  }

  _buildRulesStep(rules) {
    const isLast = !this._getSelectedRoles().length && false // channels always present
    const rulesHtml = rules.map((r, i) =>
      `<div class="flex items-start gap-3">
        <span class="text-sm font-bold text-accent mt-0.5 shrink-0 w-6 text-right">${i + 1}.</span>
        <span class="text-sm text-gray-300">${this._esc(r)}</span>
      </div>`
    ).join("")

    const nextBtn = `<button type="button" data-nav-next data-rules-next disabled
      class="bg-gray-700 hover:bg-gray-600 text-white text-sm font-medium px-5 py-2.5 rounded-lg transition cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed">Continue</button>`

    return `
      <div class="bg-gray-800 rounded-lg p-5 mb-6">
        <h2 class="text-sm font-semibold text-white uppercase tracking-wide mb-4">Server Rules</h2>
        <p class="text-xs text-gray-500 mb-4">Please read and agree to these rules before continuing.</p>
        <div class="space-y-3">${rulesHtml}</div>
      </div>
      <label class="flex items-center gap-3 cursor-pointer mb-6">
        <input type="checkbox" data-rules-check class="w-4 h-4 rounded bg-gray-900 border-gray-600 text-accent focus:ring-accent focus:ring-offset-0">
        <span class="text-sm text-gray-300">I have read and agree to the server rules</span>
      </label>
      <div class="flex items-center justify-end gap-3">${nextBtn}</div>`
  }

  _buildRolesStep(roles) {
    const hasRules = this._getRules().length > 0
    const rolesHtml = roles.map(r =>
      `<label class="flex items-center gap-3 p-3 rounded-lg border border-gray-700 hover:border-gray-600 cursor-pointer transition has-[:checked]:border-accent/50 has-[:checked]:bg-accent/5">
        <input type="checkbox" class="w-4 h-4 rounded bg-gray-900 border-gray-600 text-accent focus:ring-accent focus:ring-offset-0">
        <div class="flex items-center gap-2">
          <span class="w-3 h-3 rounded-full shrink-0" style="background-color: ${r.color}"></span>
          <span class="text-sm text-white">${this._esc(r.name)}</span>
        </div>
      </label>`
    ).join("")

    const backBtn = hasRules ? `<button type="button" data-nav-prev class="px-4 py-2 text-sm text-gray-400 hover:text-white transition cursor-pointer">Back</button>` : `<div></div>`

    return `
      <div class="bg-gray-800 rounded-lg p-5 mb-6">
        <h2 class="text-sm font-semibold text-white uppercase tracking-wide mb-2">Pick Your Roles</h2>
        <p class="text-xs text-gray-500 mb-4">Choose any roles that interest you. You can change these later in server settings.</p>
        <div class="space-y-2">${rolesHtml}</div>
      </div>
      <div class="flex items-center justify-between gap-3">
        ${backBtn}
        <button type="button" data-nav-next class="bg-gray-700 hover:bg-gray-600 text-white text-sm font-medium px-5 py-2.5 rounded-lg transition cursor-pointer">Continue</button>
      </div>`
  }

  _buildChannelsStep(channels) {
    const hasRules = this._getRules().length > 0
    const hasRoles = this._getSelectedRoles().length > 0
    const hasPrev = hasRules || hasRoles

    let channelsHtml
    if (channels.length === 0) {
      // Fall back to first 5 channel checkboxes from the form (even unchecked)
      const allLabels = this.element.querySelectorAll('input[name="server[default_channel_ids][]"]')
      const fallback = Array.from(allLabels).slice(0, 5).map(cb => {
        const name = cb.closest("label")?.querySelector("span.text-white")?.textContent || ""
        return { name }
      })
      channels = fallback
    }

    channelsHtml = channels.map(c =>
      `<div class="flex items-center gap-2.5 p-2.5 rounded-lg hover:bg-gray-700/50 transition">
        <svg class="w-5 h-5 text-gray-500 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 20l4-16m2 16l4-16M6 9h14M4 15h14"/></svg>
        <p class="text-sm text-white font-medium">${this._esc(c.name)}</p>
      </div>`
    ).join("")

    const backBtn = hasPrev ? `<button type="button" data-nav-prev class="px-4 py-2 text-sm text-gray-400 hover:text-white transition cursor-pointer">Back</button>` : `<div></div>`

    return `
      <div class="bg-gray-800 rounded-lg p-5 mb-6">
        <h2 class="text-sm font-semibold text-white uppercase tracking-wide mb-2">Channels to Get Started</h2>
        <p class="text-xs text-gray-500 mb-4">Here's where you can jump in. All channels are available in the sidebar.</p>
        <div class="space-y-1">${channelsHtml}</div>
      </div>
      <div class="flex items-center justify-between gap-3">
        ${backBtn}
        <button type="button" data-close class="bg-accent hover:bg-accent-dark text-white text-sm font-medium px-6 py-2.5 rounded-lg transition cursor-pointer">Enter Server</button>
      </div>`
  }

  _esc(str) {
    const el = document.createElement("span")
    el.textContent = str || ""
    return el.innerHTML
  }
}

import { Controller } from "@hotwired/stimulus"

// Multi-step server creation wizard.
// Steps: 1) Name & Icon  2) Server Type  3) Create
export default class extends Controller {
  static targets = [
    "step", "stepIndicator",
    "prevBtn", "nextBtn", "submitBtn",
    "serverTypeInput", "typeCard",
    "channelPreview"
  ]

  static values = { step: { type: Number, default: 1 }, totalSteps: { type: Number, default: 2 } }

  connect() {
    this.showStep()
  }

  next() {
    if (this.stepValue < this.totalStepsValue) {
      // Validate step 1: server name required
      if (this.stepValue === 1) {
        const nameInput = this.element.querySelector('input[name="server[name]"]')
        if (nameInput && !nameInput.value.trim()) {
          nameInput.focus()
          return
        }
      }
      this.stepValue++
      this.showStep()
    }
  }

  prev() {
    if (this.stepValue > 1) {
      this.stepValue--
      this.showStep()
    }
  }

  selectType(e) {
    const type = e.currentTarget.dataset.type
    this.serverTypeInputTarget.value = type

    this.typeCardTargets.forEach(card => {
      card.classList.toggle("ring-2", card.dataset.type === type)
      card.classList.toggle("ring-accent", card.dataset.type === type)
      card.classList.toggle("border-transparent", card.dataset.type === type)
      card.classList.toggle("border-gray-700/50", card.dataset.type !== type)
    })

    this.updateChannelPreview(type)
  }

  updateChannelPreview(type) {
    const templates = {
      community: [
        { cat: "Information", chs: ["# welcome (read-only)", "# rules (read-only)"] },
        { cat: "Text Channels", chs: ["# general", "# off-topic", "# media"] },
        { cat: "Announcements", chs: ["# announcements (mod-only)"] }
      ],
      friends_family: [
        { cat: "Text Channels", chs: ["# general", "# photos"] },
        { cat: "Voice", chs: ["voice hangout"] }
      ],
      gaming: [
        { cat: "Text Channels", chs: ["# general", "# lfg", "# screenshots", "# clips"] },
        { cat: "Voice", chs: ["voice lobby-1", "voice lobby-2"] }
      ],
      work_team: [
        { cat: "General", chs: ["# general", "# random"] },
        { cat: "Work", chs: ["# announcements (mod-only)", "# standup", "# projects"] }
      ],
      adult: [
        { cat: "Verification", chs: ["# rules (read-only)", "# verification-submit (post-only)"] },
        { cat: "Text Channels", chs: ["# general", "# media"] },
        { cat: "Voice", chs: ["voice voice"] }
      ]
    }

    const preview = templates[type]
    if (!preview || !this.hasChannelPreviewTarget) return

    let html = ''
    preview.forEach(cat => {
      html += `<div class="mb-2">
        <p class="text-[11px] text-gray-500 uppercase tracking-wide font-semibold mb-1">${cat.cat}</p>
        <div class="space-y-0.5 pl-2">`
      cat.chs.forEach(ch => {
        const isVoice = ch.startsWith("voice ")
        const name = isVoice ? ch.replace("voice ", "") : ch.replace("# ", "")
        const icon = isVoice
          ? '<svg class="w-3.5 h-3.5 text-gray-500 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6.253v11.494M8.464 8.464a5 5 0 000 7.072M19.07 4.93a10 10 0 010 14.142M4.93 4.93a10 10 0 000 14.142"/></svg>'
          : '<svg class="w-3.5 h-3.5 text-gray-500 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 20l4-16m2 16l4-16M6 9h14M4 15h14"/></svg>'
        html += `<div class="flex items-center gap-1.5 text-sm text-gray-400 py-0.5">
          ${icon}
          <span>${name}</span>
        </div>`
      })
      html += '</div></div>'
    })

    this.channelPreviewTarget.innerHTML = html
  }

  showStep() {
    this.stepTargets.forEach((el, i) => {
      el.classList.toggle("hidden", i + 1 !== this.stepValue)
    })

    if (this.hasStepIndicatorTarget) {
      this.stepIndicatorTargets.forEach((el, i) => {
        el.classList.toggle("text-accent", i + 1 === this.stepValue)
        el.classList.toggle("text-gray-600", i + 1 !== this.stepValue)
      })
    }

    if (this.hasPrevBtnTarget) {
      this.prevBtnTarget.classList.toggle("hidden", this.stepValue === 1)
    }
    if (this.hasNextBtnTarget) {
      this.nextBtnTarget.classList.toggle("hidden", this.stepValue === this.totalStepsValue)
    }
    if (this.hasSubmitBtnTarget) {
      this.submitBtnTarget.classList.toggle("hidden", this.stepValue !== this.totalStepsValue)
    }
  }
}

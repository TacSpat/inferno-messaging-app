import { Controller } from "@hotwired/stimulus"

// Manages the keyword filter UI: rule counting, live test box, and preset toggles.
export default class extends Controller {
  static targets = ["textarea", "testInput", "testResult", "ruleCount",
                     "blockLinks", "blockPhoneNumbers", "blockAllCaps", "blockSpamChars"]

  connect() {
    this.updateRuleCount()
  }

  updateRuleCount() {
    if (!this.hasTextareaTarget || !this.hasRuleCountTarget) return
    const count = this.activeRules().length
    this.ruleCountTarget.textContent = `${count} active rule${count === 1 ? "" : "s"}`
  }

  testMessage() {
    if (!this.hasTestInputTarget || !this.hasTestResultTarget) return
    const message = this.testInputTarget.value
    if (!message.trim()) {
      this.testResultTarget.innerHTML = '<span class="text-gray-500">Type a sample message above</span>'
      return
    }

    // Check presets first
    const presetMatch = this.checkPresets(message)
    if (presetMatch) {
      this.testResultTarget.innerHTML = `<span class="text-danger-light">Blocked by: ${this.escapeHtml(presetMatch)}</span>`
      return
    }

    // Check keyword rules
    const rules = this.activeRules()
    const matchedRule = this.findMatchingRule(message, rules)
    if (matchedRule) {
      this.testResultTarget.innerHTML = `<span class="text-danger-light">Blocked by: ${this.escapeHtml(matchedRule)}</span>`
    } else {
      this.testResultTarget.innerHTML = '<span class="text-green-400">OK — no rules matched</span>'
    }
  }

  activeRules() {
    if (!this.hasTextareaTarget) return []
    return this.textareaTarget.value
      .split("\n")
      .map(line => line.trim())
      .filter(line => line.length > 0)
  }

  findMatchingRule(message, rules) {
    const lower = message.toLowerCase()
    for (const rule of rules) {
      const rLower = rule.toLowerCase()
      if (rLower.endsWith("*") && !rLower.startsWith("*")) {
        // Starts-with wildcard: "hate*"
        const prefix = rLower.slice(0, -1)
        const regex = new RegExp(`\\b${this.escapeRegex(prefix)}\\w*`, "i")
        if (regex.test(message)) return rule
      } else if (rLower.startsWith("*") && !rLower.endsWith("*")) {
        // Ends-with wildcard: "*phobic"
        const suffix = rLower.slice(1)
        const regex = new RegExp(`\\w*${this.escapeRegex(suffix)}\\b`, "i")
        if (regex.test(message)) return rule
      } else {
        // Plain word/phrase
        if (lower.includes(rLower)) return rule
      }
    }
    return null
  }

  checkPresets(message) {
    // Block external links
    if (this.hasBlockLinksTarget && this.blockLinksTarget.checked) {
      if (this.hasUnsafeLinks(message)) return "Block external links"
    }
    // Block phone numbers
    if (this.hasBlockPhoneNumbersTarget && this.blockPhoneNumbersTarget.checked) {
      if (/(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}/.test(message)) return "Block phone numbers"
    }
    // Block ALL CAPS
    if (this.hasBlockAllCapsTarget && this.blockAllCapsTarget.checked) {
      if (message.length >= 20) {
        const letters = message.replace(/[^a-zA-Z]/g, "")
        if (letters.length > 0) {
          const upperRatio = letters.replace(/[^A-Z]/g, "").length / letters.length
          if (upperRatio > 0.8) return "Block ALL CAPS messages"
        }
      }
    }
    // Block repeated spam chars
    if (this.hasBlockSpamCharsTarget && this.blockSpamCharsTarget.checked) {
      if (/(.)\1{9,}/.test(message)) return "Block repeated spam characters"
    }
    return null
  }

  hasUnsafeLinks(message) {
    const urls = message.match(/https?:\/\/[^\s<>]+/gi)
    if (!urls) return false

    const safePatterns = [
      /\.(?:png|jpe?g|gif|webp|svg)(?:\?|$)/i,
      /\.(?:mp4|webm|mov|ogv)(?:\?|$)/i,
      /tenor\.com\/view\//i,
      /(?:youtube\.com\/watch|youtu\.be\/)/i,
      /(?:instagram\.com|kkinstagram\.com)\/(?:reel|p)\//i,
      /(?:tiktok\.com|vm\.tiktok\.com)\//i,
      /\/inferno\/invite\//i,
      /\/inferno\/server\//i,
      /\/rails\/active_storage\//i,
      /(?:blossom\.primal\.net|cdn\.satellite\.earth)\/[0-9a-f]{64}/i,
      /(?:discord\.com|discordapp\.com)\/channels\//i,
      /reddit\.com\/r\//i,
    ]

    // Also treat same-origin as safe (check in test context: just skip known app paths)
    const unsafeUrls = urls.filter(url => {
      return !safePatterns.some(pattern => pattern.test(url))
    })

    return unsafeUrls.length > 0
  }

  escapeRegex(str) {
    return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }
}

import { Controller } from "@hotwired/stimulus"

const DESCRIPTIONS = {
  none: "No automatic pruning. Messages and attachments are kept indefinitely.",
  time_based: "Messages older than the retention period are automatically deleted. Set to 0 to keep messages forever.",
  storage_based:
    "Runs in three steps: (1) attachments older than retention are purged first, " +
    "(2) messages older than retention are deleted, " +
    "(3) if the database still exceeds the size limit, the oldest messages are removed in batches until it\u2019s back under the cap. " +
    "Set a max database size to activate the size limit, or leave at 0 for no cap."
}

export default class extends Controller {
  static targets = ["retention", "attachmentRetention", "scope", "options", "description"]

  connect() {
    this.toggle()
  }

  toggle() {
    const strategy = this.element.querySelector("select[name='pruning_strategy']").value
    const disabled = strategy === "none"
    const storageMode = strategy === "storage_based"

    this.retentionTarget.classList.toggle("hidden", disabled)
    this.attachmentRetentionTarget.classList.toggle("hidden", !storageMode)
    this.scopeTarget.classList.toggle("hidden", disabled)
    this.optionsTarget.classList.toggle("hidden", disabled)

    if (this.hasDescriptionTarget) {
      this.descriptionTarget.textContent = DESCRIPTIONS[strategy] || ""
      this.descriptionTarget.classList.toggle("hidden", !DESCRIPTIONS[strategy])
    }
  }
}

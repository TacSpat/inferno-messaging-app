import { Controller } from "@hotwired/stimulus"

const EMOJI_CATEGORIES = {
  "Smileys": ["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😗","😚","😙","🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🫡","🤐","🤨","😐","😑","😶","🫥","😏","😒","🙄","😬","🤥","😌","😔","😪","🤤","😴","😷","🤒","🤕","🤢","🤮","🥵","🥶","🥴","😵","🤯","🤠","🥳","🥸","😎","🤓","🧐"],
  "Gestures": ["👍","👎","👊","✊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","✌️","🤞","🤟","🤘","👌","🤌","🤏","👈","👉","👆","👇","☝️","✋","🤚","🖐️","🖖","👋","🤙","💪","🦾","🖕"],
  "Hearts": ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❤️‍🔥","❤️‍🩹","💕","💞","💓","💗","💖","💘","💝","💟"],
  "Objects": ["🔥","⭐","🌟","✨","💫","🎉","🎊","🎈","🎁","🏆","🥇","🎮","🎯","🎲","🔮","💎","💰","💡","📌","📎","✏️","📝","💻","⌨️","🖥️","📱","☎️","📷","🎵","🎶","🎸","🎹"]
}

export default class extends Controller {
  static targets = ["panel", "input"]

  toggle() {
    this.panelTarget.classList.toggle("hidden")
  }

  close() {
    this.panelTarget.classList.add("hidden")
  }

  select(event) {
    const emoji = event.currentTarget.dataset.emoji
    const input = this.inputTarget
    const start = input.selectionStart
    const end = input.selectionEnd
    input.value = input.value.substring(0, start) + emoji + input.value.substring(end)
    input.selectionStart = input.selectionEnd = start + emoji.length
    input.focus()
    this.close()
  }

  // Close when clicking outside
  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  connect() {
    this.boundClose = this.closeOnClickOutside.bind(this)
    document.addEventListener("click", this.boundClose)
  }

  disconnect() {
    document.removeEventListener("click", this.boundClose)
  }
}

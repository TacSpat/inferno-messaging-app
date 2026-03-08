import { Controller } from "@hotwired/stimulus"
import {
  Room,
  RoomEvent,
  Track
} from "livekit-client"

/**
 * Call controller — manages DM/group call LiveKit connections.
 * Uses voice-channel style participant grid with voice-card styling.
 */
export default class extends Controller {
  static targets = [
    "callBtn", "callPanel", "messagesWrapper", "joinBanner",
    "ringingState", "ringingName",
    "incomingState", "callerName", "callerAvatar", "callerAvatarFallback",
    "activeState", "grid", "timer",
    "muteBtn", "muteIcon"
  ]
  static values = {
    conversationId: String,
    livekitConfigured: { type: Boolean, default: false },
    activeCallId: { type: String, default: "" }
  }

  connect() {
    this.room = null
    this._muted = false
    this._callId = null
    this._timerInterval = null
    this._callStartTime = null
    this._audioElements = new Map()
    this._ringTimeout = null
    this._ringtoneAudio = null
    this._dialingAudio = null

    if (this.activeCallIdValue) {
      this._activeCallId = this.activeCallIdValue
    }

    this._onCableMessage = this._handleCableMessage.bind(this)
    document.addEventListener("cable:conversation_message", this._onCableMessage)
  }

  disconnect() {
    document.removeEventListener("cable:conversation_message", this._onCableMessage)
    this._disconnectRoom()
    this._stopTimer()
    this._stopRingtone()
    this._stopDialing()
    this._clearRingTimeout()
  }

  // ─── Actions ─────────────────────────────────

  async startCall() {
    if (!this.livekitConfiguredValue) {
      alert("Voice calling requires LiveKit configuration in settings")
      return
    }
    if (this.room) return

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/conversations/${this.conversationIdValue}/calls`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (!res.ok) {
        const err = await res.json().catch(() => ({}))
        alert(err.error || "Failed to start call")
        return
      }
      const data = await res.json()
      this._callId = data.call_id
      this._pendingToken = data.token
      this._pendingUrl = data.livekit_url
      this._showCallPanel("ringing", { calleeName: data.callee_name })
      this._playDialing()
      this._ringTimeout = setTimeout(() => this.cancelCall(), 30000)
    } catch (err) {
      console.error("[Call] Failed to start:", err)
    }
  }

  async cancelCall() {
    this._stopDialing()
    this._clearRingTimeout()
    if (this._callId && !this.room) {
      const csrf = document.querySelector("meta[name=csrf-token]")?.content
      await fetch(`/conversations/${this.conversationIdValue}/calls/${this._callId}/hangup`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf }
      }).catch(() => {})
    }
    this._hideCallPanel()
    this._callId = null
    this._pendingToken = null
    this._pendingUrl = null
  }

  async acceptCall() {
    if (!this._incomingCallId) return
    this._stopRingtone()
    this._clearRingTimeout()
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/conversations/${this.conversationIdValue}/calls/${this._incomingCallId}/accept`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (!res.ok) {
        const err = await res.json().catch(() => ({}))
        alert(err.error || "Failed to accept call")
        return
      }
      const data = await res.json()
      this._callId = data.call_id
      await this._connectToRoom(data.livekit_url, data.token)
      this._showCallPanel("active")
    } catch (err) {
      console.error("[Call] Failed to accept:", err)
    }
  }

  async declineCall() {
    if (!this._incomingCallId) return
    this._stopRingtone()
    this._clearRingTimeout()
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch(`/conversations/${this.conversationIdValue}/calls/${this._incomingCallId}/decline`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrf }
    }).catch(() => {})
    this._hideCallPanel()
    this._incomingCallId = null
  }

  async joinCall() {
    const banner = this.hasJoinBannerTarget ? this.joinBannerTarget : null
    const callId = banner?.dataset.callId || this._activeCallId || this._incomingCallId
    if (!callId) return
    this._stopRingtone()
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/conversations/${this.conversationIdValue}/calls/${callId}/join`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (!res.ok) return
      const data = await res.json()
      this._callId = data.call_id
      await this._connectToRoom(data.livekit_url, data.token)
      this._showCallPanel("active")
    } catch (err) {
      console.error("[Call] Failed to join:", err)
    }
  }

  async hangup() {
    if (!this._callId) return
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    await fetch(`/conversations/${this.conversationIdValue}/calls/${this._callId}/hangup`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrf }
    }).catch(() => {})
    this._disconnectRoom()
    this._hideCallPanel()
    this._callId = null
  }

  toggleMute() {
    if (!this.room) return
    this._muted = !this._muted
    this.room.localParticipant.setMicrophoneEnabled(!this._muted)
    this._updateMuteUI()
    this._updateLocalMuteIndicator()
  }

  // ─── LiveKit Room ─────────────────────────────────

  async _connectToRoom(url, token) {
    this.room = new Room({ adaptiveStream: true, dynacast: true })

    this.room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
      if (track.kind === Track.Kind.Audio) {
        const el = track.attach()
        el.id = `call-audio-${participant.identity}`
        document.body.appendChild(el)
        this._audioElements.set(participant.identity, el)
      }
    })

    this.room.on(RoomEvent.TrackUnsubscribed, (track, pub, participant) => {
      track.detach().forEach(el => el.remove())
      this._audioElements.delete(participant.identity)
    })

    this.room.on(RoomEvent.ParticipantConnected, (participant) => {
      this._addParticipantCard(participant)
    })

    this.room.on(RoomEvent.ParticipantDisconnected, (participant) => {
      this._removeParticipantCard(participant)
      this._audioElements.delete(participant.identity)
    })

    this.room.on(RoomEvent.ActiveSpeakersChanged, (speakers) => {
      this._handleActiveSpeakers(speakers)
    })

    this.room.on(RoomEvent.Disconnected, () => {
      this._cleanupAudio()
      this._hideCallPanel()
      this._stopTimer()
    })

    await this.room.connect(url, token)
    await this.room.localParticipant.setMicrophoneEnabled(true)

    // Add local participant card
    this._addLocalParticipantCard()

    // Add existing remote participants
    for (const participant of this.room.remoteParticipants.values()) {
      this._addParticipantCard(participant)
    }

    this._startTimer()
  }

  _disconnectRoom() {
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    this._cleanupAudio()
    this._stopTimer()
  }

  _cleanupAudio() {
    this._audioElements.forEach(el => el.remove())
    this._audioElements.clear()
  }

  // ─── Participant Cards ────────────────────────────

  _addLocalParticipantCard() {
    const lp = this.room.localParticipant
    let meta = {}
    try { meta = JSON.parse(lp.metadata || "{}") } catch (_) {}
    const username = lp.name || lp.identity.slice(0, 8)
    const avatarUrl = meta.avatar_url || ""
    const profileColor = meta.profile_color || "#1e1c1b"
    this._createCard(lp.identity, username, avatarUrl, profileColor)
  }

  _addParticipantCard(participant) {
    let meta = {}
    try { meta = JSON.parse(participant.metadata || "{}") } catch (_) {}
    const username = participant.name || participant.identity.slice(0, 8)
    const avatarUrl = meta.avatar_url || ""
    const profileColor = meta.profile_color || "#1e1c1b"
    this._createCard(participant.identity, username, avatarUrl, profileColor)
  }

  _createCard(identity, username, avatarUrl, profileColor) {
    if (!this.hasGridTarget) return
    if (this.gridTarget.querySelector(`[data-voice-participant-id="${identity}"]`)) return

    const tpl = document.getElementById("tpl-voice-card")
    if (!tpl) return

    const card = tpl.content.cloneNode(true).querySelector(".voice-card")
    card.dataset.voiceParticipantId = identity
    card.style.setProperty("--card-color", profileColor)

    const avatarSlot = card.querySelector('[data-slot="avatar"]')
    if (avatarUrl) {
      const img = document.createElement("img")
      img.src = avatarUrl
      img.className = "voice-avatar"
      avatarSlot.appendChild(img)
    } else {
      const fallback = document.createElement("div")
      fallback.className = "voice-avatar-fallback"
      fallback.style.backgroundColor = `color-mix(in srgb, ${profileColor}, white 20%)`
      fallback.textContent = (username[0] || "?").toUpperCase()
      avatarSlot.appendChild(fallback)
    }

    card.querySelector('[data-slot="username"]').textContent = username
    this.gridTarget.appendChild(card)
  }

  _removeParticipantCard(participant) {
    if (!this.hasGridTarget) return
    const card = this.gridTarget.querySelector(`[data-voice-participant-id="${participant.identity}"]`)
    card?.remove()
  }

  _handleActiveSpeakers(speakers) {
    if (!this.hasGridTarget) return
    const speakerIds = new Set(speakers.map(s => s.identity))
    this.gridTarget.querySelectorAll(".voice-card").forEach(card => {
      const id = card.dataset.voiceParticipantId
      card.classList.toggle("voice-speaking", speakerIds.has(id))
    })
  }

  _updateLocalMuteIndicator() {
    if (!this.hasGridTarget || !this.room) return
    const identity = this.room.localParticipant.identity
    const card = this.gridTarget.querySelector(`[data-voice-participant-id="${identity}"]`)
    if (!card) return

    let statusIcons = card.querySelector(".voice-status-icons")
    if (this._muted) {
      if (!statusIcons) {
        statusIcons = document.createElement("div")
        statusIcons.className = "voice-status-icons"
        card.querySelector(".voice-card-inner").appendChild(statusIcons)
      }
      statusIcons.innerHTML = `<div class="voice-status-badge"><svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2.5" stroke-linecap="round"/></svg></div>`
    } else {
      statusIcons?.remove()
    }
  }

  // ─── UI State Management ─────────────────────────

  _showCallPanel(state, opts = {}) {
    if (this.hasCallPanelTarget) this.callPanelTarget.classList.remove("hidden")
    if (this.hasMessagesWrapperTarget) this.messagesWrapperTarget.classList.add("hidden")
    if (this.hasJoinBannerTarget) this.joinBannerTarget.classList.add("hidden")
    if (this.hasCallBtnTarget) this.callBtnTarget.classList.add("hidden")

    // Hide all sub-states
    if (this.hasRingingStateTarget) this.ringingStateTarget.classList.add("hidden")
    if (this.hasIncomingStateTarget) this.incomingStateTarget.classList.add("hidden")
    if (this.hasActiveStateTarget) this.activeStateTarget.classList.add("hidden")

    switch (state) {
      case "ringing":
        if (this.hasRingingStateTarget) {
          this.ringingStateTarget.classList.remove("hidden")
          if (this.hasRingingNameTarget) {
            this.ringingNameTarget.textContent = opts.calleeName || "..."
          }
        }
        break
      case "incoming":
        if (this.hasIncomingStateTarget) {
          this.incomingStateTarget.classList.remove("hidden")
          if (this.hasCallerNameTarget) {
            this.callerNameTarget.textContent = opts.callerName || ""
          }
          if (this.hasCallerAvatarTarget && opts.callerAvatar) {
            this.callerAvatarTarget.src = opts.callerAvatar
            this.callerAvatarTarget.classList.remove("hidden")
            if (this.hasCallerAvatarFallbackTarget) {
              this.callerAvatarFallbackTarget.classList.add("hidden")
            }
          }
        }
        break
      case "active":
        if (this.hasActiveStateTarget) {
          this.activeStateTarget.classList.remove("hidden")
        }
        break
    }
  }

  _hideCallPanel() {
    if (this.hasCallPanelTarget) this.callPanelTarget.classList.add("hidden")
    if (this.hasMessagesWrapperTarget) this.messagesWrapperTarget.classList.remove("hidden")
    if (this.hasCallBtnTarget) this.callBtnTarget.classList.remove("hidden")
    if (this.hasGridTarget) this.gridTarget.innerHTML = ""
    this._incomingCallId = null
  }

  _updateMuteUI() {
    if (!this.hasMuteIconTarget) return
    if (this._muted) {
      this.muteIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/>'
      this.muteBtnTarget.classList.add("bg-red-500/20", "text-red-400")
      this.muteBtnTarget.classList.remove("bg-gray-700", "text-gray-300")
    } else {
      this.muteIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/>'
      this.muteBtnTarget.classList.remove("bg-red-500/20", "text-red-400")
      this.muteBtnTarget.classList.add("bg-gray-700", "text-gray-300")
    }
  }

  // ─── Timer ─────────────────────────────────

  _startTimer() {
    this._callStartTime = Date.now()
    this._timerInterval = setInterval(() => {
      if (!this.hasTimerTarget) return
      const elapsed = Math.floor((Date.now() - this._callStartTime) / 1000)
      const mins = Math.floor(elapsed / 60)
      const secs = (elapsed % 60).toString().padStart(2, "0")
      this.timerTarget.textContent = `${mins}:${secs}`
    }, 1000)
  }

  _stopTimer() {
    if (this._timerInterval) {
      clearInterval(this._timerInterval)
      this._timerInterval = null
    }
  }

  // ─── Ringtone / Dialing ──────────────────────────

  _playRingtone() {
    this._stopRingtone()
    this._ringtoneAudio = this._createToneLoop([440, 480], 1.0, 2.0)
  }

  _stopRingtone() {
    if (this._ringtoneAudio) {
      this._ringtoneAudio.stop()
      this._ringtoneAudio = null
    }
  }

  _playDialing() {
    this._stopDialing()
    this._dialingAudio = this._createToneLoop([440, 480], 2.0, 4.0)
  }

  _stopDialing() {
    if (this._dialingAudio) {
      this._dialingAudio.stop()
      this._dialingAudio = null
    }
  }

  _createToneLoop(frequencies, onDuration, cycleDuration) {
    const ctx = new (window.AudioContext || window.webkitAudioContext)()
    const gainNode = ctx.createGain()
    gainNode.gain.value = 0.15
    gainNode.connect(ctx.destination)

    const oscillators = frequencies.map(freq => {
      const osc = ctx.createOscillator()
      osc.type = "sine"
      osc.frequency.value = freq
      osc.connect(gainNode)
      osc.start()
      return osc
    })

    const scheduleCadence = () => {
      const now = ctx.currentTime
      gainNode.gain.setValueAtTime(0.15, now)
      gainNode.gain.setValueAtTime(0, now + onDuration)
    }
    scheduleCadence()
    const interval = setInterval(scheduleCadence, cycleDuration * 1000)

    return {
      stop() {
        clearInterval(interval)
        oscillators.forEach(o => { try { o.stop() } catch {} })
        try { ctx.close() } catch {}
      }
    }
  }

  _clearRingTimeout() {
    if (this._ringTimeout) {
      clearTimeout(this._ringTimeout)
      this._ringTimeout = null
    }
  }

  // ─── ActionCable Event Handling ─────────────────

  _handleCableMessage(e) {
    const data = e.detail
    if (!data) return

    switch (data.type) {
      case "incoming_call": {
        const currentUserId = document.body.dataset.currentUserId
        if (data.caller_id === currentUserId) return
        this._incomingCallId = data.call_id
        this._showCallPanel("incoming", {
          callerName: data.caller_name,
          callerAvatar: data.caller_avatar
        })
        this._playRingtone()
        this._ringTimeout = setTimeout(() => {
          this._stopRingtone()
          this._hideCallPanel()
          this._incomingCallId = null
        }, 30000)
        break
      }
      case "call_accepted":
        this._activeCallId = data.call_id
        if (this._callId === data.call_id && this._pendingToken && !this.room) {
          this._stopDialing()
          this._clearRingTimeout()
          this._connectToRoom(this._pendingUrl, this._pendingToken)
          this._showCallPanel("active")
          this._pendingToken = null
          this._pendingUrl = null
        }
        break
      case "call_declined":
        if (this._callId === data.call_id && !this.room) {
          this._stopDialing()
          this._clearRingTimeout()
          this._hideCallPanel()
          this._callId = null
          this._pendingToken = null
          this._pendingUrl = null
        }
        this._stopRingtone()
        this._hideCallPanel()
        break
      case "call_ended":
        this._stopRingtone()
        this._stopDialing()
        this._clearRingTimeout()
        if (data.active_count === 0) {
          if (this._callId === data.call_id) {
            this._disconnectRoom()
            this._hideCallPanel()
            this._callId = null
            this._pendingToken = null
            this._pendingUrl = null
          }
          this._hideCallPanel()
          this._activeCallId = null
        }
        break
      case "participant_joined":
        break
    }
  }
}

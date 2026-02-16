import { Controller } from "@hotwired/stimulus"

// This controller lives on the voice-controls-bar in the sidebar layout.
// The "Join Voice" button inside the turbo frame communicates via window events.
export default class extends Controller {
  static targets = ["statusText", "channelName", "muteBtn", "deafenBtn", "muteIcon", "deafenIcon"]
  static values = {
    serverId: String,
    connected: { type: Boolean, default: false },
    channelId: { type: String, default: "" },
    channelName: { type: String, default: "" },
    selfMute: { type: Boolean, default: false },
    selfDeaf: { type: Boolean, default: false }
  }

  connect() {
    this.room = null
    this.muted = false
    this.deafened = false
    this.channelId = null
    this.channelDisplayName = null

    // Listen for join requests from the turbo frame
    this._onJoinRequest = (e) => this.handleJoinRequest(e.detail)
    window.addEventListener("voice:join", this._onJoinRequest)

    // Listen for disconnect requests (e.g. from page navigation)
    this._onDisconnectRequest = () => this.disconnectVoice()
    window.addEventListener("voice:disconnect", this._onDisconnectRequest)

    // Listen for moderation events
    this._onForceDisconnect = () => this.handleForceDisconnect()
    window.addEventListener("voice:force-disconnect", this._onForceDisconnect)

    this._onForceMove = (e) => this.handleForceMove(e.detail)
    window.addEventListener("voice:force-move", this._onForceMove)

    this._onServerMute = (e) => this.handleServerMute(e.detail)
    window.addEventListener("voice:server-mute", this._onServerMute)

    this._onServerDeafen = (e) => this.handleServerDeafen(e.detail)
    window.addEventListener("voice:server-deafen", this._onServerDeafen)

    this.serverMuted = false
    this.serverDeafened = false

    // Restore state from server-rendered values (page load while already in a call)
    if (this.connectedValue) {
      this.channelId = this.channelIdValue
      this.channelDisplayName = this.channelNameValue
      this.muted = this.selfMuteValue
      this.deafened = this.selfDeafValue

      if (this.hasChannelNameTarget) {
        this.channelNameTarget.textContent = this.channelDisplayName
      }

      this.updateMuteUI()
      this.updateDeafenUI()

      // Reconnect to LiveKit so audio actually works
      this.reconnectToLiveKit()
    }
  }

  disconnect() {
    window.removeEventListener("voice:join", this._onJoinRequest)
    window.removeEventListener("voice:disconnect", this._onDisconnectRequest)
    window.removeEventListener("voice:force-disconnect", this._onForceDisconnect)
    window.removeEventListener("voice:force-move", this._onForceMove)
    window.removeEventListener("voice:server-mute", this._onServerMute)
    window.removeEventListener("voice:server-deafen", this._onServerDeafen)
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
  }

  async handleJoinRequest({ channelId, serverId }) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    try {
      // Acquire mic permission NOW while we still have user gesture context.
      // This must happen before any async network calls.
      let micStream = null
      if (!this.muted) {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          console.warn("[Voice] navigator.mediaDevices unavailable — requires HTTPS or localhost")
          this.showToast("Microphone requires a secure connection (HTTPS or localhost)", true)
          this.muted = true
          this.updateMuteUI()
        } else {
          try {
            micStream = await navigator.mediaDevices.getUserMedia({ audio: true })
            console.log("[Voice] Microphone permission granted")
          } catch (micErr) {
            console.warn("[Voice] Microphone denied:", micErr.name, micErr.message)
            this.muted = true
            this.updateMuteUI()
            if (micErr.name === "NotAllowedError") {
              this.showToast("Microphone blocked — check browser permissions", true)
            } else {
              this.showToast("Microphone unavailable, joining as listener", true)
            }
          }
        }
      }

      const res = await fetch(`/servers/${serverId}/channels/${channelId}/join_voice`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })

      if (!res.ok) {
        const data = await res.json()
        this.showToast(data.error || "Failed to join voice channel", true)
        if (micStream) micStream.getTracks().forEach(t => t.stop())
        return
      }

      const data = await res.json()

      // Store channel info
      this.channelId = channelId
      this.channelDisplayName = document.querySelector(`a[data-channel-id="${channelId}"] span.truncate`)?.textContent || "Voice"

      // Stop the pre-acquired stream — LiveKit will open its own
      if (micStream) micStream.getTracks().forEach(t => t.stop())

      // Connect to LiveKit
      const connected = await this.connectToLiveKit(data.url, data.token)
      if (!connected) {
        this.showToast("Voice connection failed", true)
        await this._leaveServerVoiceState()
        this.channelId = null
        return
      }

      // Show voice controls bar
      this.showControlsBar()

      // Update sidebar with participant
      this.addSidebarParticipant(channelId, data)

      // Update main voice view
      this.updateMainViewConnected(data)

    } catch (err) {
      console.error("Failed to join voice:", err)
      this.showToast("Failed to join voice channel", true)
    }
  }

  async connectToLiveKit(url, token) {
    try {
      // Always tear down any existing room first to prevent orphaned connections
      if (this.room) {
        try { this.room.disconnect() } catch {}
        this.room = null
      }
      document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())

      const { Room, RoomEvent, Track } = await import("livekit-client")

      this.room = new Room({
        audioCaptureDefaults: {
          autoGainControl: true,
          echoCancellation: true,
          noiseSuppression: true
        }
      })

      // Attach remote audio tracks so we can hear other participants
      this.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
        console.log(`[Voice] Track subscribed: ${track.kind} from ${participant.identity}`)
        if (track.kind === Track.Kind.Audio) {
          // Remove any stale element for this participant
          const stale = document.getElementById(`voice-audio-${participant.identity}`)
          if (stale) stale.remove()

          const el = track.attach()
          el.id = `voice-audio-${participant.identity}`
          document.body.appendChild(el)

          // Ensure audio plays — startAudio unlocks the AudioContext,
          // then explicitly play the element as a fallback
          this.room.startAudio().then(() => {
            el.play().catch(() => {})
          })
        }
      })

      this.room.on(RoomEvent.TrackUnsubscribed, (track, publication, participant) => {
        console.log(`[Voice] Track unsubscribed: ${track.kind} from ${participant.identity}`)
        track.detach().forEach(el => el.remove())
        const leftover = document.getElementById(`voice-audio-${participant.identity}`)
        if (leftover) leftover.remove()
      })

      this.room.on(RoomEvent.Disconnected, () => {
        console.log("[Voice] Disconnected from room")
        document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())
        this.handleDisconnected()
      })

      this.room.on(RoomEvent.Reconnecting, () => {
        console.log("[Voice] Reconnecting...")
        if (this.hasStatusTextTarget) {
          this.statusTextTarget.textContent = "Reconnecting..."
          this.statusTextTarget.classList.remove("text-green-500")
          this.statusTextTarget.classList.add("text-yellow-500")
        }
      })

      this.room.on(RoomEvent.Reconnected, () => {
        console.log("[Voice] Reconnected")
        if (this.hasStatusTextTarget) {
          this.statusTextTarget.textContent = "Voice Connected"
          this.statusTextTarget.classList.remove("text-yellow-500")
          this.statusTextTarget.classList.add("text-green-500")
        }
      })

      this.room.on(RoomEvent.ParticipantConnected, (participant) => {
        console.log(`[Voice] Participant connected: ${participant.identity}`)
      })

      this.room.on(RoomEvent.ParticipantDisconnected, (participant) => {
        console.log(`[Voice] Participant disconnected: ${participant.identity}`)
      })

      console.log(`[Voice] Connecting to ${url}...`)
      await this.room.connect(url, token)
      console.log(`[Voice] Connected! Room: ${this.room.name}, Participants: ${this.room.remoteParticipants.size}`)

      // Try to unlock audio immediately (works if called from user gesture)
      try {
        await this.room.startAudio()
        console.log("[Voice] Audio started (autoplay unlocked)")
      } catch {
        console.log("[Voice] Audio autoplay blocked — will unlock on first interaction")
        this._setupAudioUnlock()
      }

      // Enable microphone — non-fatal, user can still listen if mic is denied
      if (!this.muted) {
        try {
          await this.room.localParticipant.setMicrophoneEnabled(true)
          console.log("[Voice] Microphone enabled")
        } catch (micErr) {
          console.warn("[Voice] Microphone access denied:", micErr.message)
          this.muted = true
          this.updateMuteUI()
        }
      } else {
        console.log("[Voice] Microphone stays muted")
      }

      // Attach any already-subscribed remote audio tracks
      this._attachExistingTracks()

      return true
    } catch (err) {
      console.error("[Voice] LiveKit connection failed:", err)
      return false
    }
  }

  async _leaveServerVoiceState() {
    if (!this.channelId) return
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      await fetch(`/servers/${this.serverIdValue}/channels/${this.channelId}/leave_voice`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf }
      })
    } catch (err) {
      console.error("[Voice] Failed to leave voice state:", err)
    }
  }

  _cleanUpAfterFailedReconnect() {
    // Disconnect any lingering room connection
    if (this.room) {
      try { this.room.disconnect() } catch {}
      this.room = null
    }
    document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())

    // Leave the server-side voice state and reset UI
    this._leaveServerVoiceState()
    const currentUserId = document.body.dataset.currentUserId
    if (this.channelId && currentUserId) {
      this.removeSidebarParticipant(this.channelId, currentUserId)
    }
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this.channelId = null
  }

  _setupAudioUnlock() {
    // On page refresh there's no user gesture, so audio is blocked.
    // Wait for ANY click/keypress on the page, then unlock.
    const unlock = async () => {
      if (!this.room) return
      try {
        await this.room.startAudio()
        console.log("[Voice] Audio unlocked via user interaction")
        // Also replay any attached audio elements
        document.querySelectorAll('[id^="voice-audio-"]').forEach(el => {
          el.play().catch(() => {})
        })
      } catch (e) {
        console.warn("[Voice] Audio unlock failed:", e)
      }
      document.removeEventListener("click", unlock, true)
      document.removeEventListener("keydown", unlock, true)
    }
    document.addEventListener("click", unlock, true)
    document.addEventListener("keydown", unlock, true)
  }

  _attachExistingTracks() {
    if (!this.room) return
    this.room.remoteParticipants.forEach((participant) => {
      participant.audioTrackPublications.forEach((pub) => {
        if (pub.track && pub.isSubscribed) {
          console.log(`[Voice] Attaching existing audio track from ${participant.identity}`)
          const existing = document.getElementById(`voice-audio-${participant.identity}`)
          if (existing) existing.remove()

          const el = pub.track.attach()
          el.id = `voice-audio-${participant.identity}`
          document.body.appendChild(el)
          el.play().catch(() => {})
        }
      })
    })
  }

  async reconnectToLiveKit() {
    // Fetch a fresh token without creating a new voice state
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/channels/${this.channelId}/refresh_voice_token`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })

      if (!res.ok) {
        console.warn("[Voice] Failed to refresh token, cleaning up")
        this._cleanUpAfterFailedReconnect()
        return
      }

      const data = await res.json()
      const connected = await this.connectToLiveKit(data.url, data.token)
      if (!connected) {
        console.warn("[Voice] LiveKit connection failed on reconnect, cleaning up")
        this._cleanUpAfterFailedReconnect()
      }
    } catch (err) {
      console.error("[Voice] Failed to reconnect:", err)
      this._cleanUpAfterFailedReconnect()
    }
  }

  async disconnectVoice() {
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    // Clean up remote audio elements
    document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())

    if (this.channelId) {
      const serverId = this.serverIdValue
      const csrf = document.querySelector("meta[name=csrf-token]")?.content

      try {
        await fetch(`/servers/${serverId}/channels/${this.channelId}/leave_voice`, {
          method: "DELETE",
          headers: { "X-CSRF-Token": csrf }
        })
      } catch (err) {
        console.error("Failed to leave voice:", err)
      }
    }

    const currentUserId = document.body.dataset.currentUserId
    if (this.channelId && currentUserId) {
      this.removeSidebarParticipant(this.channelId, currentUserId)
    }
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this.channelId = null
  }

  // Stimulus action for the disconnect button in the controls bar
  leave() {
    this.disconnectVoice()
  }

  async toggleMute() {
    this.muted = !this.muted

    try {
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(!this.muted)
      }
    } catch (err) {
      console.warn("[Voice] setMicrophoneEnabled failed:", err.message)
    }

    this.updateMuteUI()

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      await fetch("/voice_states/self_mute", {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
    } catch (err) {
      console.error("Failed to update mute state:", err)
    }
  }

  async toggleDeafen() {
    this.deafened = !this.deafened
    if (this.deafened) this.muted = true

    try {
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(!this.muted)
      }
    } catch (err) {
      console.warn("[Voice] setMicrophoneEnabled failed:", err.message)
    }

    // Mute/unmute all remote audio tracks locally
    if (this.room) {
      this.room.remoteParticipants.forEach((participant) => {
        participant.audioTrackPublications.forEach((pub) => {
          try {
            if (pub.track) {
              const mst = pub.track.mediaStreamTrack
              if (mst) mst.enabled = !this.deafened
            }
          } catch (err) {
            console.warn("[Voice] Failed to toggle remote track:", err.message)
          }
        })
      })
      // Also mute/unmute attached audio elements as fallback
      document.querySelectorAll('[id^="voice-audio-"]').forEach(el => {
        el.muted = this.deafened
      })
    }

    this.updateMuteUI()
    this.updateDeafenUI()

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch("/voice_states/self_deafen", {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
      if (res.ok) {
        const data = await res.json()
        this.muted = data.self_mute
        this.deafened = data.self_deaf
        this.updateMuteUI()
        this.updateDeafenUI()
      }
    } catch (err) {
      console.error("Failed to update deafen state:", err)
    }
  }

  handleDisconnected() {
    this.room = null
    const currentUserId = document.body.dataset.currentUserId
    if (this.channelId && currentUserId) {
      this.removeSidebarParticipant(this.channelId, currentUserId)
    }
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this.channelId = null
  }

  showControlsBar() {
    this.element.classList.remove("hidden")
    this.connectedValue = true
    this.channelIdValue = this.channelId || ""
    this.channelNameValue = this.channelDisplayName || ""
    if (this.hasChannelNameTarget) {
      this.channelNameTarget.textContent = this.channelDisplayName || "Voice Channel"
    }
    if (this.hasStatusTextTarget) {
      this.statusTextTarget.textContent = "Voice Connected"
      this.statusTextTarget.classList.add("text-green-500")
      this.statusTextTarget.classList.remove("text-yellow-500")
    }
  }

  hideControlsBar() {
    this.element.classList.add("hidden")
    this.connectedValue = false
    this.channelIdValue = ""
    this.channelNameValue = ""
  }

  addSidebarParticipant(channelId, data) {
    const channelLink = document.querySelector(`a[data-channel-id="${channelId}"]`)
    if (!channelLink) return

    let container = document.querySelector(`[data-voice-channel-participants="${channelId}"]`)
    if (!container) {
      container = document.createElement("div")
      container.className = "voice-participants"
      container.dataset.voiceChannelParticipants = channelId
      channelLink.insertAdjacentElement("afterend", container)
    }

    // Don't duplicate
    if (container.querySelector(`[data-voice-user-id="${data.user_id}"]`)) return

    if (data.sidebar_html) {
      container.insertAdjacentHTML("beforeend", data.sidebar_html)
    }
  }

  removeSidebarParticipant(channelId, userId) {
    const container = document.querySelector(`[data-voice-channel-participants="${channelId}"]`)
    if (!container) return
    const el = container.querySelector(`[data-voice-user-id="${userId}"]`)
    if (el) el.remove()
    if (!container.children.length) container.remove()
  }

  // Update the main voice channel view to show "connected" state
  updateMainViewConnected(data) {
    // Replace join button with connected text
    const joinBtn = document.querySelector("[data-voice-join-btn]")
    if (joinBtn) {
      joinBtn.outerHTML = '<p class="text-green-400 text-sm font-medium" data-voice-connected-text>You\'re connected to this voice channel</p>'
    }

    // Add participant card to the grid (or replace empty state)
    const emptyState = document.querySelector("[data-voice-empty-state]")
    const gridContainer = document.querySelector("[data-voice-participant-grid]")

    const cardHtml = this.buildParticipantCard(data)

    if (emptyState) {
      emptyState.outerHTML = `<div class="flex-1 p-3 overflow-y-auto" data-voice-participant-grid><div class="voice-grid h-full">${cardHtml}</div></div>`
    } else if (gridContainer) {
      const grid = gridContainer.querySelector(".voice-grid") || gridContainer
      if (!grid.querySelector(`[data-voice-participant-id="${data.user_id}"]`)) {
        grid.insertAdjacentHTML("beforeend", cardHtml)
      }
    }
  }

  updateMainViewDisconnected() {
    // Remove own participant card from grid if visible
    const currentUserId = document.body.dataset.currentUserId
    if (currentUserId) {
      const card = document.querySelector(`[data-voice-participant-id="${currentUserId}"]`)
      if (card) card.remove()
    }

    // If the voice-grid inside the container is empty, replace the whole grid container with empty state
    const gridContainer = document.querySelector("[data-voice-participant-grid]")
    const voiceGrid = gridContainer?.querySelector(".voice-grid")
    if (gridContainer && voiceGrid && voiceGrid.children.length === 0) {
      const wrapper = document.querySelector("[data-current-channel-id]")
      const channelName = wrapper?.querySelector("h1")?.textContent || "Voice Channel"
      gridContainer.outerHTML = `
        <div class="flex-1 flex flex-col items-center justify-center p-8" data-voice-empty-state>
          <div class="w-24 h-24 rounded-full flex items-center justify-center mx-auto mb-6" style="background: rgba(255,255,255,0.05);">
            <svg class="w-12 h-12 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072M18.364 5.636a9 9 0 010 12.728M5.636 18.364a9 9 0 010-12.728"/></svg>
          </div>
          <h2 class="text-xl font-bold text-white mb-1">${this.escapeHtml(channelName)}</h2>
          <p class="text-gray-500 text-sm">No one is in this channel yet.</p>
        </div>`
    }

    // Replace "connected" text with the join button
    const connectedText = document.querySelector("[data-voice-connected-text]")
    if (connectedText) {
      const wrapper = document.querySelector("[data-current-channel-id]")
      const channelId = wrapper?.dataset.currentChannelId || ""
      const serverId = wrapper?.dataset.currentServerId || ""
      connectedText.outerHTML = `
        <button type="button"
                class="px-6 py-2.5 bg-green-600 hover:bg-green-500 text-white font-semibold rounded-full transition flex items-center gap-2 cursor-pointer text-sm"
                data-voice-join-btn
                onclick="window.dispatchEvent(new CustomEvent('voice:join', { detail: { channelId: '${channelId}', serverId: '${serverId}' } }))">
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072"/></svg>
          Join Voice
        </button>`
    }
  }

  updateMuteUI() {
    if (!this.hasMuteBtnTarget) return

    if (this.muted) {
      this.muteBtnTarget.classList.add("text-red-400")
      this.muteBtnTarget.classList.remove("text-gray-300")
      if (this.hasMuteIconTarget) {
        this.muteIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 3l18 18"/>'
      }
    } else {
      this.muteBtnTarget.classList.remove("text-red-400")
      this.muteBtnTarget.classList.add("text-gray-300")
      if (this.hasMuteIconTarget) {
        this.muteIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/>'
      }
    }
  }

  updateDeafenUI() {
    if (!this.hasDeafenBtnTarget) return

    if (this.deafened) {
      this.deafenBtnTarget.classList.add("text-red-400")
      this.deafenBtnTarget.classList.remove("text-gray-300")
      if (this.hasDeafenIconTarget) {
        this.deafenIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/>'
      }
    } else {
      this.deafenBtnTarget.classList.remove("text-red-400")
      this.deafenBtnTarget.classList.add("text-gray-300")
      if (this.hasDeafenIconTarget) {
        this.deafenIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z M15.54 8.46a5 5 0 010 7.07"/>'
      }
    }
  }

  buildParticipantCard(data) {
    const color = data.profile_color || "#2b2d31"
    const initial = data.username?.[0]?.toUpperCase() || "?"
    const avatarHtml = data.avatar_url
      ? `<img src="${data.avatar_url}" class="voice-avatar" />`
      : `<div class="voice-avatar-fallback" style="background-color: color-mix(in srgb, ${color}, white 20%)">${initial}</div>`

    const vsId = data.voice_state_id || ""
    return `
      <div class="voice-card group" data-voice-participant-id="${data.user_id}" data-voice-state-id="${vsId}" data-action="contextmenu->voice-context#show" style="--card-color: ${color}">
        <div class="voice-card-inner">
          <div class="voice-avatar-wrapper">${avatarHtml}</div>
          <div class="voice-username-pill">
            <span class="truncate">${this.escapeHtml(data.username)}</span>
          </div>
        </div>
      </div>`
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  // --- Moderation event handlers ---

  handleForceDisconnect() {
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this.serverMuted = false
    this.serverDeafened = false
    this.channelId = null
    this.showToast("You were disconnected from voice")
  }

  async handleForceMove({ toChannelId, toChannelName, voiceStateId }) {
    // Disconnect from current LiveKit room
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())

    // Update channel info
    this.channelId = toChannelId
    this.channelDisplayName = toChannelName || "Voice"

    // Get a fresh token for the new channel and reconnect
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/channels/${toChannelId}/refresh_voice_token`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })

      if (!res.ok) {
        this.hideControlsBar()
        this.updateMainViewDisconnected()
        this.channelId = null
        this.showToast("Failed to join new voice channel", true)
        return
      }

      const data = await res.json()
      const connected = await this.connectToLiveKit(data.url, data.token)
      if (!connected) {
        this.hideControlsBar()
        this.updateMainViewDisconnected()
        this.channelId = null
        this.showToast("Failed to connect to new voice channel", true)
        return
      }

      this.showControlsBar()
      this.showToast(`You were moved to #${toChannelName || "voice"}`)
    } catch (err) {
      console.error("[Voice] Force move failed:", err)
      this.hideControlsBar()
      this.channelId = null
      this.showToast("Failed to join new voice channel", true)
    }
  }

  async handleServerMute({ serverMute }) {
    this.serverMuted = serverMute
    if (serverMute) {
      // Force-disable mic
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(false)
      }
      this.muted = true
      this.updateMuteUI()
    } else {
      // Re-enable mic only if not self-muted
      if (!this.muted || this.serverMuted === false) {
        // User can manually unmute now — just update indicator
      }
    }
  }

  async handleServerDeafen({ serverDeaf }) {
    this.serverDeafened = serverDeaf
    if (serverDeaf) {
      // Disable mic + all remote audio
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(false)
      }
      this.muted = true
      this.deafened = true

      if (this.room) {
        this.room.remoteParticipants.forEach((participant) => {
          participant.audioTrackPublications.forEach((pub) => {
            if (pub.track) {
              pub.track.mediaStreamTrack.enabled = false
            }
          })
        })
      }
      this.updateMuteUI()
      this.updateDeafenUI()
    } else {
      // Re-enable remote audio
      this.deafened = false
      if (this.room) {
        this.room.remoteParticipants.forEach((participant) => {
          participant.audioTrackPublications.forEach((pub) => {
            if (pub.track) {
              pub.track.mediaStreamTrack.enabled = true
            }
          })
        })
      }
      this.updateDeafenUI()
    }
  }

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-red-600" : "bg-green-600"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 3000)
  }
}

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
    this.channelId = null
    this.channelDisplayName = null

    // Restore mute/deafen preference from last session
    try {
      this.muted = localStorage.getItem("voice_pref_muted") === "true"
      this.deafened = localStorage.getItem("voice_pref_deafened") === "true"
      this._mutedBeforeDeafen = localStorage.getItem("voice_muted_before_deafen") === "true"
    } catch {
      this.muted = false
      this.deafened = false
      this._mutedBeforeDeafen = false
    }

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

    // Restore LiveKit room preserved from a previous navigation
    if (window._voiceState?.room) {
      const vs = window._voiceState
      delete window._voiceState
      this.room = vs.room
      this.channelId = vs.channelId
      this.channelDisplayName = vs.channelDisplayName
      this.muted = vs.muted
      this.deafened = vs.deafened
      this._mutedBeforeDeafen = vs.mutedBeforeDeafen
      this.serverMuted = vs.serverMuted || false
      this.serverDeafened = vs.serverDeafened || false

      if (this.hasChannelNameTarget) {
        this.channelNameTarget.textContent = this.channelDisplayName
      }
      this.showControlsBar()
      this._startAudioLevelMonitor()
      this.syncAllVoiceUI()
      return
    }

    // Restore state from server-rendered values (page load while already in a call)
    if (this.connectedValue) {
      this.channelId = this.channelIdValue
      this.channelDisplayName = this.channelNameValue
      this.muted = this.selfMuteValue
      this.deafened = this.selfDeafValue

      // Restore pre-deafen mute memory from localStorage
      try {
        this._mutedBeforeDeafen = localStorage.getItem("voice_muted_before_deafen") === "true"
      } catch {}

      if (this.hasChannelNameTarget) {
        this.channelNameTarget.textContent = this.channelDisplayName
      }

      this.syncAllVoiceUI()

      // Reconnect to LiveKit so audio actually works
      this.reconnectToLiveKit()
    }
  }

  disconnect() {
    this._stopAudioLevelMonitor()
    window.removeEventListener("voice:join", this._onJoinRequest)
    window.removeEventListener("voice:disconnect", this._onDisconnectRequest)
    window.removeEventListener("voice:force-disconnect", this._onForceDisconnect)
    window.removeEventListener("voice:force-move", this._onForceMove)
    window.removeEventListener("voice:server-mute", this._onServerMute)
    window.removeEventListener("voice:server-deafen", this._onServerDeafen)
    // Preserve the LiveKit room across page navigations instead of disconnecting.
    // The next connect() will pick it up from window._voiceState.
    if (this.room) {
      window._voiceState = {
        room: this.room,
        channelId: this.channelId,
        channelDisplayName: this.channelDisplayName,
        muted: this.muted,
        deafened: this.deafened,
        mutedBeforeDeafen: this._mutedBeforeDeafen,
        serverMuted: this.serverMuted,
        serverDeafened: this.serverDeafened
      }
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
          this.syncAllVoiceUI()
        } else {
          try {
            micStream = await navigator.mediaDevices.getUserMedia({ audio: true })
            console.log("[Voice] Microphone permission granted")
          } catch (micErr) {
            console.warn("[Voice] Microphone denied:", micErr.name, micErr.message)
            this.muted = true
            this.syncAllVoiceUI()
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
      this.syncAllVoiceUI()

      // Notify server of initial mute/deafen state if joining muted/deafened
      if (this.muted || this.deafened) {
        const csrf2 = document.querySelector("meta[name=csrf-token]")?.content
        try {
          if (this.deafened) {
            await fetch("/voice_states/self_deafen", {
              method: "PATCH",
              headers: { "X-CSRF-Token": csrf2, "Content-Type": "application/json" }
            })
          } else {
            await fetch("/voice_states/self_mute", {
              method: "PATCH",
              headers: { "X-CSRF-Token": csrf2, "Content-Type": "application/json" }
            })
          }
        } catch {}
      }

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
      this._stopAudioLevelMonitor()
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
          this.syncAllVoiceUI()
        }
      } else {
        console.log("[Voice] Microphone stays muted")
      }

      // Attach any already-subscribed remote audio tracks
      this._attachExistingTracks()

      // Start polling audio levels for speaking indicators
      this._startAudioLevelMonitor()

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
    this._stopAudioLevelMonitor()
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
    this._mutedBeforeDeafen = false
    this._clearMuteMemory()
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
    this._stopAudioLevelMonitor()
    delete window._voiceState // Clear any preserved state
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
    this._mutedBeforeDeafen = false
    this._clearMuteMemory()
    this.channelId = null
  }

  // Stimulus action for the disconnect button in the controls bar
  leave() {
    this.disconnectVoice()
  }

  async toggleMute() {
    this.muted = !this.muted

    // If deafened, only change the remembered state for undeafen — don't
    // touch the mic or server state since deafen overrides everything
    if (this.deafened) {
      this._mutedBeforeDeafen = this.muted
      this._saveMuteMemory()
      // Control bar still shows muted (deafen implies mute), no visual change
      return
    }

    try {
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(!this.muted)
      }
    } catch (err) {
      console.warn("[Voice] setMicrophoneEnabled failed:", err.message)
    }

    // Re-setup local analyser when unmuting (track may be new)
    if (!this.muted && !this._localAnalyser) {
      this._setupLocalAnalyser()
    }

    this.syncAllVoiceUI()

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      await fetch("/voice_states/self_mute", {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
    } catch (err) {
      console.error("Failed to update mute state:", err)
    }

    this._saveVoicePrefs()
  }

  async toggleDeafen() {
    const wasDeafened = this.deafened
    this.deafened = !this.deafened

    if (this.deafened) {
      // Deafening: remember current mute state, then force mute
      this._mutedBeforeDeafen = this.muted
      this._saveMuteMemory()
      this.muted = true
    } else {
      // Undeafening: restore the mute state from before deafening
      this.muted = this._mutedBeforeDeafen
      this._clearMuteMemory()
    }

    try {
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(!this.muted)
      }
    } catch (err) {
      console.warn("[Voice] setMicrophoneEnabled failed:", err.message)
    }

    // Re-setup local analyser when undeafening with mic active
    if (!this.deafened && !this.muted && !this._localAnalyser) {
      this._setupLocalAnalyser()
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

    this.syncAllVoiceUI()

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      const body = this.deafened ? {} : { self_mute: this.muted }
      await fetch("/voice_states/self_deafen", {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify(body)
      })
    } catch (err) {
      console.error("Failed to update deafen state:", err)
    }

    this._saveVoicePrefs()
  }

  _saveVoicePrefs() {
    try {
      localStorage.setItem("voice_pref_muted", String(this.muted))
      localStorage.setItem("voice_pref_deafened", String(this.deafened))
    } catch {}
  }

  _saveMuteMemory() {
    try { localStorage.setItem("voice_muted_before_deafen", String(this._mutedBeforeDeafen)) } catch {}
  }

  _clearMuteMemory() {
    try { localStorage.removeItem("voice_muted_before_deafen") } catch {}
  }

  handleDisconnected() {
    this._stopAudioLevelMonitor()
    this.room = null
    const currentUserId = document.body.dataset.currentUserId
    if (this.channelId && currentUserId) {
      this.removeSidebarParticipant(this.channelId, currentUserId)
    }
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this._mutedBeforeDeafen = false
    this._clearMuteMemory()
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
      gridContainer.replaceWith(this._buildVoiceEmptyState(channelName))
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

    // Deafen implies mute — always show muted visual when deafened
    const effectivelyMuted = this.muted || this.deafened

    if (effectivelyMuted) {
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

  // Update all voice UI at once: control bar buttons + sidebar/main view indicators
  syncAllVoiceUI() {
    this.updateMuteUI()
    this.updateDeafenUI()
    this._updateSelfVoiceIndicators()
  }

  // Immediately sync sidebar participant + main view card icons for the current user
  _updateSelfVoiceIndicators() {
    const currentUserId = document.body.dataset.currentUserId
    if (!currentUserId) return

    const effectiveMute = this.muted || this.deafened
    const effectiveDeaf = this.deafened

    // --- Sidebar participant icons ---
    const participant = document.querySelector(`[data-voice-user-id="${currentUserId}"]`)
    if (participant) {
      participant.querySelectorAll(".voice-mute-icon, .voice-deaf-icon, .voice-server-mute-icon, .voice-server-deaf-icon").forEach(el => el.remove())
      const nameSpan = participant.querySelector("span")

      if (this.serverMuted && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-server-mute-icon w-3 h-3 text-red-400 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2" stroke-linecap="round"/></svg>')
      } else if (effectiveMute && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-mute-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>')
      }

      if (this.serverDeafened && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-server-deaf-icon w-3 h-3 text-red-400 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/></svg>')
      } else if (effectiveDeaf && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-deaf-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/></svg>')
      }
    }

    // --- Main voice view card status badges ---
    const card = document.querySelector(`[data-voice-participant-id="${currentUserId}"]`)
    if (card) {
      const existingIcons = card.querySelector(".voice-status-icons")
      if (existingIcons) existingIcons.remove()

      const hasMute = this.serverMuted || effectiveMute
      const hasDeaf = this.serverDeafened || effectiveDeaf

      if (hasMute || hasDeaf) {
        let badgesHtml = ""
        if (hasMute) {
          const color = this.serverMuted ? "text-red-400" : ""
          badgesHtml += `<div class="voice-status-badge ${this.serverMuted ? 'server-muted' : ''}"><svg class="w-3.5 h-3.5 ${color}" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2.5" stroke-linecap="round"/></svg></div>`
        }
        if (hasDeaf) {
          const color = this.serverDeafened ? "text-red-400" : ""
          badgesHtml += `<div class="voice-status-badge ${this.serverDeafened ? 'server-deafened' : ''}"><svg class="w-3.5 h-3.5 ${color}" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg></div>`
        }
        const inner = card.querySelector(".voice-card-inner")
        if (inner) {
          inner.insertAdjacentHTML("beforeend", `<div class="voice-status-icons">${badgesHtml}</div>`)
        }
      }
    }
  }

  buildParticipantCard(data) {
    const color = data.profile_color || "#1e1c1b"
    const initial = data.username?.[0]?.toUpperCase() || "?"
    const avatarHtml = data.avatar_url
      ? `<img src="${data.avatar_url}" class="voice-avatar" />`
      : `<div class="voice-avatar-fallback" style="background-color: color-mix(in srgb, ${color}, white 20%)">${initial}</div>`

    const tpl = document.getElementById("tpl-voice-card").content.cloneNode(true)
    const card = tpl.querySelector(".voice-card")
    card.dataset.voiceParticipantId = data.user_id
    card.dataset.voiceStateId = data.voice_state_id || ""
    card.dataset.action = "contextmenu->voice-context#show"
    card.style.setProperty("--card-color", color)
    card.querySelector('[data-slot="avatar"]').innerHTML = avatarHtml
    card.querySelector('[data-slot="username"]').textContent = data.username
    return card.outerHTML
  }

  _buildVoiceEmptyState(channelName) {
    const tpl = document.getElementById("tpl-voice-empty-state").content.cloneNode(true)
    tpl.querySelector('[data-slot="channel-name"]').textContent = channelName
    return tpl.firstElementChild
  }

  // --- Moderation event handlers ---

  handleForceDisconnect() {
    this._stopAudioLevelMonitor()
    delete window._voiceState
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    document.querySelectorAll('[id^="voice-audio-"]').forEach(el => el.remove())
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this._mutedBeforeDeafen = false
    this._clearMuteMemory()
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
    // Ignore echoed broadcasts where the value hasn't changed — prevents
    // self-action broadcasts from overwriting local state.
    if (this.serverMuted === serverMute) return
    this.serverMuted = serverMute
    if (serverMute) {
      // Force-disable mic
      if (this.room?.localParticipant) {
        await this.room.localParticipant.setMicrophoneEnabled(false)
      }
      this.muted = true
      this.syncAllVoiceUI()
    } else {
      // Re-enable mic only if not self-muted
      this.syncAllVoiceUI()
    }
  }

  async handleServerDeafen({ serverDeaf }) {
    // Ignore echoed broadcasts where the value hasn't changed — prevents
    // self-action broadcasts from overwriting local state.
    if (this.serverDeafened === serverDeaf) return
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
      this.syncAllVoiceUI()
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
      this.syncAllVoiceUI()
    }
  }

  // --- Speaking indicators (audio-level driven) ---

  _startAudioLevelMonitor() {
    if (this._audioLevelRAF) return
    this._setupLocalAnalyser()

    const tick = () => {
      if (!this.room) { this._audioLevelRAF = null; return }
      this._pollAudioLevels()
      this._audioLevelRAF = requestAnimationFrame(tick)
    }
    this._audioLevelRAF = requestAnimationFrame(tick)
  }

  _stopAudioLevelMonitor() {
    if (this._audioLevelRAF) {
      cancelAnimationFrame(this._audioLevelRAF)
      this._audioLevelRAF = null
    }
    this._teardownLocalAnalyser()
    // Clear all speaking indicators
    document.querySelectorAll(".speaking").forEach(el => {
      el.classList.remove("speaking")
      el.style.removeProperty("--audio-level")
    })
    document.querySelectorAll(".voice-speaking").forEach(el => {
      el.classList.remove("voice-speaking")
      el.style.removeProperty("--audio-level")
    })
  }

  // Web Audio analyser for instant local mic feedback (per-frame)
  _setupLocalAnalyser() {
    try {
      if (!this.room?.localParticipant) return
      const pub = Array.from(this.room.localParticipant.audioTrackPublications.values())
        .find(p => p.track)
      const mst = pub?.track?.mediaStreamTrack
      if (!mst || mst.readyState !== "live") return

      this._localAudioCtx = new (window.AudioContext || window.webkitAudioContext)()
      if (this._localAudioCtx.state === "suspended") this._localAudioCtx.resume()
      const source = this._localAudioCtx.createMediaStreamSource(new MediaStream([mst]))
      this._localAnalyser = this._localAudioCtx.createAnalyser()
      this._localAnalyser.fftSize = 256
      this._localAnalyser.smoothingTimeConstant = 0.4
      source.connect(this._localAnalyser)
      this._localAnalyserBuf = new Float32Array(this._localAnalyser.fftSize)
    } catch (e) {
      console.warn("[Voice] Local analyser setup failed:", e)
    }
  }

  _teardownLocalAnalyser() {
    if (this._localAudioCtx) {
      try { this._localAudioCtx.close() } catch {}
      this._localAudioCtx = null
      this._localAnalyser = null
      this._localAnalyserBuf = null
    }
  }

  _getLocalRMS() {
    if (!this._localAnalyser) return -1
    try {
      this._localAnalyser.getFloatTimeDomainData(this._localAnalyserBuf)
      let sum = 0
      for (let i = 0; i < this._localAnalyserBuf.length; i++) {
        sum += this._localAnalyserBuf[i] * this._localAnalyserBuf[i]
      }
      // RMS → normalized 0-1 (raw mic RMS is typically 0-0.3)
      return Math.min(Math.sqrt(sum / this._localAnalyserBuf.length) * 4, 1)
    } catch {
      return -1
    }
  }

  _pollAudioLevels() {
    if (!this.room) return
    const THRESHOLD = 0.01

    // Local participant — use Web Audio analyser for instant feedback
    const localP = this.room.localParticipant
    let localLevel = this._getLocalRMS()
    if (localLevel < 0) localLevel = localP.audioLevel || 0
    const localSpeaking = localLevel > THRESHOLD && !this.muted && !this.deafened
    this._applySpeakingIndicator(localP.identity, localLevel, localSpeaking)

    // Remote participants — use LiveKit's audioLevel directly (no isSpeaking hysteresis)
    for (const [, p] of this.room.remoteParticipants) {
      const level = p.audioLevel || 0
      this._applySpeakingIndicator(p.identity, level, level > THRESHOLD)
    }
  }

  _applySpeakingIndicator(identity, level, speaking) {
    const card = document.querySelector(`[data-voice-participant-id="${identity}"]`)
    if (card) {
      card.classList.toggle("speaking", speaking)
      if (speaking) {
        card.style.setProperty("--audio-level", level.toFixed(3))
      } else {
        card.style.removeProperty("--audio-level")
      }
    }

    const sidebar = document.querySelector(`[data-voice-user-id="${identity}"]`)
    if (sidebar) {
      sidebar.classList.toggle("voice-speaking", speaking)
      if (speaking) {
        sidebar.style.setProperty("--audio-level", level.toFixed(3))
      } else {
        sidebar.style.removeProperty("--audio-level")
      }
    }
  }

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-red-600" : "bg-green-600"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium context-pop`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.3s"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 3000)
  }
}

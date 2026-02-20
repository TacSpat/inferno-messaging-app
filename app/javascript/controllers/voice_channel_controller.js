import { Controller } from "@hotwired/stimulus"

// This controller lives on the voice-controls-bar in the sidebar layout.
// The "Join Voice" button inside the turbo frame communicates via window events.
export default class extends Controller {
  static targets = ["statusText", "channelName", "muteBtn", "deafenBtn", "muteIcon", "deafenIcon", "screenShareBtn", "screenShareIcon"]
  static values = {
    serverId: String,
    connected: { type: Boolean, default: false },
    channelId: { type: String, default: "" },
    channelName: { type: String, default: "" },
    selfMute: { type: Boolean, default: false },
    selfDeaf: { type: Boolean, default: false },
    inputMode: { type: String, default: "voice_activity" },
    inputSensitivity: { type: Number, default: 0.01 },
    noiseSuppression: { type: Boolean, default: true },
    pttKeyCode: { type: String, default: "Backquote" }
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
    this._screenShareActive = false
    this._pttActive = false
    this._remoteScreenTracks = new Map()
    this._watchingStreams = new Set()
    this._rnnoiseProcessor = null
    this._rnnoiseAudioCtx = null

    // Push-to-talk key listeners
    this._onPttKeyDown = (e) => this._handlePttKeyDown(e)
    this._onPttKeyUp = (e) => this._handlePttKeyUp(e)
    document.addEventListener("keydown", this._onPttKeyDown, true)
    document.addEventListener("keyup", this._onPttKeyUp, true)

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
      this._screenShareActive = vs.screenShareActive || false
      this._pttActive = vs.pttActive || false
      this._watchingStreams = new Set(vs.watchingStreams || [])
      this._rnnoiseProcessor = vs.rnnoiseProcessor || null
      this._rnnoiseAudioCtx = vs.rnnoiseAudioCtx || null

      if (this.hasChannelNameTarget) {
        this.channelNameTarget.textContent = this.channelDisplayName
      }
      this.showControlsBar()
      this._startAudioLevelMonitor()
      this.syncAllVoiceUI()
      this._setupCardClickListener()
      if (this._screenShareActive) {
        requestAnimationFrame(() => this._showLocalScreenSharePreview())
      }
      // Repopulate remote screen tracks from room and re-open watched streams
      requestAnimationFrame(() => {
        if (!this.room) return
        this.room.remoteParticipants.forEach((participant) => {
          participant.videoTrackPublications.forEach((pub) => {
            if (pub.track && pub.isSubscribed && pub.track.source === "screen_share") {
              this._remoteScreenTracks.set(participant.identity, { track: pub.track, participant })
              this._addLiveBadgeToCard(participant.identity)
            }
          })
        })
        const toReopen = new Set(this._watchingStreams)
        this._watchingStreams.clear()
        for (const identity of toReopen) {
          if (this._remoteScreenTracks.has(identity)) {
            this._openStreamPreview(identity)
          }
        }
      })
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
    document.removeEventListener("keydown", this._onPttKeyDown, true)
    document.removeEventListener("keyup", this._onPttKeyUp, true)
    if (this._visibilityHandler) {
      document.removeEventListener("visibilitychange", this._visibilityHandler)
      this._visibilityHandler = null
    }
    if (this._cardClickHandler) {
      document.removeEventListener("click", this._cardClickHandler)
      this._cardClickHandler = null
    }
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
        serverDeafened: this.serverDeafened,
        screenShareActive: this._screenShareActive,
        pttActive: this._pttActive,
        watchingStreams: Array.from(this._watchingStreams || []),
        rnnoiseProcessor: this._rnnoiseProcessor,
        rnnoiseAudioCtx: this._rnnoiseAudioCtx
      }
      this.room = null
    }
  }

  async handleJoinRequest({ channelId, serverId }) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    // Set serverIdValue so _leaveServerVoiceState and other methods can use it
    this.serverIdValue = serverId

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
      document.querySelectorAll('[id^="voice-audio-"], [id^="voice-screen-audio-"], [id^="voice-screen-share-"]').forEach(el => el.remove())
      this._remoteScreenTracks.clear()

      const { Room, RoomEvent, Track } = await import("livekit-client")

      this.room = new Room({
        audioCaptureDefaults: {
          autoGainControl: true,
          echoCancellation: true,
          noiseSuppression: false  // RNNoise handles this when enabled
        }
      })

      // Attach remote audio + screen share tracks
      this.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
        console.log(`[Voice] Track subscribed: ${track.kind} (source: ${track.source}) from ${participant.identity}`)

        if (track.source === Track.Source.ScreenShare) {
          if (track.kind === Track.Kind.Video) {
            this._showRemoteScreenShare(track, participant)
          } else if (track.kind === Track.Kind.Audio) {
            // Screen share audio — attach as hidden audio element
            const el = track.attach()
            el.id = `voice-screen-audio-${participant.identity}`
            document.body.appendChild(el)
            this.room.startAudio().then(() => el.play().catch(() => {}))
          }
          return
        }

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
        console.log(`[Voice] Track unsubscribed: ${track.kind} (source: ${track.source}) from ${participant.identity}`)
        track.detach().forEach(el => el.remove())

        if (track.source === Track.Source.ScreenShare) {
          if (track.kind === Track.Kind.Video) {
            this._removeRemoteScreenShare(participant.identity)
          }
          const screenAudio = document.getElementById(`voice-screen-audio-${participant.identity}`)
          if (screenAudio) screenAudio.remove()
          return
        }

        const leftover = document.getElementById(`voice-audio-${participant.identity}`)
        if (leftover) leftover.remove()
      })

      // Detect when local screen share is stopped via browser's native "Stop sharing" button
      this.room.on(RoomEvent.LocalTrackUnpublished, (publication) => {
        if (publication.source === Track.Source.ScreenShare && this._screenShareActive) {
          console.log("[Voice] Local screen share ended (browser stop or track ended)")
          this._screenShareActive = false
          this._removeLocalScreenSharePreview()
          this._updateScreenShareUI()
          this._updateScreenShareState()
        }
      })

      this.room.on(RoomEvent.Disconnected, () => {
        console.log("[Voice] Disconnected from room")
        document.querySelectorAll('[id^="voice-audio-"], [id^="voice-screen-audio-"], [id^="voice-screen-share-"]').forEach(el => el.remove())
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
      let audioUnlocked = false
      try {
        await this.room.startAudio()
        console.log("[Voice] Audio started (autoplay unlocked)")
        audioUnlocked = true
      } catch {
        console.log("[Voice] Audio autoplay blocked — will unlock on first interaction")
      }

      // Enable microphone — non-fatal, user can still listen if mic is denied
      let micEnabled = false
      if (!this.muted) {
        try {
          await this.room.localParticipant.setMicrophoneEnabled(true)
          console.log("[Voice] Microphone enabled")
          micEnabled = true
        } catch (micErr) {
          console.warn("[Voice] Microphone access denied:", micErr.message)
          // Don't force muted — the audio unlock handler will retry on user gesture
        }
      } else {
        console.log("[Voice] Microphone stays muted")
      }

      // Enable RNNoise noise suppression if the user has it turned on
      if (this.noiseSuppressionValue && micEnabled) {
        await this._enableRnnoise()
      }

      // If push-to-talk mode, start with mic muted
      if (this.inputModeValue === "push_to_talk" && micEnabled) {
        this._setMicMuted(true)
        this.muted = true
      }

      // Always set up audio unlock as safety net — handles cases where
      // startAudio or setMicrophoneEnabled failed due to missing user gesture
      if (!audioUnlocked || !micEnabled) {
        this._setupAudioUnlock()
      }

      // Attach any already-subscribed remote audio tracks
      this._attachExistingTracks()

      // Start polling audio levels for speaking indicators
      this._startAudioLevelMonitor()

      // Set up click listener for LIVE badges on participant cards
      this._setupCardClickListener()

      // Re-open any previously watched streams (after _attachExistingTracks repopulated _remoteScreenTracks)
      if (this._watchingStreams.size > 0) {
        const toReopen = new Set(this._watchingStreams)
        this._watchingStreams.clear()
        for (const identity of toReopen) {
          if (this._remoteScreenTracks.has(identity)) {
            this._openStreamPreview(identity)
          }
        }
      }

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
    this._removeLocalScreenSharePreview()
    this._hideFloatingControls()
    this._disableRnnoise()
    if (this.room) {
      try { this.room.disconnect() } catch {}
      this.room = null
    }
    document.querySelectorAll('[id^="voice-audio-"], [id^="voice-screen-audio-"], [id^="voice-screen-share-"]').forEach(el => el.remove())
    this._remoteScreenTracks.clear()
    this._watchingStreams.clear()

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
    this._screenShareActive = false
    this._pttActive = false
    this.channelId = null
  }

  _setupAudioUnlock() {
    // On page refresh there's no user gesture, so audio + mic are blocked.
    // Wait for ANY click/keypress on the page, then unlock both.
    if (this._audioUnlockBound) return // prevent duplicate listeners
    this._audioUnlockBound = true

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

      // Also enable mic if it should be on but isn't yet
      if (!this.muted && !this.deafened && this.room?.localParticipant) {
        try {
          const micOn = this.room.localParticipant.isMicrophoneEnabled
          if (!micOn) {
            await this.room.localParticipant.setMicrophoneEnabled(true)
            console.log("[Voice] Microphone enabled via user interaction")
            this._setupLocalAnalyser()
            if (this.noiseSuppressionValue && !this._rnnoiseProcessor) {
              this._enableRnnoise()
            }
          }
        } catch (e) {
          console.warn("[Voice] Mic enable on unlock failed:", e)
        }
      }

      this._audioUnlockBound = false
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
      // Re-attach screen share video tracks
      participant.videoTrackPublications.forEach((pub) => {
        if (pub.track && pub.isSubscribed && pub.track.source === "screen_share") {
          this._showRemoteScreenShare(pub.track, participant)
        }
      })
    })
  }

  async reconnectToLiveKit() {
    // Fetch a fresh token without creating a new voice state
    const csrf = document.querySelector("meta[name=csrf-token]")?.content

    // Show reconnecting status
    if (this.hasStatusTextTarget) {
      this.statusTextTarget.textContent = "Reconnecting..."
      this.statusTextTarget.classList.remove("text-green-500")
      this.statusTextTarget.classList.add("text-yellow-500")
    }

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
      } else {
        // Restore "Voice Connected" status after successful reconnect
        if (this.hasStatusTextTarget) {
          this.statusTextTarget.textContent = "Voice Connected"
          this.statusTextTarget.classList.remove("text-yellow-500")
          this.statusTextTarget.classList.add("text-green-500")
        }
      }
    } catch (err) {
      console.error("[Voice] Failed to reconnect:", err)
      this._cleanUpAfterFailedReconnect()
    }
  }

  async disconnectVoice() {
    this._stopAudioLevelMonitor()
    this._removeLocalScreenSharePreview()
    this._hideFloatingControls()
    await this._disableRnnoise()
    delete window._voiceState // Clear any preserved state
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    // Clean up remote audio + screen share elements
    document.querySelectorAll('[id^="voice-audio-"], [id^="voice-screen-audio-"], [id^="voice-screen-share-"]').forEach(el => el.remove())
    this._screenShareActive = false
    this._pttActive = false
    this._remoteScreenTracks.clear()
    this._watchingStreams.clear()

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

    // Use track-level mute/unmute (instant) instead of setMicrophoneEnabled
    // which destroys and recreates the track (slow, calls getUserMedia again)
    this._setMicMuted(this.muted)

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

    // Use track-level mute (instant) instead of setMicrophoneEnabled (slow)
    this._setMicMuted(this.muted)

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

  // Instant mic mute/unmute using MediaStreamTrack.enabled toggle.
  // Unlike setMicrophoneEnabled() which destroys and recreates the track
  // (calling getUserMedia again — slow), this keeps the track alive and
  // just silences it at the media level for instant response.
  // Note: we intentionally do NOT call pub.mute()/unmute() because LiveKit's
  // SDK stops the underlying track on mute, which kills the analyser source
  // and requires getUserMedia on unmute — defeating the purpose.
  _setMicMuted(muted) {
    if (!this.room?.localParticipant) return

    try {
      const pubs = Array.from(this.room.localParticipant.audioTrackPublications.values())
      for (const pub of pubs) {
        if (pub.track?.mediaStreamTrack) {
          pub.track.mediaStreamTrack.enabled = !muted
        }
      }
    } catch (e) {
      console.warn("[Voice] Track-level mute failed:", e)
    }

    // Manage speaking indicator analyser — teardown on mute, recreate on unmute
    if (muted) {
      this._teardownLocalAnalyser()
    } else {
      this._setupLocalAnalyser()
    }
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
    this._removeLocalScreenSharePreview()
    this._hideFloatingControls()
    this._disableRnnoise()
    this.room = null
    document.querySelectorAll('[id^="voice-screen-share-"], [id^="voice-screen-audio-"]').forEach(el => el.remove())
    this._remoteScreenTracks.clear()
    this._watchingStreams.clear()
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
    this._screenShareActive = false
    this._pttActive = false
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
    this._updateScreenShareUI()
    this._updateSelfVoiceIndicators()
    this._syncFloatingControlStates()
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
    this._removeLocalScreenSharePreview()
    this._hideFloatingControls()
    this._disableRnnoise()
    delete window._voiceState
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    document.querySelectorAll('[id^="voice-audio-"], [id^="voice-screen-audio-"], [id^="voice-screen-share-"]').forEach(el => el.remove())
    this._remoteScreenTracks.clear()
    this._watchingStreams.clear()
    this.hideControlsBar()
    this.updateMainViewDisconnected()
    this.muted = false
    this.deafened = false
    this._mutedBeforeDeafen = false
    this._clearMuteMemory()
    this.serverMuted = false
    this.serverDeafened = false
    this._screenShareActive = false
    this._pttActive = false
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
    const THRESHOLD = this.inputSensitivityValue

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

  // ── Push-to-Talk ──

  _handlePttKeyDown(e) {
    if (e.repeat) return
    if (this.inputModeValue !== "push_to_talk") return
    if (e.code !== this.pttKeyCodeValue) return
    if (!this.room?.localParticipant) return

    // Don't fire PTT when typing in text fields
    const tag = e.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || e.target.isContentEditable) return

    e.preventDefault()
    this._pttActive = true
    this._setMicMuted(false)
    this.muted = false
    this.syncAllVoiceUI()
  }

  _handlePttKeyUp(e) {
    if (this.inputModeValue !== "push_to_talk") return
    if (e.code !== this.pttKeyCodeValue) return
    if (!this._pttActive) return

    e.preventDefault()
    this._pttActive = false
    this._setMicMuted(true)
    this.muted = true
    this.syncAllVoiceUI()
  }

  // ── Screen Sharing ──

  async toggleScreenShare() {
    if (!this.room?.localParticipant) return

    if (this._screenShareActive) {
      await this.room.localParticipant.setScreenShareEnabled(false)
      this._screenShareActive = false
      this._removeLocalScreenSharePreview()
      this._updateScreenShareUI()
      this._updateScreenShareState()
    } else {
      this._showScreenSharePicker()
    }
  }

  _showScreenSharePicker() {
    const tpl = document.getElementById("tpl-screen-share-picker")
    if (!tpl) return
    const frag = tpl.content.cloneNode(true)
    const overlay = frag.querySelector("[data-ss-picker-overlay]")

    // Load saved preferences
    const defaults = { resolution: "720", frameRate: "30", contentType: "smoothness", audio: true }
    let prefs = defaults
    try {
      const saved = JSON.parse(localStorage.getItem("voice_screen_share_prefs"))
      if (saved) prefs = { ...defaults, ...saved }
    } catch {}

    // Set active pills from preferences
    overlay.querySelectorAll("[data-ss-group]").forEach(group => {
      const key = group.dataset.ssGroup
      const val = String(prefs[key])
      group.querySelectorAll(".ss-pill").forEach(pill => {
        pill.classList.toggle("ss-pill-active", pill.dataset.value === val)
      })
    })

    // Audio toggle
    const audioToggle = overlay.querySelector("[data-ss-audio-toggle]")
    if (prefs.audio) audioToggle.classList.add("ss-audio-on")

    // Pill click delegation
    overlay.querySelectorAll("[data-ss-group]").forEach(group => {
      group.addEventListener("click", (e) => {
        const pill = e.target.closest(".ss-pill")
        if (!pill) return
        group.querySelectorAll(".ss-pill").forEach(p => p.classList.remove("ss-pill-active"))
        pill.classList.add("ss-pill-active")
      })
    })

    // Audio toggle click
    audioToggle.addEventListener("click", () => {
      audioToggle.classList.toggle("ss-audio-on")
    })

    // Close handlers
    const close = () => overlay.remove()
    overlay.querySelector("[data-ss-close]").addEventListener("click", close)
    overlay.querySelector("[data-ss-cancel]").addEventListener("click", close)
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) close()
    })
    const onEsc = (e) => {
      if (e.key === "Escape") { close(); document.removeEventListener("keydown", onEsc) }
    }
    document.addEventListener("keydown", onEsc)

    // Go Live handler
    overlay.querySelector("[data-ss-go-live]").addEventListener("click", () => {
      const settings = {}
      overlay.querySelectorAll("[data-ss-group]").forEach(group => {
        const active = group.querySelector(".ss-pill-active")
        if (active) settings[group.dataset.ssGroup] = active.dataset.value
      })
      settings.audio = audioToggle.classList.contains("ss-audio-on")

      // Save preferences
      try { localStorage.setItem("voice_screen_share_prefs", JSON.stringify(settings)) } catch {}

      close()
      document.removeEventListener("keydown", onEsc)
      this._startScreenShareWithSettings(settings)
    })

    document.body.appendChild(overlay)
  }

  async _startScreenShareWithSettings(settings) {
    const resMap = {
      "480":  { width: 854,  height: 480  },
      "720":  { width: 1280, height: 720  },
      "1080": { width: 1920, height: 1080 },
      "1440": { width: 2560, height: 1440 },
      "2160": { width: 3840, height: 2160 }
    }
    const res = resMap[settings.resolution] || resMap["720"]
    const frameRate = parseInt(settings.frameRate) || 30
    const contentHint = settings.contentType === "clarity" ? "detail" : "motion"
    const audio = settings.audio !== false

    try {
      await this.room.localParticipant.setScreenShareEnabled(true, {
        resolution: { width: res.width, height: res.height, frameRate },
        contentHint,
        audio,
        systemAudio: audio ? "include" : "exclude",
        suppressLocalAudioPlayback: true
      })
      this._screenShareActive = true
      this._showLocalScreenSharePreview()
      this._updateScreenShareUI()
      this._updateScreenShareState()
    } catch (err) {
      if (err.name !== "NotAllowedError") {
        console.error("[Voice] Screen share error:", err)
        this.showToast("Screen share failed", true)
      }
    }
  }

  _updateScreenShareUI() {
    if (!this.hasScreenShareBtnTarget) return
    if (this._screenShareActive) {
      this.screenShareBtnTarget.classList.add("text-green-400")
      this.screenShareBtnTarget.classList.remove("text-gray-300")
    } else {
      this.screenShareBtnTarget.classList.remove("text-green-400")
      this.screenShareBtnTarget.classList.add("text-gray-300")
    }
  }

  async _updateScreenShareState() {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    try {
      await fetch("/voice_states/self_screen_share", {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      })
    } catch (err) {
      console.error("[Voice] Failed to update screen share state:", err)
    }
  }

  _showRemoteScreenShare(track, participant) {
    // Store track for opt-in watching — no DOM rendering until user clicks LIVE badge
    this._remoteScreenTracks.set(participant.identity, { track, participant })
    this._addLiveBadgeToCard(participant.identity)
  }

  _removeRemoteScreenShare(identity) {
    this._closeStreamPreview(identity)
    this._remoteScreenTracks.delete(identity)
    this._removeLiveBadgeFromCard(identity)
  }

  _toggleWatchStream(identity) {
    if (this._watchingStreams.has(identity)) {
      this._closeStreamPreview(identity)
    } else {
      this._openStreamPreview(identity)
    }
  }

  _openStreamPreview(identity) {
    const entry = this._remoteScreenTracks.get(identity)
    if (!entry) return
    if (document.getElementById(`voice-screen-share-${identity}`)) return

    const { track, participant } = entry
    const gridContainer = document.querySelector("[data-voice-participant-grid]")
    if (!gridContainer) return

    const container = document.createElement("div")
    container.id = `voice-screen-share-${identity}`
    container.className = "voice-screen-preview"
    container.dataset.screenShareIdentity = identity

    const badge = document.createElement("div")
    badge.className = "voice-live-badge"
    badge.textContent = "LIVE"

    const video = track.attach()
    video.className = "voice-screen-video"
    video.disablePictureInPicture = true

    const label = document.createElement("div")
    label.className = "voice-screen-label"
    label.textContent = `${participant.identity} is sharing their screen`

    const expandBtn = this._buildExpandButton()

    const closeBtn = document.createElement("button")
    closeBtn.className = "voice-screen-close"
    closeBtn.title = "Close"
    closeBtn.innerHTML = '<svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12"/></svg>'
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation()
      this._closeStreamPreview(identity)
    })

    container.appendChild(badge)
    container.appendChild(video)
    container.appendChild(label)
    container.appendChild(expandBtn)
    container.appendChild(closeBtn)

    container.addEventListener("click", () => this._toggleMaximizeStream(container))

    gridContainer.insertAdjacentElement("beforebegin", container)
    this._watchingStreams.add(identity)
  }

  _closeStreamPreview(identity) {
    const el = document.getElementById(`voice-screen-share-${identity}`)
    if (el) {
      if (el.classList.contains("voice-stream-focused")) {
        const voiceContent = document.querySelector("[data-voice-content]")
        if (voiceContent) voiceContent.classList.remove("voice-stream-maximized")
        this._hideFloatingControls()
        this._streamMaximized = false
      }
      el.remove()
    }
    this._watchingStreams.delete(identity)
  }

  // ── Local Screen Share Preview ──

  _showLocalScreenSharePreview() {
    if (!this.room?.localParticipant) return

    // Find local screen share video track
    let screenTrack = null
    for (const [, pub] of this.room.localParticipant.videoTrackPublications) {
      if (pub.track?.source === "screen_share") {
        screenTrack = pub.track
        break
      }
    }

    if (!screenTrack) {
      // Track may not be published yet — listen for it
      import("livekit-client").then(({ RoomEvent }) => {
        const handler = (pub) => {
          if (pub.track?.source === "screen_share" && pub.track?.kind === "video") {
            this.room?.off(RoomEvent.LocalTrackPublished, handler)
            this._showLocalScreenSharePreview()
          }
        }
        this.room?.on(RoomEvent.LocalTrackPublished, handler)
      })
      return
    }

    // Remove existing preview if any
    const existing = document.getElementById("voice-local-screen-preview")
    if (existing) existing.remove()

    const gridContainer = document.querySelector("[data-voice-participant-grid]")
    if (!gridContainer) return

    const container = document.createElement("div")
    container.id = "voice-local-screen-preview"
    container.className = "voice-screen-preview"
    container.dataset.screenShareIdentity = this.room.localParticipant.identity

    const badge = document.createElement("div")
    badge.className = "voice-live-badge"
    badge.textContent = "LIVE"

    const video = screenTrack.attach()
    video.muted = true
    video.className = "voice-screen-video"
    video.disablePictureInPicture = true

    // Hidden message shown when tab is not visible
    const hiddenMsg = document.createElement("div")
    hiddenMsg.className = "voice-screen-hidden-msg"
    hiddenMsg.style.display = "none"
    hiddenMsg.innerHTML = `
      <svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/></svg>
      <span class="hidden-msg-title">You are still streaming</span>
      <span class="hidden-msg-sub">Preview hidden to save resources</span>
    `

    const label = document.createElement("div")
    label.className = "voice-screen-label"
    label.textContent = "You are sharing your screen"

    const expandBtn = this._buildExpandButton()

    container.appendChild(badge)
    container.appendChild(video)
    container.appendChild(hiddenMsg)
    container.appendChild(label)
    container.appendChild(expandBtn)

    container.addEventListener("click", () => this._toggleMaximizeStream(container))

    gridContainer.insertAdjacentElement("beforebegin", container)

    // Visibility change handler
    this._visibilityHandler = () => this._handleVisibilityChange()
    document.addEventListener("visibilitychange", this._visibilityHandler)

    this._addLiveBadgeToCard(this.room.localParticipant.identity)
  }

  _removeLocalScreenSharePreview() {
    const el = document.getElementById("voice-local-screen-preview")
    if (el) {
      if (el.classList.contains("voice-stream-focused")) {
        const voiceContent = document.querySelector("[data-voice-content]")
        if (voiceContent) voiceContent.classList.remove("voice-stream-maximized")
        this._hideFloatingControls()
        this._streamMaximized = false
      }
      el.remove()
    }
    if (this._visibilityHandler) {
      document.removeEventListener("visibilitychange", this._visibilityHandler)
      this._visibilityHandler = null
    }
    if (this.room?.localParticipant) {
      this._removeLiveBadgeFromCard(this.room.localParticipant.identity)
    }
  }

  _handleVisibilityChange() {
    const container = document.getElementById("voice-local-screen-preview")
    if (!container) return
    const video = container.querySelector(".voice-screen-video")
    const hiddenMsg = container.querySelector(".voice-screen-hidden-msg")
    if (!video || !hiddenMsg) return

    if (document.hidden) {
      video.style.display = "none"
      hiddenMsg.style.display = "flex"
    } else {
      video.style.display = "block"
      hiddenMsg.style.display = "none"
    }
  }

  // ── Click-to-Maximize ──

  _toggleMaximizeStream(containerEl) {
    const voiceContent = document.querySelector("[data-voice-content]")
    if (!voiceContent) return

    if (voiceContent.classList.contains("voice-stream-maximized")) {
      voiceContent.classList.remove("voice-stream-maximized")
      containerEl.classList.remove("voice-stream-focused")
      this._hideFloatingControls()
      this._streamMaximized = false
    } else {
      // Un-focus any previously focused stream
      document.querySelectorAll(".voice-stream-focused").forEach(el => el.classList.remove("voice-stream-focused"))
      voiceContent.classList.add("voice-stream-maximized")
      containerEl.classList.add("voice-stream-focused")
      this._streamMaximized = true
      this._showFloatingControls(voiceContent)
    }
  }

  _buildExpandButton() {
    const btn = document.createElement("button")
    btn.className = "voice-screen-expand"
    btn.title = "Expand"
    btn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 8V4m0 0h4M4 4l5 5m11-1V4m0 0h-4m4 0l-5 5M4 16v4m0 0h4m-4 0l5-5m11 5v-4m0 4h-4m4 0l-5-5"/></svg>'
    return btn
  }

  // ── LIVE Badge on Participant Cards ──

  _addLiveBadgeToCard(identity) {
    const card = document.querySelector(`[data-voice-participant-id="${identity}"]`)
    if (!card) return
    const inner = card.querySelector(".voice-card-inner")
    if (!inner || inner.querySelector(".voice-live-indicator")) return
    const badge = document.createElement("div")
    badge.className = "voice-live-indicator"
    badge.textContent = "LIVE"
    inner.appendChild(badge)
  }

  _setupCardClickListener() {
    if (this._cardClickHandler) return
    this._cardClickHandler = (e) => {
      const liveBadge = e.target.closest(".voice-live-indicator")
      if (!liveBadge) return
      const card = liveBadge.closest("[data-voice-participant-id]")
      if (!card) return
      const identity = card.dataset.voiceParticipantId
      e.stopPropagation()
      this._toggleWatchStream(identity)
    }
    document.addEventListener("click", this._cardClickHandler)
  }

  _removeLiveBadgeFromCard(identity) {
    const card = document.querySelector(`[data-voice-participant-id="${identity}"]`)
    if (!card) return
    const badge = card.querySelector(".voice-live-indicator")
    if (badge) badge.remove()
  }

  // ── Floating Controls Overlay ──

  _showFloatingControls(voiceContent) {
    this._hideFloatingControls()

    const bar = document.createElement("div")
    bar.id = "voice-floating-controls"
    bar.className = "voice-floating-controls voice-floating-visible"

    bar.innerHTML = `
      <button class="voice-float-btn" data-float-action="mute" title="Toggle Mute">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/>
        </svg>
      </button>
      <button class="voice-float-btn" data-float-action="deafen" title="Toggle Deafen">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z M15.54 8.46a5 5 0 010 7.07"/>
        </svg>
      </button>
      <button class="voice-float-btn" data-float-action="screenshare" title="Toggle Screen Share">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
        </svg>
      </button>
      <div class="voice-float-separator"></div>
      <button class="voice-float-btn voice-float-btn-disconnect" data-float-action="disconnect" title="Disconnect">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 8l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2M5 3a2 2 0 00-2 2v1c0 8.284 6.716 15 15 15h1a2 2 0 002-2v-3.28a1 1 0 00-.684-.948l-4.493-1.498a1 1 0 00-1.21.502l-1.13 2.257a11.042 11.042 0 01-5.516-5.517l2.257-1.128a1 1 0 00.502-1.21L9.228 3.683A1 1 0 008.279 3H5z"/>
        </svg>
      </button>
    `

    // Delegated click handler for floating buttons
    bar.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-float-action]")
      if (!btn) return
      e.stopPropagation()
      const action = btn.dataset.floatAction
      if (action === "mute") this.toggleMute()
      else if (action === "deafen") this.toggleDeafen()
      else if (action === "screenshare") this.toggleScreenShare()
      else if (action === "disconnect") this.leave()
    })

    voiceContent.appendChild(bar)
    this._syncFloatingControlStates()

    // Auto-hide after 3 seconds
    this._floatingFadeTimer = setTimeout(() => this._fadeFloatingControls(), 3000)

    // Show on mouse move
    this._floatingMouseHandler = () => {
      const ctrl = document.getElementById("voice-floating-controls")
      if (ctrl) {
        ctrl.classList.remove("voice-floating-hidden")
        ctrl.classList.add("voice-floating-visible")
      }
      clearTimeout(this._floatingFadeTimer)
      this._floatingFadeTimer = setTimeout(() => this._fadeFloatingControls(), 3000)
    }
    voiceContent.addEventListener("mousemove", this._floatingMouseHandler)
  }

  _fadeFloatingControls() {
    const ctrl = document.getElementById("voice-floating-controls")
    if (ctrl) {
      ctrl.classList.remove("voice-floating-visible")
      ctrl.classList.add("voice-floating-hidden")
    }
  }

  _hideFloatingControls() {
    const ctrl = document.getElementById("voice-floating-controls")
    if (ctrl) ctrl.remove()
    if (this._floatingFadeTimer) {
      clearTimeout(this._floatingFadeTimer)
      this._floatingFadeTimer = null
    }
    if (this._floatingMouseHandler) {
      const voiceContent = document.querySelector("[data-voice-content]")
      if (voiceContent) voiceContent.removeEventListener("mousemove", this._floatingMouseHandler)
      this._floatingMouseHandler = null
    }
  }

  _syncFloatingControlStates() {
    const bar = document.getElementById("voice-floating-controls")
    if (!bar) return

    const muteBtn = bar.querySelector('[data-float-action="mute"]')
    const deafenBtn = bar.querySelector('[data-float-action="deafen"]')
    const shareBtn = bar.querySelector('[data-float-action="screenshare"]')

    const effectivelyMuted = this.muted || this.deafened
    if (muteBtn) {
      muteBtn.classList.toggle("voice-float-btn-active-red", effectivelyMuted)
      if (effectivelyMuted) {
        muteBtn.querySelector("svg").innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 3l18 18"/>'
      } else {
        muteBtn.querySelector("svg").innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/>'
      }
    }
    if (deafenBtn) {
      deafenBtn.classList.toggle("voice-float-btn-active-red", this.deafened)
      if (this.deafened) {
        deafenBtn.querySelector("svg").innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/>'
      } else {
        deafenBtn.querySelector("svg").innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z M15.54 8.46a5 5 0 010 7.07"/>'
      }
    }
    if (shareBtn) {
      shareBtn.classList.toggle("voice-float-btn-active-green", this._screenShareActive)
    }
  }

  // ── RNNoise Noise Suppression ──

  async _enableRnnoise() {
    try {
      const pub = Array.from(this.room.localParticipant.audioTrackPublications.values())
        .find(p => p.track)
      if (!pub?.track) return

      const audioCtx = new AudioContext()
      pub.track.setAudioContext(audioCtx)
      this._rnnoiseAudioCtx = audioCtx

      const { RnnoiseProcessor } = await import('../lib/rnnoise_processor')
      this._rnnoiseProcessor = new RnnoiseProcessor()
      await pub.track.setProcessor(this._rnnoiseProcessor)
      console.log('[Voice] RNNoise noise suppression enabled')
    } catch (err) {
      console.warn('[Voice] RNNoise failed, falling back to browser noise suppression:', err)
    }
  }

  async _disableRnnoise() {
    if (!this._rnnoiseProcessor) return
    try {
      const pub = Array.from(this.room.localParticipant.audioTrackPublications.values())
        .find(p => p.track)
      if (pub?.track) await pub.track.stopProcessor()
    } catch (err) {
      console.warn('[Voice] RNNoise cleanup error:', err)
    }
    this._rnnoiseProcessor = null
    if (this._rnnoiseAudioCtx) {
      try { this._rnnoiseAudioCtx.close() } catch {}
      this._rnnoiseAudioCtx = null
    }
  }

  showToast(msg, isError = false) {
    const toast = document.createElement("div")
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-danger" : "bg-success"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium context-pop`
    toast.textContent = msg
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = "opacity 0.3s"
      toast.style.opacity = "0"
      setTimeout(() => toast.remove(), 300)
    }, 3000)
  }
}

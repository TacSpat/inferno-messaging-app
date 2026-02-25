import { Controller } from "@hotwired/stimulus"
import {
  Room,
  RoomEvent,
  Track,
  DisconnectReason
} from "livekit-client"

const VOICE_SESSION_KEY = "voice-active-session"

/**
 * Voice channel controller — manages LiveKit room connection.
 *
 * Lives in the layout (not inside Turbo Frame) so it persists across navigation.
 * Listens for voice:join / voice:force-disconnect / voice:force-move events
 * dispatched by channel_sidebar_controller.
 *
 * Local mic speaking indicator uses a cloned MediaStreamTrack + AnalyserNode
 * so it reads the exact same audio LiveKit transmits, with zero latency.
 * Remote participant levels use AnalyserNode for smooth visualization.
 */
export default class extends Controller {
  static targets = [
    "controlsBar", "channelName", "statusText",
    "muteBtn", "muteIcon", "deafenBtn", "deafenIcon",
    "cameraBtn", "cameraIcon",
    "screenShareBtn", "screenShareIcon", "disconnectBtn"
  ]

  connect() {
    // Guard against re-initialization (data-turbo-permanent keeps us alive)
    if (this._initialized) return
    this._initialized = true

    this.room = null
    this.currentChannelId = null
    this.currentServerId = null
    this.voiceStateId = null
    this.currentProviderId = null
    this._muted = false
    this._deafened = false
    this._screenSharing = false
    this._cameraOn = false
    this._screenShareTrack = null
    this._userInitiatedDisconnect = false
    this._reconnecting = false
    this._audioElements = new Map()
    this._videoElements = new Map()   // identity → screen share preview element
    this._cameraElements = new Map()  // identity → camera video element
    this._pendingScreenShares = new Map()      // identity → { track, participant, placeholder }
    this._pendingScreenShareAudio = new Map()  // identity → { track, participant }
    this._screenShareAudioElements = new Map() // identity → audio element (opt-in)
    this._localPreviewVisHandler = null
    this._analysers = new Map()       // identity → { analyser } (remote only)
    this._localMeter = null           // { clone, ctx, analyser } for local mic
    this._levelRafId = null

    // Bind event listeners
    this._onJoin = this._handleJoin.bind(this)
    this._onForceDisconnect = this._handleForceDisconnect.bind(this)
    this._onForceMove = this._handleForceMove.bind(this)
    this._onServerMute = this._handleServerMute.bind(this)
    this._onServerDeafen = this._handleServerDeafen.bind(this)
    this._onBeforeUnload = this._handleBeforeUnload.bind(this)
    this._onOutputVolumeChanged = this._handleOutputVolumeChanged.bind(this)
    this._onEchoCancellationChanged = this._handleEchoCancellationChanged.bind(this)
    this._onAgcChanged = this._handleAgcChanged.bind(this)
    this._onInputDeviceChanged = this._handleInputDeviceChanged.bind(this)
    this._onOutputDeviceChanged = this._handleOutputDeviceChanged.bind(this)

    window.addEventListener("voice:join", this._onJoin)
    window.addEventListener("voice:force-disconnect", this._onForceDisconnect)
    window.addEventListener("voice:force-move", this._onForceMove)
    window.addEventListener("voice:server-mute", this._onServerMute)
    window.addEventListener("voice:server-deafen", this._onServerDeafen)
    window.addEventListener("beforeunload", this._onBeforeUnload)
    window.addEventListener("voice:output-volume-changed", this._onOutputVolumeChanged)
    window.addEventListener("voice:echo-cancellation-changed", this._onEchoCancellationChanged)
    window.addEventListener("voice:agc-changed", this._onAgcChanged)
    window.addEventListener("voice:input-device-changed", this._onInputDeviceChanged)
    window.addEventListener("voice:output-device-changed", this._onOutputDeviceChanged)

    // Auto-rejoin if we were in a voice channel before page refresh
    this._checkPendingRejoin()
  }

  disconnect() {
    this._initialized = false
    window.removeEventListener("voice:join", this._onJoin)
    window.removeEventListener("voice:force-disconnect", this._onForceDisconnect)
    window.removeEventListener("voice:force-move", this._onForceMove)
    window.removeEventListener("voice:server-mute", this._onServerMute)
    window.removeEventListener("voice:server-deafen", this._onServerDeafen)
    window.removeEventListener("beforeunload", this._onBeforeUnload)
    window.removeEventListener("voice:output-volume-changed", this._onOutputVolumeChanged)
    window.removeEventListener("voice:echo-cancellation-changed", this._onEchoCancellationChanged)
    window.removeEventListener("voice:agc-changed", this._onAgcChanged)
    window.removeEventListener("voice:input-device-changed", this._onInputDeviceChanged)
    window.removeEventListener("voice:output-device-changed", this._onOutputDeviceChanged)
    this._disconnectRoom()
  }

  // ─── Session persistence ─────────────────────────────────

  _saveSession() {
    if (!this.currentChannelId || !this.currentServerId) return
    sessionStorage.setItem(VOICE_SESSION_KEY, JSON.stringify({
      channelId: this.currentChannelId,
      serverId: this.currentServerId,
      muted: this._muted,
      deafened: this._deafened
    }))
  }

  _clearSession() {
    sessionStorage.removeItem(VOICE_SESSION_KEY)
  }

  async _checkPendingRejoin() {
    const raw = sessionStorage.getItem(VOICE_SESSION_KEY)
    if (!raw) return

    try {
      const session = JSON.parse(raw)
      if (!session.channelId || !session.serverId) return

      console.log("[VoiceChannel] Rejoining after page reload:", session.channelId)
      await this._joinChannel(session.channelId, session.serverId)

      // Restore mute/deafen state
      if (session.deafened) {
        this._deafened = true
        this._muted = true
        this.room.localParticipant.setMicrophoneEnabled(false)
        this._setRemoteVolumes(0)
        this._updateMuteIcon()
        this._updateDeafenIcon()
      } else if (session.muted) {
        this._muted = true
        this.room.localParticipant.setMicrophoneEnabled(false)
        this._updateMuteIcon()
      }
    } catch (err) {
      console.warn("[VoiceChannel] Rejoin after reload failed:", err)
      this._clearSession()
    }
  }

  // ─── Event handlers ────────────────────────────────────────

  async _handleJoin(e) {
    const { channelId, serverId } = e.detail
    if (!channelId || !serverId) return

    // Already in this channel
    if (this.room && this.currentChannelId === channelId) return

    // If in a different channel, disconnect first
    if (this.room) {
      await this._disconnectRoom()
    }

    try {
      await this._joinChannel(channelId, serverId)
    } catch (err) {
      console.error("[VoiceChannel] Join failed:", err)
      this._showError(err.message || "Failed to join voice channel")
      this._updateVoicePanelStatus("join")
    }
  }

  _handleForceDisconnect() {
    this._disconnectRoom()
  }

  async _handleForceMove(e) {
    const { toChannelId, toChannelName, voiceStateId } = e.detail
    // The backend already moved our voice state; we just need to reconnect
    // to the new LiveKit room
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    this.voiceStateId = voiceStateId
    this.currentChannelId = toChannelId

    if (this.hasChannelNameTarget) {
      this.channelNameTarget.textContent = toChannelName || "Voice"
    }

    // Re-join with a new token for the new channel
    try {
      await this._joinChannel(toChannelId, this.currentServerId)
    } catch (err) {
      console.error("[VoiceChannel] Force-move reconnect failed:", err)
    }
  }

  _handleOutputVolumeChanged(e) {
    const { volume } = e.detail
    if (!this._deafened) {
      this._setRemoteVolumes(volume / 100)
    }
  }

  // Returns the user's saved output volume as a 0-2 float (0-200% range)
  _getOutputGain() {
    const saved = parseInt(localStorage.getItem("voice-output-volume") ?? "100", 10)
    return Math.max(0, Math.min(2, saved / 100))
  }

  // Build audio capture constraints from stored preferences
  _audioCaptureOptions() {
    const deviceId = localStorage.getItem("voice-input-device")
    const opts = {
      autoGainControl: localStorage.getItem("voice-auto-gain-control") !== "false",
      echoCancellation: localStorage.getItem("voice-echo-cancellation") !== "false",
      noiseSuppression: true
    }
    if (deviceId && deviceId !== "default") {
      opts.deviceId = { ideal: deviceId }
    }
    return opts
  }

  // ─── Live settings handlers ──────────────────────────────────

  async _handleEchoCancellationChanged() {
    await this._republishMicWithCurrentSettings()
  }

  async _handleAgcChanged() {
    await this._republishMicWithCurrentSettings()
  }

  async _handleInputDeviceChanged(e) {
    if (!this.room) return
    try {
      const deviceId = e.detail.deviceId
      await this.room.switchActiveDevice("audioinput", deviceId === "default" ? "" : deviceId)
      if (!this._muted) this._setupLocalLevelMeter()
      console.log("[VoiceChannel] Switched input device:", deviceId)
    } catch (err) {
      console.warn("[VoiceChannel] Failed to switch input device:", err)
    }
  }

  async _handleOutputDeviceChanged(e) {
    if (!this.room) return
    try {
      const deviceId = e.detail.deviceId
      await this.room.switchActiveDevice("audiooutput", deviceId === "default" ? "" : deviceId)
      console.log("[VoiceChannel] Switched output device:", deviceId)
    } catch (err) {
      console.warn("[VoiceChannel] Failed to switch output device:", err)
    }
  }

  // Republish mic track with updated audio processing constraints (echo, AGC)
  async _republishMicWithCurrentSettings() {
    if (!this.room || this._muted) return
    try {
      await this.room.localParticipant.setMicrophoneEnabled(false)
      this._cleanupLocalLevelMeter()
      await this.room.localParticipant.setMicrophoneEnabled(true, this._audioCaptureOptions())
      this._setupLocalLevelMeter()
      console.log("[VoiceChannel] Republished mic with updated audio processing settings")
    } catch (err) {
      console.warn("[VoiceChannel] Failed to republish mic:", err)
    }
  }

  _handleServerMute(e) {
    const { serverMute } = e.detail
    if (serverMute && this.room) {
      this.room.localParticipant.setMicrophoneEnabled(false)
      this._muted = true
      this._updateMuteIcon()
    }
  }

  _handleServerDeafen(e) {
    const { serverDeaf } = e.detail
    if (serverDeaf) {
      this._deafened = true
      this._muted = true
      if (this.room) {
        this.room.localParticipant.setMicrophoneEnabled(false)
        this._setRemoteVolumes(0)
      }
      this._updateMuteIcon()
      this._updateDeafenIcon()
    }
  }

  // ─── Core join/leave ───────────────────────────────────────

  async _joinChannel(channelId, serverId) {
    this.currentChannelId = channelId
    this.currentServerId = serverId

    this._updateVoicePanelStatus("connecting")

    // Request token from backend
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    const response = await fetch(`/servers/${serverId}/voice/join/${channelId}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken
      }
    })

    const data = await response.json()

    if (!response.ok) {
      throw new Error(data.error || "Failed to join voice channel")
    }

    this.voiceStateId = data.voice_state_id
    this.currentProviderId = data.provider_id

    // Create and connect LiveKit room
    this.room = new Room({
      adaptiveStream: true,
      dynacast: true,
      audioCaptureDefaults: this._audioCaptureOptions()
    })

    this._setupRoomEvents()

    await this.room.connect(data.livekit_url, data.token)
    console.log("[VoiceChannel] Connected to LiveKit, enabling mic...")
    try {
      await this.room.localParticipant.setMicrophoneEnabled(true, this._audioCaptureOptions())
      console.log("[VoiceChannel] Mic enabled successfully")
    } catch (micErr) {
      console.error("[VoiceChannel] Failed to enable mic:", micErr)
      // Retry with no constraints as fallback
      try {
        await this.room.localParticipant.setMicrophoneEnabled(true)
        console.log("[VoiceChannel] Mic enabled with default constraints")
      } catch (retryErr) {
        console.error("[VoiceChannel] Mic retry also failed:", retryErr)
      }
    }

    this._muted = false
    this._deafened = false

    // Render any participants already in the room (joined before us)
    for (const participant of this.room.remoteParticipants.values()) {
      this._ensureParticipantUI(participant)
      // Attach any already-published video tracks
      for (const pub of participant.videoTrackPublications.values()) {
        if (pub.track && pub.isSubscribed) {
          if (pub.source === Track.Source.ScreenShare) {
            this._showScreenSharePlaceholder(pub.track, participant)
          } else if (pub.source === Track.Source.Camera) {
            this._attachCameraTrack(pub.track, participant)
          }
        }
      }
    }

    // Attach local level meter (cloned track) + start the level loop
    this._setupLocalLevelMeter()
    this._startLevelLoop()

    // Persist session for reconnect on refresh
    this._saveSession()

    // Show controls bar
    this._showControlsBar(data.channel_name || "Voice")
    this._updateVoicePanelStatus("connected")
  }

  async _disconnectRoom() {
    this._userInitiatedDisconnect = true
    this._stopLevelLoop()
    this._cleanupLocalLevelMeter()

    // Clear persisted session — explicit disconnect should not auto-rejoin
    this._clearSession()

    if (this.room) {
      this.room.disconnect()
      this.room = null
    }

    // Clean up audio elements, gain nodes, and analysers
    this._audioElements.forEach(el => el.remove())
    this._audioElements.clear()
    this._gainNodes?.clear()
    this._analysers.clear()
    if (this._audioContext) { this._audioContext.close().catch(() => {}); this._audioContext = null }

    // Clean up video elements
    this._videoElements.forEach(({ element, track }) => {
      try { track.detach() } catch (_) {}
      element.remove()
    })
    this._videoElements.clear()
    this._cameraElements.forEach(({ video, track }) => {
      try { track.detach() } catch (_) {}
      video.remove()
    })
    this._cameraElements.clear()
    this._pendingScreenShares.forEach(({ placeholder }) => placeholder?.remove())
    this._pendingScreenShares.clear()
    this._pendingScreenShareAudio.clear()
    this._screenShareAudioElements.forEach(el => el.remove())
    this._screenShareAudioElements.clear()
    if (this._localPreviewVisHandler) {
      document.removeEventListener("visibilitychange", this._localPreviewVisHandler)
      this._localPreviewVisHandler = null
    }
    this._screenShareTrack = null

    // Notify backend
    if (this.currentServerId) {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      try {
        await fetch(`/servers/${this.currentServerId}/voice/leave`, {
          method: "DELETE",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken
          }
        })
      } catch (e) {
        // Best effort
      }
    }

    this.currentChannelId = null
    this.currentServerId = null
    this.voiceStateId = null
    this.currentProviderId = null
    this._muted = false
    this._deafened = false
    this._screenSharing = false
    this._cameraOn = false
    this._userInitiatedDisconnect = false
    this._reconnecting = false

    // Hide controls bar
    this._hideControlsBar()
    this._updateVoicePanelStatus("join")
  }

  _handleBeforeUnload() {
    // Save session so we can rejoin after refresh.
    // Don't send leave — the join endpoint cleans up stale state,
    // and sessionStorage auto-clears on tab close.
    this._saveSession()
  }

  // ─── Room event handling ───────────────────────────────────

  _setupRoomEvents() {
    const room = this.room

    room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
      if (track.kind === Track.Kind.Audio) {
        if (publication.source === Track.Source.ScreenShareAudio) {
          // Store screen share audio — only attached when user opts in
          this._pendingScreenShareAudio.set(participant.identity, { track, participant })
        } else {
          this._attachAudioTrack(track, participant)
        }
      } else if (track.kind === Track.Kind.Video) {
        if (publication.source === Track.Source.ScreenShare) {
          this._showScreenSharePlaceholder(track, participant)
        } else if (publication.source === Track.Source.Camera) {
          this._attachCameraTrack(track, participant)
        }
      }
    })

    room.on(RoomEvent.TrackUnsubscribed, (track, publication, participant) => {
      if (track.kind === Track.Kind.Audio) {
        if (publication.source === Track.Source.ScreenShareAudio) {
          this._pendingScreenShareAudio.delete(participant.identity)
          this._detachScreenShareAudio(participant.identity)
        } else {
          this._detachAudioTrack(participant)
        }
      } else if (track.kind === Track.Kind.Video) {
        if (publication.source === Track.Source.ScreenShare) {
          this._removePendingScreenShare(participant.identity)
          this._detachScreenShareTrack(participant)
        } else if (publication.source === Track.Source.Camera) {
          this._detachCameraTrack(participant)
        }
      }
    })

    // Handle local track published (for local screen share / camera preview)
    room.on(RoomEvent.LocalTrackPublished, (publication, participant) => {
      if (publication.source === Track.Source.ScreenShare && publication.track) {
        this._showLocalScreenSharePreview(publication.track, participant)
      } else if (publication.source === Track.Source.Camera && publication.track) {
        this._showLocalCameraPreview(publication.track, participant)
      }
    })

    // Handle local track unpublished (browser "Stop sharing" button, etc.)
    room.on(RoomEvent.LocalTrackUnpublished, (publication, participant) => {
      if (publication.source === Track.Source.ScreenShare) {
        if (this._screenSharing) {
          this._screenSharing = false
          this._screenShareTrack = null
          this._detachScreenShareTrack(participant)
          this._updateScreenShareIcon()
          this._patchState("screen_share", { screen_share: false })
        }
      } else if (publication.source === Track.Source.Camera) {
        if (this._cameraOn) {
          this._cameraOn = false
          this._detachCameraTrack(participant)
          this._updateCameraIcon()
          this._patchState("video", { video: false })
        }
      }
    })

    // LiveKit auto-reconnects on temporary network drops.
    room.on(RoomEvent.Reconnecting, () => {
      console.warn("[VoiceChannel] Connection lost, reconnecting...")
      this._updateVoicePanelStatus("reconnecting")
      this._updateControlsBarStatus("reconnecting")
    })

    room.on(RoomEvent.Reconnected, () => {
      console.log("[VoiceChannel] Reconnected successfully")
      this._updateVoicePanelStatus("connected")
      this._updateControlsBarStatus("connected")
    })

    // Disconnected fires only after LiveKit's internal reconnection gives up.
    room.on(RoomEvent.Disconnected, (reason) => {
      if (this._userInitiatedDisconnect) return
      if (reason !== DisconnectReason.CLIENT_INITIATED) {
        console.warn("[VoiceChannel] Disconnected after reconnect attempts:", reason)
        this._attemptFailover()
      }
    })

    room.on(RoomEvent.ParticipantConnected, (participant) => {
      this._ensureParticipantUI(participant)
    })

    room.on(RoomEvent.ParticipantDisconnected, (participant) => {
      this._detachAudioTrack(participant)
      this._removePendingScreenShare(participant.identity)
      this._pendingScreenShareAudio.delete(participant.identity)
      this._detachScreenShareAudio(participant.identity)
      this._removeParticipantUI(participant)
    })
  }

  _attachAudioTrack(track, participant) {
    const el = track.attach()
    el.id = `voice-audio-${participant.identity}`
    el.style.display = "none"
    document.body.appendChild(el)
    this._audioElements.set(participant.identity, el)

    // Set up Web Audio gain node for amplification beyond 100%
    try {
      if (!this._audioContext) this._audioContext = new AudioContext()
      if (this._audioContext.state === "suspended") this._audioContext.resume()
      const source = this._audioContext.createMediaElementSource(el)
      const gainNode = this._audioContext.createGain()

      // Tap an AnalyserNode for client-side level metering
      const analyser = this._audioContext.createAnalyser()
      analyser.fftSize = 256
      analyser.smoothingTimeConstant = 0.3
      source.connect(analyser)
      analyser.connect(gainNode)
      gainNode.connect(this._audioContext.destination)

      this._gainNodes = this._gainNodes || new Map()
      this._gainNodes.set(participant.identity, gainNode)
      this._analysers.set(participant.identity, { analyser })
    } catch (e) {
      // Fallback: no gain node / analyser, volume capped at 100%
    }

    if (this._deafened) {
      this._setParticipantVolume(participant.identity, 0)
    } else {
      this._setParticipantVolume(participant.identity, this._getOutputGain())
    }
  }

  _detachAudioTrack(participant) {
    const el = this._audioElements.get(participant.identity)
    if (el) {
      el.remove()
      this._audioElements.delete(participant.identity)
    }
    this._gainNodes?.delete(participant.identity)
    this._analysers.delete(participant.identity)
  }

  // ─── Client-side audio level metering ───────────────────────

  // Clone the LiveKit mic track and attach an AnalyserNode for instant
  // client-side level detection. The clone reads the same hardware source
  // so there are no false positives, and it doesn't interfere with LiveKit's
  // WebRTC PeerConnection since it's an independent MediaStreamTrack.
  async _setupLocalLevelMeter() {
    this._cleanupLocalLevelMeter()
    const pub = this.room?.localParticipant?.getTrackPublication(Track.Source.Microphone)
    const mst = pub?.track?.mediaStreamTrack
    if (!mst) return

    try {
      const clone = mst.clone()
      const ctx = new AudioContext()
      if (ctx.state === "suspended") await ctx.resume()
      const source = ctx.createMediaStreamSource(new MediaStream([clone]))
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 256
      analyser.smoothingTimeConstant = 0.3
      source.connect(analyser)
      // Keep graph alive: analyser → silent gain → destination
      const silentGain = ctx.createGain()
      silentGain.gain.value = 0
      analyser.connect(silentGain)
      silentGain.connect(ctx.destination)

      this._localMeter = { clone, ctx, source, analyser }
    } catch (e) {
      console.warn("[VoiceChannel] Local level meter setup failed:", e)
    }
  }

  _cleanupLocalLevelMeter() {
    if (!this._localMeter) return
    const { clone, ctx, source } = this._localMeter
    try { source.disconnect() } catch (_) {}
    clone.stop()
    ctx.close().catch(() => {})
    this._localMeter = null
  }

  _startLevelLoop() {
    if (this._levelRafId) return
    const SPEAK_THRESHOLD = 0.07  // minimum level (0-1) to count as speaking
    const SMOOTH = 0.35           // exponential smoothing (0 = instant, 1 = frozen)
    this._smoothedLevels = new Map()
    let debugCounter = 0

    const tick = () => {
      this._levelRafId = requestAnimationFrame(tick)
      if (!this.room) return

      const localId = this.room.localParticipant?.identity
      const localSuppressed = this._muted
      const levels = new Map()

      // ── Local participant: read from cloned track's AnalyserNode ──
      if (localId && this._localMeter) {
        let localLevel = 0
        if (!localSuppressed) {
          const { analyser } = this._localMeter
          const dataArray = new Uint8Array(analyser.fftSize)
          analyser.getByteTimeDomainData(dataArray)
          let sumSq = 0
          for (let i = 0; i < dataArray.length; i++) {
            const s = (dataArray[i] - 128) / 128
            sumSq += s * s
          }
          localLevel = Math.sqrt(sumSq / dataArray.length)
        }
        const prev = this._smoothedLevels.get(localId) || 0
        const smoothed = localSuppressed
          ? prev * SMOOTH  // decay to zero
          : prev * SMOOTH + localLevel * (1 - SMOOTH)
        this._smoothedLevels.set(localId, smoothed)
        levels.set(localId, smoothed)
      }

      // ── Remote participants: read from AnalyserNode chain ──
      for (const [identity, { analyser }] of this._analysers) {
        if (identity === localId) continue
        // Fresh array each frame (Firefox zeroes pre-allocated TypedArrays
        // stored as Map properties when passed to analyser methods).
        const dataArray = new Uint8Array(analyser.fftSize)
        analyser.getByteTimeDomainData(dataArray)
        // RMS: byte 128 = silence, deviation from center = amplitude
        let sumSq = 0
        for (let i = 0; i < dataArray.length; i++) {
          const s = (dataArray[i] - 128) / 128
          sumSq += s * s
        }
        const level = Math.sqrt(sumSq / dataArray.length)
        // Exponential smoothing for fluid visualizer feel
        const prev = this._smoothedLevels.get(identity) || 0
        const smoothed = prev * SMOOTH + level * (1 - SMOOTH)
        this._smoothedLevels.set(identity, smoothed)
        levels.set(identity, smoothed)
      }

      // Debug: log every ~3 seconds
      if (++debugCounter % 180 === 0) {
        const dbg = []
        for (const [id, lvl] of levels) dbg.push(`${id.slice(0,8)}=${lvl.toFixed(3)}`)
        console.log("[VoiceLevel]", dbg.join(", ") || "(none)", `| speaking=${document.querySelectorAll(".voice-speaking").length}`)
      }

      this._applyLevelsToDOM(levels, SPEAK_THRESHOLD)
    }
    this._levelRafId = requestAnimationFrame(tick)
  }

  _stopLevelLoop() {
    if (this._levelRafId) {
      cancelAnimationFrame(this._levelRafId)
      this._levelRafId = null
    }
    this._smoothedLevels = null
    // Clear all speaking states from DOM
    document.querySelectorAll(".voice-speaking").forEach(el => {
      el.classList.remove("voice-speaking")
      el.style.removeProperty("--audio-level")
    })
  }

  _applyLevelsToDOM(levels, threshold) {
    // Sidebar participant rows
    document.querySelectorAll("[data-voice-user-id]").forEach(row => {
      const id = row.dataset.voiceUserId
      const level = levels.get(id)
      if (level !== undefined && level > threshold) {
        row.classList.add("voice-speaking")
        // sqrt curve boosts quieter levels for perceptual responsiveness
        const normalized = Math.sqrt(Math.min((level - threshold) / 0.20, 1))
        row.style.setProperty("--audio-level", normalized.toFixed(3))
      } else {
        row.classList.remove("voice-speaking")
        row.style.removeProperty("--audio-level")
      }
    })

    // Voice cards in main view
    document.querySelectorAll("[data-voice-participant-id]").forEach(card => {
      const id = card.dataset.voiceParticipantId
      const level = levels.get(id)
      if (level !== undefined && level > threshold) {
        card.classList.add("voice-speaking")
        const normalized = Math.sqrt(Math.min((level - threshold) / 0.20, 1))
        card.style.setProperty("--audio-level", normalized.toFixed(3))
      } else {
        card.classList.remove("voice-speaking")
        card.style.removeProperty("--audio-level")
      }
    })
  }

  // ─── Auto-failover ──────────────────────────────────────────

  async _attemptFailover() {
    if (this._reconnecting || !this.currentChannelId || !this.currentServerId) {
      this._disconnectRoom()
      return
    }

    this._reconnecting = true
    const failedProviderId = this.currentProviderId

    this._updateVoicePanelStatus("reconnecting")

    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch(`/servers/${this.currentServerId}/voice/rejoin/${this.currentChannelId}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ exclude_provider: failedProviderId })
      })

      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.error || "All voice providers are offline")
      }

      // Clean up old room
      if (this.room) {
        this.room.disconnect()
        this.room = null
      }
      this._audioElements.forEach(el => el.remove())
      this._audioElements.clear()

      // Connect to new provider
      this.currentProviderId = data.provider_id
      this.room = new Room({
        adaptiveStream: true,
        dynacast: true,
        audioCaptureDefaults: this._audioCaptureOptions()
      })

      this._setupRoomEvents()
      await this.room.connect(data.livekit_url, data.token)
      await this.room.localParticipant.setMicrophoneEnabled(!this._muted, this._audioCaptureOptions())
      if (!this._muted) this._setupLocalLevelMeter()

      this._saveSession()
      this._updateVoicePanelStatus("connected")
      this._reconnecting = false
      console.log("[VoiceChannel] Failover successful, new provider:", data.provider_id)
    } catch (err) {
      console.error("[VoiceChannel] Failover failed:", err)
      this._reconnecting = false
      this._showError(err.message || "All voice providers are offline")
      this._disconnectRoom()
    }
  }

  // Updates the voice panel status area (bottom of show_voice view).
  // States: "join" (show join button), "connecting", "connected", "reconnecting"
  _updateVoicePanelStatus(state) {
    const panel = document.querySelector("[data-voice-panel-status]")
    if (!panel) return

    const channelId = panel.dataset.voicePanelChannel
    const serverId = panel.dataset.voicePanelServer

    // Only update if this panel is for the channel we're in (or joining)
    if (this.currentChannelId && channelId !== this.currentChannelId) return

    const statusMap = {
      join: `<button type="button"
               class="px-6 py-2.5 bg-green-600 hover:bg-green-500 text-white font-semibold rounded-full transition flex items-center gap-2 cursor-pointer text-sm"
               data-voice-status="join"
               onclick="window.dispatchEvent(new CustomEvent('voice:join', { detail: { channelId: '${channelId}', serverId: '${serverId}' } }))">
               <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-3.536-2.464a5 5 0 010-7.072"/></svg>
               Join Voice
             </button>`,
      connecting: `<div class="flex items-center gap-2" data-voice-status="connecting">
                     <div class="animate-spin w-3.5 h-3.5 border-2 border-accent border-t-transparent rounded-full"></div>
                     <p class="text-gray-400 text-sm font-medium">Connecting...</p>
                   </div>`,
      connected: `<div class="flex items-center gap-2" data-voice-status="connected">
                    <div class="w-2 h-2 rounded-full bg-green-400"></div>
                    <p class="text-green-400 text-sm font-medium">Voice Connected</p>
                  </div>`,
      reconnecting: `<div class="flex items-center gap-2" data-voice-status="reconnecting">
                       <div class="animate-spin w-3.5 h-3.5 border-2 border-yellow-400 border-t-transparent rounded-full"></div>
                       <p class="text-yellow-400 text-sm font-medium">Reconnecting...</p>
                     </div>`
    }

    panel.innerHTML = statusMap[state] || statusMap.join
  }

  // ─── Control bar actions ───────────────────────────────────

  async toggleMute() {
    if (!this.room) return
    this._muted = !this._muted

    // Undeafen if unmuting
    if (!this._muted && this._deafened) {
      this._deafened = false
      this._setRemoteVolumes(this._getOutputGain())
      this._updateDeafenIcon()
      this._patchState("self_deafen", { deafened: false })
    }

    // Update UI immediately so it never gets stuck
    this._updateMuteIcon()
    this._updateSelfVoiceIndicators()

    try {
      await this.room.localParticipant.setMicrophoneEnabled(!this._muted)
      if (this._muted) {
        this._cleanupLocalLevelMeter()
      } else {
        this._setupLocalLevelMeter()
      }
    } catch (e) {
      console.warn("[VoiceChannel] toggleMute setMicrophoneEnabled failed:", e)
    }
    this._patchState("self_mute", { muted: this._muted })
    this._saveSession()
  }

  async toggleDeafen() {
    if (!this.room) return
    this._deafened = !this._deafened

    if (this._deafened) {
      // Deafen → also mute
      this._muted = true
      this.room.localParticipant.setMicrophoneEnabled(false)
      this._cleanupLocalLevelMeter()
      this._setRemoteVolumes(0)
    } else {
      // Undeafen → unmute and restore volume to saved gain
      this._muted = false
      this._setRemoteVolumes(this._getOutputGain())
      try {
        await this.room.localParticipant.setMicrophoneEnabled(true)
        this._setupLocalLevelMeter()
      } catch (e) {
        console.warn("[VoiceChannel] toggleDeafen setMicrophoneEnabled failed:", e)
      }
    }

    // Update UI immediately so it never gets stuck
    this._updateMuteIcon()
    this._updateDeafenIcon()
    this._updateSelfVoiceIndicators()
    this._patchState("self_deafen", { deafened: this._deafened })
    this._saveSession()
  }

  toggleScreenShare() {
    if (!this.room) return
    if (this._screenSharing) {
      this._stopScreenShare()
    } else {
      this._showScreenSharePicker()
    }
  }

  async toggleCamera() {
    if (!this.room) return
    const turningOn = !this._cameraOn
    this._cameraOn = turningOn
    this._updateCameraIcon()

    if (!turningOn) {
      // Detach video element BEFORE disabling the track to avoid frozen frame
      const localId = this.room.localParticipant?.identity
      if (localId) this._detachCameraTrack({ identity: localId })
    }

    try {
      await this.room.localParticipant.setCameraEnabled(turningOn)
    } catch (e) {
      console.warn("[VoiceChannel] toggleCamera failed:", e)
      this._cameraOn = false
      this._updateCameraIcon()
      return
    }
    this._patchState("video", { video: this._cameraOn })
  }

  disconnectVoice() {
    this._disconnectRoom()
  }

  // ─── Screen Share ─────────────────────────────────────────

  _showScreenSharePicker() {
    const tpl = document.getElementById("tpl-screen-share-picker")
    if (!tpl) return
    const overlay = tpl.content.cloneNode(true).querySelector("[data-ss-picker-overlay]")
    document.body.appendChild(overlay)

    // Load saved settings from localStorage
    const savedRes = localStorage.getItem("ss-resolution") || "1080"
    const savedFps = localStorage.getItem("ss-framerate") || "30"
    const savedContent = localStorage.getItem("ss-content-type") || "smoothness"
    const savedAudio = localStorage.getItem("ss-audio") !== "false"

    // Wire pill group toggles
    overlay.querySelectorAll("[data-ss-group]").forEach(group => {
      const groupName = group.dataset.ssGroup
      const defaultVal = { resolution: savedRes, frameRate: savedFps, contentType: savedContent }[groupName]
      group.querySelectorAll(".ss-pill").forEach(pill => {
        if (pill.dataset.value === defaultVal) pill.classList.add("ss-pill-active")
        pill.addEventListener("click", () => {
          group.querySelectorAll(".ss-pill").forEach(p => p.classList.remove("ss-pill-active"))
          pill.classList.add("ss-pill-active")
        })
      })
    })

    // Wire audio toggle
    const audioToggle = overlay.querySelector("[data-ss-audio-toggle]")
    if (savedAudio) audioToggle.classList.add("ss-audio-on")
    audioToggle.addEventListener("click", () => {
      audioToggle.classList.toggle("ss-audio-on")
    })

    // Close/Cancel
    const close = () => overlay.remove()
    overlay.querySelector("[data-ss-close]").addEventListener("click", close)
    overlay.querySelector("[data-ss-cancel]").addEventListener("click", close)
    overlay.addEventListener("click", (e) => { if (e.target === overlay) close() })

    // Go Live
    overlay.querySelector("[data-ss-go-live]").addEventListener("click", () => {
      const getActive = (groupName) => {
        const active = overlay.querySelector(`[data-ss-group="${groupName}"] .ss-pill-active`)
        return active?.dataset.value
      }
      const settings = {
        resolution: parseInt(getActive("resolution") || "1080", 10),
        frameRate: parseInt(getActive("frameRate") || "30", 10),
        contentType: getActive("contentType") || "smoothness",
        audio: audioToggle.classList.contains("ss-audio-on")
      }

      // Save to localStorage
      localStorage.setItem("ss-resolution", String(settings.resolution))
      localStorage.setItem("ss-framerate", String(settings.frameRate))
      localStorage.setItem("ss-content-type", settings.contentType)
      localStorage.setItem("ss-audio", String(settings.audio))

      close()
      this._startScreenShare(settings)
    })
  }

  async _startScreenShare(settings) {
    if (!this.room || this._screenSharing) return

    const captureOptions = {
      resolution: {
        width: { ideal: Math.round(settings.resolution * 16 / 9) },
        height: { ideal: settings.resolution }
      },
      contentHint: settings.contentType === "clarity" ? "detail" : "motion",
      audio: settings.audio
    }
    if (settings.contentType === "clarity") {
      captureOptions.resolution.frameRate = { ideal: Math.min(settings.frameRate, 15) }
    } else {
      captureOptions.resolution.frameRate = { ideal: settings.frameRate }
    }

    try {
      await this.room.localParticipant.setScreenShareEnabled(true, captureOptions)
      this._screenSharing = true
      this._updateScreenShareIcon()
      this._patchState("screen_share", { screen_share: true })
    } catch (e) {
      // User cancelled the browser picker or error
      console.warn("[VoiceChannel] Screen share failed:", e)
    }
  }

  async _stopScreenShare() {
    if (!this.room) return
    try {
      await this.room.localParticipant.setScreenShareEnabled(false)
    } catch (e) {
      console.warn("[VoiceChannel] Stop screen share failed:", e)
    }
    this._screenSharing = false
    this._screenShareTrack = null
    // Remove local preview
    const localId = this.room.localParticipant?.identity
    if (localId) this._detachScreenShareTrack({ identity: localId })
    this._updateScreenShareIcon()
    this._patchState("screen_share", { screen_share: false })
  }

  _updateScreenShareIcon() {
    if (!this.hasScreenShareBtnTarget) return
    const btn = this.screenShareBtnTarget
    if (this._screenSharing) {
      btn.classList.add("text-green-400")
      btn.classList.remove("text-gray-300")
    } else {
      btn.classList.remove("text-green-400")
      btn.classList.add("text-gray-300")
    }
  }

  _updateCameraIcon() {
    if (!this.hasCameraBtnTarget) return
    const btn = this.cameraBtnTarget
    if (this._cameraOn) {
      btn.classList.add("text-green-400")
      btn.classList.remove("text-gray-300")
    } else {
      btn.classList.remove("text-green-400")
      btn.classList.add("text-gray-300")
    }
  }

  // ─── Video track attach/detach ────────────────────────────

  _getParticipantMeta(participant) {
    let meta = {}
    try { meta = JSON.parse(participant.metadata || "{}") } catch (_) {}
    return {
      username: participant.name || participant.identity?.slice(0, 8) || "Unknown",
      avatarUrl: meta.avatar_url || ""
    }
  }

  _attachScreenShareTrack(track, participant) {
    const identity = participant.identity
    // Avoid duplicates
    if (this._videoElements.has(identity)) return

    const { username } = this._getParticipantMeta(participant)
    const container = document.querySelector("[data-voice-participant-grid]")
    if (!container) return

    const preview = document.createElement("div")
    preview.className = "voice-screen-preview"
    preview.dataset.screenShareIdentity = identity

    const video = track.attach()
    video.className = "voice-screen-video"
    preview.appendChild(video)

    const badge = document.createElement("div")
    badge.className = "voice-live-badge"
    badge.textContent = "LIVE"
    preview.appendChild(badge)

    const label = document.createElement("div")
    label.className = "voice-screen-label"
    label.textContent = `${username}'s screen`
    preview.appendChild(label)

    // Click to toggle between card (inside grid) and theatre (above grid)
    preview.addEventListener("click", () => {
      this._toggleVideoTheatre(identity)
    })

    // Start in card format inside the grid (users opt in to theatre)
    preview.classList.add("voice-screen-preview--card")
    const grid = container.querySelector(".voice-grid")
    if (grid) {
      grid.appendChild(preview)
    } else {
      container.appendChild(preview)
    }

    this._videoElements.set(identity, { element: preview, track, theatre: false })
  }

  _detachScreenShareTrack(participant) {
    const identity = participant.identity
    const entry = this._videoElements.get(identity)
    if (entry) {
      const { element, track } = entry
      // Properly detach the LiveKit track so no frozen frame remains
      try { track.detach() } catch (_) {}
      element.remove()
      this._videoElements.delete(identity)
    }
    // Clean up local preview visibility handler
    if (this._localPreviewVisHandler && identity === this.room?.localParticipant?.identity) {
      document.removeEventListener("visibilitychange", this._localPreviewVisHandler)
      this._localPreviewVisHandler = null
    }
    // Clean up screen share audio if user was watching
    this._detachScreenShareAudio(identity)
  }

  _showLocalScreenSharePreview(track, participant) {
    this._attachScreenShareTrack(track, participant)

    // Pause local preview when the user tabs away to save resources
    const identity = participant.identity
    this._localPreviewVisHandler = () => {
      const entry = this._videoElements.get(identity)
      if (!entry) return
      const video = entry.element.querySelector("video")
      if (!video) return

      if (document.hidden) {
        video.pause()
        let overlay = entry.element.querySelector(".voice-screen-paused-overlay")
        if (!overlay) {
          overlay = document.createElement("div")
          overlay.className = "voice-screen-paused-overlay"
          overlay.innerHTML = `
            <svg class="w-8 h-8 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
            </svg>
            <span class="text-sm text-gray-300 font-medium text-center px-4">You are still streaming</span>
            <span class="text-xs text-gray-500 text-center px-4">Preview paused to save resources</span>
          `
          entry.element.appendChild(overlay)
        }
        overlay.style.display = ""
      } else {
        video.play().catch(() => {})
        const overlay = entry.element.querySelector(".voice-screen-paused-overlay")
        if (overlay) overlay.style.display = "none"
      }
    }
    document.addEventListener("visibilitychange", this._localPreviewVisHandler)
  }

  _showScreenSharePlaceholder(track, participant) {
    const identity = participant.identity
    if (this._pendingScreenShares.has(identity) || this._videoElements.has(identity)) return

    const { username } = this._getParticipantMeta(participant)
    const container = document.querySelector("[data-voice-participant-grid]")
    if (!container) return

    const placeholder = document.createElement("div")
    placeholder.className = "voice-screen-placeholder voice-screen-preview--card"
    placeholder.dataset.screenShareIdentity = identity

    placeholder.innerHTML = `
      <svg class="w-10 h-10 text-gray-400 mb-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
      </svg>
      <span class="text-sm text-gray-300 font-medium">${this._escapeHtml(username)} is streaming</span>
      <button class="voice-watch-btn">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"/>
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
        </svg>
        Watch Stream
      </button>
    `

    placeholder.querySelector(".voice-watch-btn").addEventListener("click", (e) => {
      e.stopPropagation()
      this._watchScreenShare(identity)
    })

    const grid = container.querySelector(".voice-grid")
    if (grid) {
      grid.appendChild(placeholder)
    } else {
      container.appendChild(placeholder)
    }

    this._pendingScreenShares.set(identity, { track, participant, placeholder })
  }

  _watchScreenShare(identity) {
    const pending = this._pendingScreenShares.get(identity)
    if (!pending) return

    const { track, participant, placeholder } = pending
    placeholder.remove()
    this._pendingScreenShares.delete(identity)

    // Attach the video track
    this._attachScreenShareTrack(track, participant)

    // Attach any pending screen share audio
    const audioEntry = this._pendingScreenShareAudio.get(identity)
    if (audioEntry) {
      const el = audioEntry.track.attach()
      el.id = `voice-ss-audio-${identity}`
      el.style.display = "none"
      document.body.appendChild(el)
      this._screenShareAudioElements.set(identity, el)
      this._pendingScreenShareAudio.delete(identity)
    }
  }

  _removePendingScreenShare(identity) {
    const pending = this._pendingScreenShares.get(identity)
    if (pending) {
      pending.placeholder.remove()
      this._pendingScreenShares.delete(identity)
    }
  }

  _detachScreenShareAudio(identity) {
    const el = this._screenShareAudioElements.get(identity)
    if (el) {
      el.remove()
      this._screenShareAudioElements.delete(identity)
    }
  }

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  // Toggle screen share between theatre (large, above grid) and card (inside grid)
  _toggleVideoTheatre(identity) {
    const entry = this._videoElements.get(identity)
    if (!entry) return
    const { element } = entry
    const container = document.querySelector("[data-voice-participant-grid]")
    if (!container) return
    const grid = container.querySelector(".voice-grid")
    if (!grid) return

    if (entry.theatre) {
      // Collapse to card: move into the grid, apply card sizing
      element.classList.add("voice-screen-preview--card")
      grid.prepend(element)
      entry.theatre = false
    } else {
      // Expand to theatre: move above the grid, remove card sizing
      element.classList.remove("voice-screen-preview--card")
      container.insertBefore(element, grid)
      entry.theatre = true
    }
  }

  _attachCameraTrack(track, participant) {
    const identity = participant.identity
    // Avoid duplicates
    if (this._cameraElements.has(identity)) return

    const card = document.querySelector(`[data-voice-participant-id="${identity}"]`)
    if (!card) return

    const inner = card.querySelector(".voice-card-inner")
    if (!inner) return

    const video = track.attach()
    video.className = "voice-camera-video"
    video.dataset.cameraIdentity = identity
    inner.appendChild(video)

    // Hide the avatar
    const avatarWrapper = inner.querySelector(".voice-avatar-wrapper")
    if (avatarWrapper) avatarWrapper.style.display = "none"

    this._cameraElements.set(identity, { video, track })
  }

  _detachCameraTrack(participant) {
    const identity = participant.identity
    const entry = this._cameraElements.get(identity)
    if (entry) {
      const { video, track } = entry
      // Properly detach the LiveKit track so no frozen frame remains
      try { track.detach() } catch (_) {}
      video.remove()
      this._cameraElements.delete(identity)
    }

    // Restore avatar
    const card = document.querySelector(`[data-voice-participant-id="${identity}"]`)
    if (card) {
      const avatarWrapper = card.querySelector(".voice-avatar-wrapper")
      if (avatarWrapper) avatarWrapper.style.display = ""
    }
  }

  _showLocalCameraPreview(track, participant) {
    this._attachCameraTrack(track, participant)
  }

  // ─── UI helpers ────────────────────────────────────────────

  _showControlsBar(channelName) {
    if (this.hasControlsBarTarget) {
      this.controlsBarTarget.classList.remove("hidden")
    }
    if (this.hasChannelNameTarget) {
      this.channelNameTarget.textContent = channelName
    }
    this._updateControlsBarStatus("connected")
    this._updateMuteIcon()
    this._updateDeafenIcon()
  }

  _updateControlsBarStatus(state) {
    if (!this.hasStatusTextTarget) return
    const el = this.statusTextTarget
    if (state === "reconnecting") {
      el.textContent = "Reconnecting..."
      el.classList.remove("text-green-500")
      el.classList.add("text-yellow-400")
    } else {
      el.textContent = "Voice Connected"
      el.classList.remove("text-yellow-400")
      el.classList.add("text-green-500")
    }
  }

  _hideControlsBar() {
    if (this.hasControlsBarTarget) {
      this.controlsBarTarget.classList.add("hidden")
    }
  }

  _updateMuteIcon() {
    if (!this.hasMuteBtnTarget) return
    const btn = this.muteBtnTarget
    if (this._muted) {
      btn.classList.add("text-red-400")
      btn.classList.remove("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2" stroke-linecap="round"/></svg>'
    } else {
      btn.classList.remove("text-red-400")
      btn.classList.add("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/></svg>'
    }
  }

  _updateDeafenIcon() {
    if (!this.hasDeafenBtnTarget) return
    const btn = this.deafenBtnTarget
    if (this._deafened) {
      btn.classList.add("text-red-400")
      btn.classList.remove("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>'
    } else {
      btn.classList.remove("text-red-400")
      btn.classList.add("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M18.364 5.636a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/></svg>'
    }
  }

  _setRemoteVolumes(gain) {
    this._audioElements.forEach((el, identity) => {
      this._setParticipantVolume(identity, gain)
    })
  }

  _setParticipantVolume(identity, gain) {
    const gainNode = this._gainNodes?.get(identity)
    if (gainNode) {
      // With GainNode: set el.volume=1, use gain for amplification
      const el = this._audioElements.get(identity)
      if (el) el.volume = 1
      gainNode.gain.value = gain
    } else {
      // Fallback: clamp to 0-1
      const el = this._audioElements.get(identity)
      if (el) el.volume = Math.min(1, Math.max(0, gain))
    }
  }

  _updateSelfVoiceIndicators() {
    const currentUserId = document.body.dataset.currentUserId
    if (!currentUserId) return

    // Update sidebar participant row icons for self
    const selfRow = document.querySelector(`[data-voice-user-id="${currentUserId}"]`)
    if (selfRow) {
      selfRow.querySelectorAll(".voice-mute-icon, .voice-deaf-icon").forEach(el => el.remove())
      const nameSpan = selfRow.querySelector("span")
      if (this._muted && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-mute-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>')
      }
      if (this._deafened && nameSpan) {
        nameSpan.insertAdjacentHTML("afterend", '<svg class="voice-deaf-icon w-3 h-3 text-gray-500 ml-1 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636"/></svg>')
      }
    }

    // Update main voice view card for self
    const selfCard = document.querySelector(`[data-voice-participant-id="${currentUserId}"]`)
    if (selfCard) {
      const existingIcons = selfCard.querySelector(".voice-status-icons")
      if (existingIcons) existingIcons.remove()

      if (this._muted || this._deafened) {
        let badgesHtml = ""
        if (this._muted) {
          badgesHtml += '<div class="voice-status-badge"><svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2.5" stroke-linecap="round"/></svg></div>'
        }
        if (this._deafened) {
          badgesHtml += '<div class="voice-status-badge"><svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg></div>'
        }
        const inner = selfCard.querySelector(".voice-card-inner")
        if (inner) {
          inner.insertAdjacentHTML("beforeend", `<div class="voice-status-icons">${badgesHtml}</div>`)
        }
      }
    }
  }

  // ─── Cross-instance participant UI ──────────────────────────
  // LiveKit tells us about remote participants, but the local database
  // only has VoiceState records for local users. For cross-instance
  // participants (no local VoiceState), we create DOM elements from
  // the LiveKit participant metadata embedded in the token.

  _ensureParticipantUI(participant) {
    const userId = participant.identity
    if (!userId || !this.currentChannelId) return

    let meta = {}
    try { meta = JSON.parse(participant.metadata || "{}") } catch (_) {}
    const username = participant.name || userId.slice(0, 8)
    const avatarUrl = meta.avatar_url || ""
    const profileColor = meta.profile_color || "#1e1c1b"

    // ── Sidebar ──
    const sidebarContainer = document.querySelector(
      `[data-voice-channel-participants="${this.currentChannelId}"]`
    )
    if (sidebarContainer && !sidebarContainer.querySelector(`[data-voice-user-id="${userId}"]`)) {
      const row = document.createElement("div")
      row.className = "flex items-center py-0.5 pl-6 pr-2 rounded hover:bg-gray-700/50 group"
      row.dataset.voiceUserId = userId
      row.dataset.channelId = this.currentChannelId
      row.dataset.voiceRemote = "true"
      row.dataset.action = "contextmenu->voice-context#show"

      const avatarWrap = document.createElement("div")
      avatarWrap.className = "relative"
      if (avatarUrl) {
        const img = document.createElement("img")
        img.src = avatarUrl
        img.className = "w-5 h-5 rounded-full object-cover voice-sidebar-avatar"
        img.loading = "lazy"
        avatarWrap.appendChild(img)
      } else {
        const fb = document.createElement("div")
        fb.className = "w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold text-white voice-sidebar-avatar"
        fb.style.backgroundColor = profileColor
        fb.textContent = (username[0] || "?").toUpperCase()
        avatarWrap.appendChild(fb)
      }
      row.appendChild(avatarWrap)

      const name = document.createElement("span")
      name.className = "ml-1.5 text-xs text-gray-300 truncate flex-1"
      name.textContent = username
      row.appendChild(name)

      sidebarContainer.appendChild(row)
    }

    // ── Main voice view card ──
    const grid = document.querySelector("[data-voice-participant-grid] .voice-grid")
    if (grid && !grid.querySelector(`[data-voice-participant-id="${userId}"]`)) {
      const tpl = document.getElementById("tpl-voice-card")
      if (tpl) {
        const card = tpl.content.cloneNode(true).querySelector(".voice-card")
        card.dataset.voiceParticipantId = userId
        card.dataset.voiceRemote = "true"
        card.dataset.action = "contextmenu->voice-context#show"
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
        grid.appendChild(card)
      }
    }
  }

  _removeParticipantUI(participant) {
    const userId = participant.identity
    if (!userId) return

    // Clean up any video tracks for this participant
    this._detachScreenShareTrack(participant)
    this._detachCameraTrack(participant)

    // Only remove elements we created (marked with data-voice-remote)
    document.querySelectorAll(`[data-voice-user-id="${userId}"][data-voice-remote]`).forEach(el => el.remove())
    document.querySelectorAll(`[data-voice-participant-id="${userId}"][data-voice-remote]`).forEach(el => el.remove())
  }

  async _patchState(action, body) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/voice_states/${action}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify(body)
      })
    } catch (e) {
      // Best effort
    }
  }

  _showError(message) {
    // Simple error toast
    const toast = document.createElement("div")
    toast.className = "fixed top-4 right-4 z-50 bg-danger text-white px-4 py-2 rounded-lg shadow-lg"
    toast.textContent = message
    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 5000)
  }
}

import { Controller } from "@hotwired/stimulus"
import {
  Room,
  RoomEvent,
  Track,
  DisconnectReason,
  DataPacket_Kind
} from "livekit-client"

import { RnnoiseProcessor } from "../lib/rnnoise_processor"
import { DeepFilterNoiseFilterProcessor } from "deepfilternet3-noise-filter"

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
    "screenShareBtn", "screenShareIcon", "disconnectBtn",
    "broadcastBtn", "requestSpeakBtn", "hierarchyRow"
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
    this._tokenRefreshTimer = null
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
    this._screenShareGainNodes = new Map()     // identity → gainNode
    this._localPreviewVisHandler = null
    this._ancestorRooms = new Map()     // channelId → { room, audioElements, gainNodes, analysers, channelId, channelName }
    this._monitoredRooms = new Map()    // channelId → { room, audioElements, gainNodes, analysers, volume }
    this._broadcasting = false
    this._childChannels = []            // [{channel_id, name, participant_count}]
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
    this._onNoiseSuppressionChanged = this._handleNoiseSuppressionChanged.bind(this)
    this._onNoiseSuppressionLevelChanged = this._handleNoiseSuppressionLevelChanged.bind(this)
    this._onEchoCancellationChanged = this._handleEchoCancellationChanged.bind(this)
    this._onAgcChanged = this._handleAgcChanged.bind(this)
    this._onInputSensitivityChanged = this._handleInputSensitivityChanged.bind(this)
    this._onInputDeviceChanged = this._handleInputDeviceChanged.bind(this)
    this._onOutputDeviceChanged = this._handleOutputDeviceChanged.bind(this)

    window.addEventListener("voice:join", this._onJoin)
    window.addEventListener("voice:force-disconnect", this._onForceDisconnect)
    window.addEventListener("voice:force-move", this._onForceMove)
    window.addEventListener("voice:server-mute", this._onServerMute)
    window.addEventListener("voice:server-deafen", this._onServerDeafen)
    window.addEventListener("beforeunload", this._onBeforeUnload)
    window.addEventListener("voice:output-volume-changed", this._onOutputVolumeChanged)
    window.addEventListener("voice:noise-suppression-changed", this._onNoiseSuppressionChanged)
    window.addEventListener("voice:noise-suppression-level-changed", this._onNoiseSuppressionLevelChanged)
    window.addEventListener("voice:echo-cancellation-changed", this._onEchoCancellationChanged)
    window.addEventListener("voice:agc-changed", this._onAgcChanged)
    window.addEventListener("voice:input-sensitivity-changed", this._onInputSensitivityChanged)
    window.addEventListener("voice:input-device-changed", this._onInputDeviceChanged)
    window.addEventListener("voice:output-device-changed", this._onOutputDeviceChanged)

    // Re-apply voice panel status after Turbo frame navigations
    this._onFrameLoad = (e) => {
      if (e.target.id === "main-content" && this.room && this.currentChannelId) {
        this._updateVoicePanelStatus("connected")
      }
    }
    document.addEventListener("turbo:frame-load", this._onFrameLoad)

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
    window.removeEventListener("voice:noise-suppression-changed", this._onNoiseSuppressionChanged)
    window.removeEventListener("voice:noise-suppression-level-changed", this._onNoiseSuppressionLevelChanged)
    window.removeEventListener("voice:echo-cancellation-changed", this._onEchoCancellationChanged)
    window.removeEventListener("voice:agc-changed", this._onAgcChanged)
    window.removeEventListener("voice:input-sensitivity-changed", this._onInputSensitivityChanged)
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

  _applyAfkMute() {
    if (!this.room) return
    this._muted = true
    this.room.localParticipant.setMicrophoneEnabled(false)
    this._cleanupLocalLevelMeter()
    this._updateMuteIcon()
    this._updateSelfVoiceIndicators()
    this._patchState("self_mute", { muted: true })
    this._saveSession()
  }

  _handleForceDisconnect() {
    this._disconnectRoom()
  }

  async _handleForceMove(e) {
    const { toChannelId, toChannelName, voiceStateId, afk } = e.detail
    // Prevent the old room's Disconnected event from triggering failover
    this._userInitiatedDisconnect = true

    // Clean up old room + media elements
    if (this.room) {
      this.room.disconnect()
      this.room = null
    }
    this._audioElements.forEach(el => el.remove())
    this._audioElements.clear()
    this._gainNodes?.clear()
    this._analysers.clear()
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
    this._screenShareGainNodes.clear()
    // Clean up ancestor rooms on force-move
    for (const [, state] of this._ancestorRooms) {
      this._cleanupAncestorState(state)
      try { state.room.disconnect() } catch (_) {}
    }
    this._ancestorRooms.clear()
    // Clean up monitored rooms
    for (const [, state] of this._monitoredRooms) {
      this._cleanupMonitorState(state)
      try { state.room.disconnect() } catch (_) {}
    }
    this._monitoredRooms.clear()
    this._stopLevelLoop()
    this._cleanupLocalLevelMeter()

    this.voiceStateId = voiceStateId
    this.currentChannelId = toChannelId

    if (this.hasChannelNameTarget) {
      this.channelNameTarget.textContent = toChannelName || "Voice"
    }

    // Re-join with a new token for the new channel
    try {
      this._userInitiatedDisconnect = false
      await this._joinChannel(toChannelId, this.currentServerId)
      if (afk) {
        this._applyAfkMute()
      }
    } catch (err) {
      console.error("[VoiceChannel] Force-move reconnect failed:", err)
      this._userInitiatedDisconnect = false
    }
  }

  _handleOutputVolumeChanged(e) {
    const { volume } = e.detail
    if (!this._deafened) {
      const gain = volume / 100
      this._setRemoteVolumes(gain)
      this._setAncestorVolumes(gain)
      // Monitor volumes use their own per-child slider, not the global output
    }
  }

  // Returns the user's saved output volume as a 0-2 float (0-200% range)
  _getOutputGain() {
    const saved = parseInt(localStorage.getItem("voice-output-volume") ?? "100", 10)
    return Math.max(0, Math.min(2, saved / 100))
  }

  // Build audio capture constraints from stored preferences.
  // When RNNoise is enabled, we disable the browser's built-in noise
  // suppression to avoid double-processing artifacts (phasing, pumping).
  _audioCaptureOptions() {
    const deviceId = localStorage.getItem("voice-input-device")
    const rnnoiseEnabled = localStorage.getItem("voice-noise-suppression") !== "false"
    const opts = {
      autoGainControl: localStorage.getItem("voice-auto-gain-control") !== "false",
      echoCancellation: localStorage.getItem("voice-echo-cancellation") !== "false",
      // Disable browser suppression when RNNoise handles it
      noiseSuppression: !rnnoiseEnabled
    }
    if (deviceId && deviceId !== "default") {
      opts.deviceId = { ideal: deviceId }
    }
    return opts
  }

  // ─── Live settings handlers ──────────────────────────────────

  async _handleNoiseSuppressionChanged() {
    await this._republishMicWithCurrentSettings()
    await this._syncNoiseProcessor()
  }

  async _handleNoiseSuppressionLevelChanged() {
    // Level changed — rebuild the processor with new HP/gate settings
    await this._syncNoiseProcessor()
  }

  async _handleEchoCancellationChanged() {
    await this._republishMicWithCurrentSettings()
  }

  async _handleAgcChanged() {
    await this._republishMicWithCurrentSettings()
  }

  _handleInputSensitivityChanged() {
    this._speakThreshold = this._computeSpeakThreshold()
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

  // Schedule token renewal 30 minutes before the JWT expires.
  // Requests a new token from the backend and reconnects seamlessly.
  _scheduleTokenRefresh(token, serverId, channelId) {
    if (this._tokenRefreshTimer) clearTimeout(this._tokenRefreshTimer)
    this._currentToken = token
    try {
      const parts = token.split(".")
      if (parts.length !== 3) return
      const payload = JSON.parse(atob(parts[1]))
      const exp = payload.exp
      if (!exp) return

      this._tokenExpiresAt = exp * 1000
      const renewAt = this._tokenExpiresAt - (30 * 60 * 1000) // 30 min before expiry
      const delay = renewAt - Date.now()

      if (delay <= 0) {
        console.warn("[VoiceChannel] Token already near expiry, renewing now")
        this._renewToken(serverId, channelId)
        return
      }

      const delayMin = Math.round(delay / 60000)
      console.log(`[VoiceChannel] Token renewal scheduled in ${delayMin}m`)
      this._tokenRefreshTimer = setTimeout(() => this._renewToken(serverId, channelId), delay)
    } catch (e) {
      console.warn("[VoiceChannel] Could not parse token expiry:", e)
    }
  }

  async _renewToken(serverId, channelId) {
    if (!this.room) return

    // Skip renewal if token still has >30 min left
    if (this._tokenExpiresAt && (this._tokenExpiresAt - Date.now()) > 30 * 60 * 1000) {
      console.log("[VoiceChannel] Token still valid, skipping renewal")
      this._scheduleTokenRefresh(this._currentToken, serverId, channelId)
      return
    }

    console.log("[VoiceChannel] Token expiring, requesting renewal...")
    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch(`/servers/${serverId}/voice/join/${channelId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
        credentials: "same-origin"
      })
      if (!response.ok) {
        console.error("[VoiceChannel] Token renewal request failed:", response.status)
        return
      }
      const data = await response.json()
      if (!data.token || !data.livekit_url) {
        console.error("[VoiceChannel] Invalid renewal response")
        return
      }

      // Disconnect and reconnect with new token
      const wasMuted = this._muted
      const wasDeafened = this._deafened
      this.room.disconnect()

      this.room = new Room({
        adaptiveStream: true,
        dynacast: true,
        audioCaptureDefaults: this._audioCaptureOptions()
      })
      this._setupRoomEvents()
      await this.room.connect(data.livekit_url, data.token)

      // Restore audio state
      if (!wasMuted) {
        await this.room.localParticipant.setMicrophoneEnabled(true, this._audioCaptureOptions())
      }
      if (wasDeafened) this._deafened = true

      await this._syncNoiseProcessor()
      this._scheduleTokenRefresh(data.token, serverId, channelId)
      console.log("[VoiceChannel] Token renewed, reconnected")
    } catch (e) {
      console.error("[VoiceChannel] Token renewal failed:", e)
    }
  }

  // Attach or detach the RNNoise processor based on stored preference.
  // When the suppression level changes, we tear down and rebuild the processor
  // so the new high-pass / gate settings take effect.
  async _syncNoiseProcessor() {
    if (!this.room || this._muted) return
    const enabled = localStorage.getItem("voice-noise-suppression") !== "false"
    const level = localStorage.getItem("voice-noise-suppression-level") || "moderate"
    const pub = this.room.localParticipant.getTrackPublication(Track.Source.Microphone)
    const localTrack = pub?.track
    if (!localTrack) return

    // Map level names to DeepFilterNet3 suppression values (0-100)
    const dfLevels = { low: 40, moderate: 80, aggressive: 95 }
    const dfLevel = dfLevels[level] ?? 60

    // If level changed, tear down old processor so we rebuild with new settings
    if (enabled && this._noiseProcessor && this._noiseLevel !== level) {
      try { await localTrack.stopProcessor() } catch (_) {}
      this._noiseProcessor = null
    }

    if (enabled && !this._noiseProcessor) {
      // Try DeepFilterNet3 first, fall back to RNNoise
      try {
        this._noiseProcessor = new DeepFilterNoiseFilterProcessor({
          sampleRate: 48000,
          noiseReductionLevel: dfLevel,
          enabled: true
        })
        this._noiseLevel = level
        await localTrack.setProcessor(this._noiseProcessor)
        console.log(`[VoiceChannel] DeepFilterNet3 processor attached (${level}=${dfLevel})`)
      } catch (e) {
        console.warn("[VoiceChannel] DeepFilterNet3 failed, falling back to RNNoise:", e)
        this._noiseProcessor = null
        try {
          this._noiseProcessor = new RnnoiseProcessor(level)
          this._noiseLevel = level
          await localTrack.setProcessor(this._noiseProcessor)
          console.log(`[VoiceChannel] RNNoise processor attached (${level})`)
        } catch (e2) {
          console.warn("[VoiceChannel] RNNoise attach also failed:", e2)
          this._noiseProcessor = null
        }
      }
    } else if (enabled && this._noiseProcessor?.setSuppressionLevel) {
      // DeepFilterNet3 supports live level adjustment
      this._noiseProcessor.setSuppressionLevel(dfLevel)
      this._noiseLevel = level
    } else if (!enabled && this._noiseProcessor) {
      try {
        await localTrack.stopProcessor()
      } catch (_) {}
      this._noiseProcessor = null
      this._noiseLevel = null
      console.log("[VoiceChannel] Noise processor detached")
    }
  }

  // Republish mic track with updated audio processing constraints (echo, AGC)
  async _republishMicWithCurrentSettings() {
    if (!this.room || this._muted) return
    try {
      // Processor must be detached before disabling the track
      if (this._noiseProcessor) {
        const pub = this.room.localParticipant.getTrackPublication(Track.Source.Microphone)
        try { await pub?.track?.stopProcessor() } catch (_) {}
        this._noiseProcessor = null
      }
      await this.room.localParticipant.setMicrophoneEnabled(false)
      this._cleanupLocalLevelMeter()
      await this.room.localParticipant.setMicrophoneEnabled(true, this._audioCaptureOptions())
      this._setupLocalLevelMeter()
      await this._syncNoiseProcessor()
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
    let micEnabled = false
    try {
      await this.room.localParticipant.setMicrophoneEnabled(true, this._audioCaptureOptions())
      console.log("[VoiceChannel] Mic enabled successfully")
      micEnabled = true
    } catch (micErr) {
      console.error("[VoiceChannel] Failed to enable mic:", micErr)
      // Retry with no constraints as fallback
      try {
        await this.room.localParticipant.setMicrophoneEnabled(true)
        console.log("[VoiceChannel] Mic enabled with default constraints")
        micEnabled = true
      } catch (retryErr) {
        console.error("[VoiceChannel] Mic retry also failed, joining muted:", retryErr)
      }
    }

    // If mic permission was denied, join muted
    if (micEnabled) {
      this._muted = false
    } else {
      this._muted = true
      this._updateSelfMuteUI()
      this._showError("Microphone access was blocked — you joined muted.")
    }
    this._deafened = false

    // Attach RNNoise processor if noise suppression is enabled
    await this._syncNoiseProcessor()

    // Render any participants already in the room (joined before us)
    for (const participant of this.room.remoteParticipants.values()) {
      this._ensureParticipantUI(participant)
      this._updateRemoteParticipantMuteIcons(participant)
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

    // Connect to ancestor rooms (subscribe-only) for cascading audio
    if (data.ancestor_rooms && data.ancestor_rooms.length > 0) {
      await this._connectAncestorRooms(data.ancestor_rooms)
    }

    // Store ember channels for monitor/broadcast UI
    this._childChannels = data.child_channels || []
    this._broadcasting = false

    // Persist session for reconnect on refresh
    this._saveSession()

    // Schedule token renewal 30 minutes before expiry
    this._scheduleTokenRefresh(data.token, serverId, channelId)

    // Show controls bar
    this._showControlsBar(data.channel_name || "Voice")
    this._updateVoicePanelStatus("connected")
    this._updateHierarchyButtons()

    // Auto-mute in AFK channels
    if (data.afk) {
      this._applyAfkMute()
    }
  }

  async _disconnectRoom() {
    this._userInitiatedDisconnect = true
    this._stopLevelLoop()
    this._cleanupLocalLevelMeter()
    this._noiseProcessor = null
    if (this._tokenRefreshTimer) {
      clearTimeout(this._tokenRefreshTimer)
      this._tokenRefreshTimer = null
    }

    // Clear persisted session — explicit disconnect should not auto-rejoin
    this._clearSession()

    // Notify backend FIRST — use sendBeacon for reliability (survives page nav/unload)
    if (this.currentServerId) {
      this._sendLeave(this.currentServerId)
    }

    if (this.room) {
      this.room.disconnect()
      this.room = null
    }

    // Clean up audio elements, gain nodes, and analysers
    this._audioElements.forEach(el => el.remove())
    this._audioElements.clear()
    this._gainNodes?.clear()
    this._analysers.clear()

    // Clean up ancestor rooms
    for (const [, state] of this._ancestorRooms) {
      this._cleanupAncestorState(state)
      try { state.room.disconnect() } catch (_) {}
    }
    this._ancestorRooms.clear()

    // Clean up monitored rooms
    for (const [, state] of this._monitoredRooms) {
      this._cleanupMonitorState(state)
      try { state.room.disconnect() } catch (_) {}
    }
    this._monitoredRooms.clear()

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
    this._screenShareGainNodes.clear()
    if (this._localPreviewVisHandler) {
      document.removeEventListener("visibilitychange", this._localPreviewVisHandler)
      this._localPreviewVisHandler = null
    }
    this._screenShareTrack = null

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

  // Reliably notify the backend of a voice leave.
  // Uses sendBeacon (survives page unload/navigation) with fetch fallback.
  _sendLeave(serverId) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    const url = `/servers/${serverId}/voice/leave`

    // sendBeacon is the most reliable for unload/navigation scenarios
    if (navigator.sendBeacon) {
      const blob = new Blob([JSON.stringify({ authenticity_token: csrfToken })], { type: "application/json" })
      const sent = navigator.sendBeacon(url, blob)
      if (sent) return
    }

    // Fallback: keepalive fetch
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      keepalive: true
    }).catch(() => {})
  }

  _handleBeforeUnload() {
    // Save session so we can rejoin after refresh.
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

    // Remote participant mutes/unmutes a track → update their voice card icons
    room.on(RoomEvent.TrackMuted, (publication, participant) => {
      if (!participant.isLocal) this._updateRemoteParticipantMuteIcons(participant)
    })
    room.on(RoomEvent.TrackUnmuted, (publication, participant) => {
      if (!participant.isLocal) this._updateRemoteParticipantMuteIcons(participant)
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
      // Apply per-user volume if saved, otherwise use default output gain
      const userGain = this._userVolumes?.get(participant.identity)
      const outputGain = this._getOutputGain()
      this._setParticipantVolume(participant.identity, userGain != null ? outputGain * userGain : outputGain)
    }

    // Load saved per-user volume from localStorage
    const savedVol = localStorage.getItem(`user-vol-${participant.identity}`)
    if (savedVol) {
      const vol = parseInt(savedVol, 10) / 100
      if (!this._userVolumes) this._userVolumes = new Map()
      this._userVolumes.set(participant.identity, vol)
      if (!this._deafened) {
        this._setParticipantVolume(participant.identity, this._getOutputGain() * vol)
      }
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

  // Convert the settings slider (-100..0) to an RMS threshold for the level loop.
  // The slider scale is a linear percentage mapped to -100..0, NOT real dB —
  // so we use a squared curve to map it to the 0..0.30 RMS range that the
  // time-domain analyser produces for typical speech.
  _computeSpeakThreshold() {
    const auto = localStorage.getItem("voice-sensitivity-auto") !== "false"
    if (auto) return 0.03
    const slider = parseInt(localStorage.getItem("voice-sensitivity-threshold") ?? "-50", 10)
    const pct = (slider + 100) / 100            // 0..1  (-100→0, -50→0.5, 0→1)
    return 0.001 + pct * pct * 0.30             // squared curve: -50→0.076, -80→0.013, -20→0.193
  }

  _startLevelLoop() {
    if (this._levelRafId) return
    this._speakThreshold = this._computeSpeakThreshold()
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

      this._applyLevelsToDOM(levels, this._speakThreshold)
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
    // Update all voice panel status areas (desktop + mobile)
    document.querySelectorAll("[data-voice-panel-status]").forEach(panel => {
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
                         <div class="animate-spin w-3.5 h-3.5 border-2 border-warning-light border-t-transparent rounded-full"></div>
                         <p class="text-warning-light text-sm font-medium">Reconnecting...</p>
                       </div>`
      }

      panel.innerHTML = statusMap[state] || statusMap.join
    })
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
      this._setAncestorVolumes(0)
      this._setMonitorVolumesAll(0)
    } else {
      // Undeafen → unmute and restore volume to saved gain
      this._muted = false
      const gain = this._getOutputGain()
      this._setRemoteVolumes(gain)
      this._setAncestorVolumes(gain)
      this._restoreMonitorVolumes()
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
    const mobileBtn = document.querySelector('[data-mobile-voice-btn="screenshare"]')
    if (this._screenSharing) {
      btn.classList.add("text-green-400")
      btn.classList.remove("text-gray-300")
      if (mobileBtn) { mobileBtn.classList.add("text-green-400", "bg-green-400/10"); mobileBtn.classList.remove("text-gray-300") }
    } else {
      btn.classList.remove("text-green-400")
      btn.classList.add("text-gray-300")
      if (mobileBtn) { mobileBtn.classList.remove("text-green-400", "bg-green-400/10"); mobileBtn.classList.add("text-gray-300") }
    }
  }

  _updateCameraIcon() {
    if (!this.hasCameraBtnTarget) return
    const btn = this.cameraBtnTarget
    const mobileBtn = document.querySelector('[data-mobile-voice-btn="camera"]')
    if (this._cameraOn) {
      btn.classList.add("text-green-400")
      btn.classList.remove("text-gray-300")
      if (mobileBtn) { mobileBtn.classList.add("text-green-400", "bg-green-400/10"); mobileBtn.classList.remove("text-gray-300") }
    } else {
      btn.classList.remove("text-green-400")
      btn.classList.add("text-gray-300")
      if (mobileBtn) { mobileBtn.classList.remove("text-green-400", "bg-green-400/10"); mobileBtn.classList.add("text-gray-300") }
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

    // Right-click context menu for volume / mute / broadcast
    preview.addEventListener("contextmenu", (e) => {
      e.preventDefault()
      e.stopPropagation()
      window.dispatchEvent(new CustomEvent("voice:stream-context", {
        detail: { identity, x: e.clientX, y: e.clientY }
      }))
    })

    // Add close button for remote streams (stop watching)
    const localId = this.room?.localParticipant?.identity
    if (identity !== localId) {
      const closeBtn = document.createElement("button")
      closeBtn.className = "voice-screen-close-btn"
      closeBtn.title = "Stop watching"
      closeBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>'
      closeBtn.addEventListener("click", (e) => {
        e.stopPropagation()
        this._unwatchScreenShare(identity)
      })
      preview.appendChild(closeBtn)
    }

    // Start in card format inside the grid (users opt in to theatre)
    preview.classList.add("voice-screen-preview--card")
    const grid = container.querySelector(".voice-grid")
    if (grid) {
      grid.appendChild(preview)
    } else {
      container.appendChild(preview)
    }

    this._videoElements.set(identity, { element: preview, track, participant, theatre: false })
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

      // Web Audio gain chain for volume control
      try {
        if (!this._audioContext) this._audioContext = new AudioContext()
        if (this._audioContext.state === "suspended") this._audioContext.resume()
        const source = this._audioContext.createMediaElementSource(el)
        const gainNode = this._audioContext.createGain()
        source.connect(gainNode)
        gainNode.connect(this._audioContext.destination)
        this._screenShareGainNodes.set(identity, gainNode)
        // Restore saved volume
        const saved = localStorage.getItem(`ss-vol-${identity}`)
        if (saved) gainNode.gain.value = parseInt(saved, 10) / 100
      } catch (e) { /* fallback: no gain node */ }
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
    this._screenShareGainNodes.delete(identity)
  }

  _unwatchScreenShare(identity) {
    const entry = this._videoElements.get(identity)
    if (!entry) return
    const { element, track, participant } = entry
    try { track.detach() } catch (_) {}
    element.remove()
    this._videoElements.delete(identity)
    this._detachScreenShareAudio(identity)
    // Re-show the placeholder so they can watch again
    this._showScreenSharePlaceholder(track, participant)
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

    const videos = []
    // Attach to all matching cards (desktop + mobile grids)
    document.querySelectorAll(`[data-voice-participant-id="${identity}"]`).forEach(card => {
      const inner = card.querySelector(".voice-card-inner")
      if (!inner) return

      const video = track.attach()
      video.className = "voice-camera-video"
      video.dataset.cameraIdentity = identity
      inner.appendChild(video)
      videos.push(video)

      // Hide the avatar
      const avatarWrapper = inner.querySelector(".voice-avatar-wrapper")
      if (avatarWrapper) avatarWrapper.style.display = "none"
    })

    if (videos.length) {
      this._cameraElements.set(identity, { video: videos[0], videos, track })
    }
  }

  _detachCameraTrack(participant) {
    const identity = participant.identity
    const entry = this._cameraElements.get(identity)
    if (entry) {
      const { videos, track } = entry
      // Properly detach the LiveKit track so no frozen frame remains
      try { track.detach() } catch (_) {}
      // Remove all video elements (desktop + mobile)
      if (videos) {
        videos.forEach(v => v.remove())
      } else if (entry.video) {
        entry.video.remove()
      }
      this._cameraElements.delete(identity)
    }

    // Restore avatars in all grids
    document.querySelectorAll(`[data-voice-participant-id="${identity}"]`).forEach(card => {
      const avatarWrapper = card.querySelector(".voice-avatar-wrapper")
      if (avatarWrapper) avatarWrapper.style.display = ""
    })
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
    // Show mobile voice controls bar if present
    const mobileBar = document.getElementById("mobile-voice-controls")
    if (mobileBar) mobileBar.classList.remove("hidden")
  }

  _updateControlsBarStatus(state) {
    if (!this.hasStatusTextTarget) return
    const el = this.statusTextTarget
    if (state === "reconnecting") {
      el.textContent = "Reconnecting..."
      el.classList.remove("text-green-500")
      el.classList.add("text-warning-light")
    } else {
      el.textContent = "Voice Connected"
      el.classList.remove("text-warning-light")
      el.classList.add("text-green-500")
    }
  }

  _hideControlsBar() {
    if (this.hasControlsBarTarget) {
      this.controlsBarTarget.classList.add("hidden")
    }
    // Hide mobile voice controls bar if present
    const mobileBar = document.getElementById("mobile-voice-controls")
    if (mobileBar) mobileBar.classList.add("hidden")
  }

  _updateMuteIcon() {
    if (!this.hasMuteBtnTarget) return
    const btn = this.muteBtnTarget
    const mobileBtn = document.querySelector('[data-mobile-voice-btn="mute"]')
    if (this._muted) {
      btn.classList.add("text-red-400")
      btn.classList.remove("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2" stroke-linecap="round"/></svg>'
      if (mobileBtn) {
        mobileBtn.classList.add("text-red-400", "bg-red-400/10")
        mobileBtn.classList.remove("text-gray-300")
        mobileBtn.innerHTML = '<svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/><line x1="3" y1="3" x2="21" y2="21" stroke-width="2" stroke-linecap="round"/></svg>'
      }
    } else {
      btn.classList.remove("text-red-400")
      btn.classList.add("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/></svg>'
      if (mobileBtn) {
        mobileBtn.classList.remove("text-red-400", "bg-red-400/10")
        mobileBtn.classList.add("text-gray-300")
        mobileBtn.innerHTML = '<svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/></svg>'
      }
    }
  }

  _updateDeafenIcon() {
    if (!this.hasDeafenBtnTarget) return
    const btn = this.deafenBtnTarget
    const mobileBtn = document.querySelector('[data-mobile-voice-btn="deafen"]')
    if (this._deafened) {
      btn.classList.add("text-red-400")
      btn.classList.remove("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>'
      if (mobileBtn) {
        mobileBtn.classList.add("text-red-400", "bg-red-400/10")
        mobileBtn.classList.remove("text-gray-300")
        mobileBtn.innerHTML = '<svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>'
      }
    } else {
      btn.classList.remove("text-red-400")
      btn.classList.add("text-gray-300")
      btn.innerHTML = '<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M18.364 5.636a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/></svg>'
      if (mobileBtn) {
        mobileBtn.classList.remove("text-red-400", "bg-red-400/10")
        mobileBtn.classList.add("text-gray-300")
        mobileBtn.innerHTML = '<svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M18.364 5.636a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"/></svg>'
      }
    }
  }

  // Public: set per-user volume (called from voice context menu)
  setUserVolume(userId, gain) {
    if (!this._userVolumes) this._userVolumes = new Map()
    this._userVolumes.set(userId, gain)
    // The LiveKit identity is the user's public_id
    this._setParticipantVolume(userId, this._deafened ? 0 : gain * this._getOutputGain())
  }

  // Public: set screen share audio volume (called from stream context menu)
  setScreenShareVolume(identity, gain) {
    const gainNode = this._screenShareGainNodes.get(identity)
    if (gainNode) {
      gainNode.gain.value = gain
    } else {
      const el = this._screenShareAudioElements.get(identity)
      if (el) el.volume = Math.min(1, Math.max(0, gain))
    }
  }

  // Public: toggle mute on a screen share's audio
  muteScreenShareAudio(identity) {
    const el = this._screenShareAudioElements.get(identity)
    if (el) el.muted = !el.muted
    return el?.muted ?? false
  }

  _setRemoteVolumes(gain) {
    this._audioElements.forEach((el, identity) => {
      // Apply per-user volume multiplier if set
      const userGain = this._userVolumes?.get(identity)
      this._setParticipantVolume(identity, userGain != null ? gain * userGain : gain)
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

    // Update main voice view cards for self (both desktop and mobile grids)
    document.querySelectorAll(`[data-voice-participant-id="${currentUserId}"]`).forEach(selfCard => {
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
    })
  }

  _updateRemoteParticipantMuteIcons(participant) {
    const userId = participant.identity
    // Update all matching cards (desktop + mobile grids)
    document.querySelectorAll(`[data-voice-participant-id="${userId}"]`).forEach(card => {
      const existingIcons = card.querySelector(".voice-status-icons")
      if (existingIcons) existingIcons.remove()

      const isMuted = !participant.isMicrophoneEnabled
      if (isMuted) {
        const inner = card.querySelector(".voice-card-inner")
        if (inner) {
          inner.insertAdjacentHTML("beforeend",
            `<div class="voice-status-icons"><div class="voice-status-badge">` +
            `<svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">` +
            `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"/>` +
            `<line x1="3" y1="3" x2="21" y2="21" stroke-width="2.5" stroke-linecap="round"/>` +
            `</svg></div></div>`)
        }
      }
    })
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

    // ── Main voice view cards (desktop + mobile grids) ──
    document.querySelectorAll("[data-voice-participant-grid] .voice-grid").forEach(grid => {
      if (grid.querySelector(`[data-voice-participant-id="${userId}"]`)) return
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
    })
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

  // ─── Hierarchical Voice: Ancestor Rooms ──────────────────────

  async _connectAncestorRooms(ancestorRooms) {
    for (const info of ancestorRooms) {
      const room = new Room({ adaptiveStream: true, dynacast: true })
      const state = {
        room,
        audioElements: new Map(),
        gainNodes: new Map(),
        analysers: new Map(),
        channelId: info.channel_id,
        channelName: info.channel_name
      }
      this._ancestorRooms.set(info.channel_id, state)

      this._setupAncestorRoomEvents(room, state)
      try {
        await room.connect(info.livekit_url, info.token)
        console.log(`[VoiceChannel] Connected to ancestor room: ${info.channel_name}`)

        // Attach existing participants' audio and video
        for (const p of room.remoteParticipants.values()) {
          for (const pub of p.audioTrackPublications.values()) {
            if (pub.track && pub.isSubscribed) {
              this._attachAncestorAudioTrack(pub.track, p, state)
            }
          }
          for (const pub of p.videoTrackPublications.values()) {
            if (pub.track && pub.isSubscribed) {
              if (pub.source === Track.Source.ScreenShare) {
                this._showScreenSharePlaceholder(pub.track, p, state.channelName)
              } else if (pub.source === Track.Source.Camera) {
                this._attachCameraTrack(pub.track, p)
              }
            }
          }
        }
      } catch (err) {
        console.warn(`[VoiceChannel] Failed to connect ancestor room ${info.channel_name}:`, err)
      }
    }
  }

  _setupAncestorRoomEvents(room, state) {
    room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
      if (track.kind === Track.Kind.Audio) {
        this._attachAncestorAudioTrack(track, participant, state)
      } else if (track.kind === Track.Kind.Video) {
        if (pub.source === Track.Source.ScreenShare) {
          this._showScreenSharePlaceholder(track, participant, state.channelName)
        } else if (pub.source === Track.Source.Camera) {
          this._attachCameraTrack(track, participant)
        }
      }
    })
    room.on(RoomEvent.TrackUnsubscribed, (track, pub, participant) => {
      if (track.kind === Track.Kind.Audio) {
        this._detachAncestorAudioTrack(participant, state)
      } else if (track.kind === Track.Kind.Video) {
        if (pub.source === Track.Source.ScreenShare) {
          this._detachScreenShareTrack(participant)
        } else if (pub.source === Track.Source.Camera) {
          this._detachCameraTrack(participant)
        }
      }
    })
    room.on(RoomEvent.DataReceived, (payload, participant) => {
      try {
        const msg = JSON.parse(new TextDecoder().decode(payload))
        if (msg.type === "broadcast") {
          const gainNode = state.gainNodes.get(msg.identity)
          if (gainNode) {
            const vol = msg.on ? this._getOutputGain() : 0
            gainNode.gain.setValueAtTime(vol, this._audioContext.currentTime)
          }
        }
      } catch (_) {}
    })
    room.on(RoomEvent.Disconnected, () => {
      this._cleanupAncestorState(state)
    })
  }

  _attachAncestorAudioTrack(track, participant, state) {
    const el = track.attach()
    el.id = `voice-ancestor-audio-${state.channelId}-${participant.identity}`
    el.style.display = "none"
    document.body.appendChild(el)
    state.audioElements.set(participant.identity, el)

    try {
      if (!this._audioContext) this._audioContext = new AudioContext()
      if (this._audioContext.state === "suspended") this._audioContext.resume()

      const source = this._audioContext.createMediaElementSource(el)
      const gainNode = this._audioContext.createGain()
      const analyser = this._audioContext.createAnalyser()
      analyser.fftSize = 256
      analyser.smoothingTimeConstant = 0.3
      source.connect(analyser)
      analyser.connect(gainNode)
      gainNode.connect(this._audioContext.destination)

      state.gainNodes.set(participant.identity, gainNode)
      state.analysers.set(participant.identity, { analyser })

      // Respect deafen state
      const vol = this._deafened ? 0 : this._getOutputGain()
      gainNode.gain.setValueAtTime(vol, this._audioContext.currentTime)
    } catch (e) {
      // Fallback: no gain node
    }
  }

  _detachAncestorAudioTrack(participant, state) {
    const el = state.audioElements.get(participant.identity)
    if (el) {
      el.remove()
      state.audioElements.delete(participant.identity)
    }
    state.gainNodes.delete(participant.identity)
    state.analysers.delete(participant.identity)
  }

  _cleanupAncestorState(state) {
    state.audioElements.forEach(el => el.remove())
    state.audioElements.clear()
    state.gainNodes.clear()
    state.analysers.clear()
  }

  _setAncestorVolumes(gain) {
    for (const [, state] of this._ancestorRooms) {
      for (const [, gainNode] of state.gainNodes) {
        if (this._audioContext) {
          gainNode.gain.setValueAtTime(gain, this._audioContext.currentTime)
        }
      }
    }
  }

  // ─── Hierarchical Voice: Monitor Mode ────────────────────────

  async toggleMonitor(e) {
    const channelId = e.target?.dataset?.monitorChannelId
    if (!channelId || !this.currentServerId) return

    if (this._monitoredRooms.has(channelId)) {
      this._detachMonitor(channelId)
      return
    }

    // Fetch subscribe-only token from monitor endpoint
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      const response = await fetch(`/servers/${this.currentServerId}/voice/monitor/${channelId}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })
      const data = await response.json()
      if (!response.ok) {
        this._showError(data.error || "Failed to start monitoring")
        e.target.checked = false
        return
      }

      const room = new Room({ adaptiveStream: true, dynacast: true })
      const savedVol = parseInt(localStorage.getItem(`monitor-vol-${channelId}`) ?? "80", 10) / 100
      const state = {
        room,
        audioElements: new Map(),
        gainNodes: new Map(),
        analysers: new Map(),
        channelId: data.channel_id,
        channelName: data.channel_name,
        volume: savedVol
      }
      this._monitoredRooms.set(channelId, state)

      this._setupMonitorRoomEvents(room, state)
      await room.connect(data.livekit_url, data.token)
      console.log(`[VoiceChannel] Monitoring: ${data.channel_name}`)

      // Attach existing participants
      for (const p of room.remoteParticipants.values()) {
        for (const pub of p.audioTrackPublications.values()) {
          if (pub.track && pub.isSubscribed) {
            this._attachMonitorAudioTrack(pub.track, p, state)
          }
        }
      }
    } catch (err) {
      console.error("[VoiceChannel] Monitor failed:", err)
      this._showError("Failed to start monitoring")
      e.target.checked = false
    }
  }

  _setupMonitorRoomEvents(room, state) {
    room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
      if (track.kind === Track.Kind.Audio) {
        this._attachMonitorAudioTrack(track, participant, state)
      }
    })
    room.on(RoomEvent.TrackUnsubscribed, (track, pub, participant) => {
      if (track.kind === Track.Kind.Audio) {
        this._detachMonitorAudioTrack(participant, state)
      }
    })
    room.on(RoomEvent.Disconnected, () => {
      this._cleanupMonitorState(state)
    })
  }

  _attachMonitorAudioTrack(track, participant, state) {
    const el = track.attach()
    el.id = `voice-monitor-audio-${state.channelId}-${participant.identity}`
    el.style.display = "none"
    document.body.appendChild(el)
    state.audioElements.set(participant.identity, el)

    try {
      if (!this._audioContext) this._audioContext = new AudioContext()
      if (this._audioContext.state === "suspended") this._audioContext.resume()

      const source = this._audioContext.createMediaElementSource(el)
      const gainNode = this._audioContext.createGain()
      const analyser = this._audioContext.createAnalyser()
      analyser.fftSize = 256
      analyser.smoothingTimeConstant = 0.3
      source.connect(analyser)
      analyser.connect(gainNode)
      gainNode.connect(this._audioContext.destination)

      state.gainNodes.set(participant.identity, gainNode)
      state.analysers.set(participant.identity, { analyser })

      const vol = this._deafened ? 0 : state.volume
      gainNode.gain.setValueAtTime(vol, this._audioContext.currentTime)
    } catch (e) {
      // Fallback
    }
  }

  _detachMonitorAudioTrack(participant, state) {
    const el = state.audioElements.get(participant.identity)
    if (el) {
      el.remove()
      state.audioElements.delete(participant.identity)
    }
    state.gainNodes.delete(participant.identity)
    state.analysers.delete(participant.identity)
  }

  _cleanupMonitorState(state) {
    state.audioElements.forEach(el => el.remove())
    state.audioElements.clear()
    state.gainNodes.clear()
    state.analysers.clear()
  }

  _detachMonitor(channelId) {
    const state = this._monitoredRooms.get(channelId)
    if (!state) return
    this._cleanupMonitorState(state)
    try { state.room.disconnect() } catch (_) {}
    this._monitoredRooms.delete(channelId)
    console.log(`[VoiceChannel] Stopped monitoring: ${channelId}`)
  }

  setMonitorVolume(e) {
    const channelId = e.target?.dataset?.monitorVolumeChannel
    if (!channelId) return
    const vol = parseInt(e.target.value, 10) / 100
    localStorage.setItem(`monitor-vol-${channelId}`, e.target.value)

    const state = this._monitoredRooms.get(channelId)
    if (!state) return
    state.volume = vol
    if (this._deafened) return
    for (const [, gainNode] of state.gainNodes) {
      if (this._audioContext) {
        gainNode.gain.setValueAtTime(vol, this._audioContext.currentTime)
      }
    }
  }

  _setMonitorVolumesAll(gain) {
    for (const [, state] of this._monitoredRooms) {
      for (const [, gainNode] of state.gainNodes) {
        if (this._audioContext) {
          gainNode.gain.setValueAtTime(gain, this._audioContext.currentTime)
        }
      }
    }
  }

  _restoreMonitorVolumes() {
    for (const [, state] of this._monitoredRooms) {
      for (const [, gainNode] of state.gainNodes) {
        if (this._audioContext) {
          gainNode.gain.setValueAtTime(state.volume, this._audioContext.currentTime)
        }
      }
    }
  }

  // ─── Hierarchical Voice: Broadcast Toggle ────────────────────

  toggleBroadcast() {
    if (!this.room) return
    this._broadcasting = !this._broadcasting
    this._updateBroadcastIcon()
    this._updateSelfBroadcastBadge()

    // Notify all room participants via data message
    const data = JSON.stringify({
      type: "broadcast",
      on: this._broadcasting,
      identity: this.room.localParticipant.identity
    })
    this.room.localParticipant.publishData(
      new TextEncoder().encode(data),
      { reliable: true }
    )

    // Persist to VoiceState for late joiners
    this._patchState("broadcasting", { broadcasting: this._broadcasting })
  }

  _updateSelfBroadcastBadge() {
    const currentUserId = document.body.dataset.currentUserId
    if (!currentUserId) return
    const selfRow = document.querySelector(`[data-voice-user-id="${currentUserId}"]`)
    if (!selfRow) return
    const avatarWrap = selfRow.querySelector(".relative")
    if (!avatarWrap) return
    const existing = avatarWrap.querySelector(".voice-broadcast-badge")
    if (this._broadcasting && !existing) {
      avatarWrap.insertAdjacentHTML("beforeend", '<div class="voice-broadcast-badge" title="Broadcasting to children"><svg class="w-1.5 h-1.5 text-white" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M11 5.882V19.24a1.76 1.76 0 01-3.417.592l-2.147-6.15M18 13a3 3 0 100-6M5.436 13.683A4.001 4.001 0 017 6h1.832c4.1 0 7.625-1.234 9.168-3v14c-1.543-1.766-5.067-3-9.168-3H7a3.988 3.988 0 01-1.564-.317z"/></svg></div>')
    } else if (!this._broadcasting && existing) {
      existing.remove()
    }
  }

  _updateBroadcastIcon() {
    if (!this.hasBroadcastBtnTarget) return
    const btn = this.broadcastBtnTarget
    if (this._broadcasting) {
      btn.classList.add("text-green-400")
      btn.classList.remove("text-gray-300")
    } else {
      btn.classList.remove("text-green-400")
      btn.classList.add("text-gray-300")
    }
  }

  // ─── Hierarchical Voice: Showcase Channel ───────────────────

  async showcaseChannel(e) {
    const channelId = e.target?.closest("[data-showcase-channel-id]")?.dataset.showcaseChannelId
    if (!channelId || !this.currentServerId) return
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      await fetch(`/servers/${this.currentServerId}/voice_showcases`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ child_channel_id: channelId })
      })
    } catch (err) {
      console.warn("[VoiceChannel] Showcase channel failed:", err)
    }
  }

  // ─── Hierarchical Voice: Request to Speak ────────────────────

  async requestToSpeak() {
    if (!this.currentServerId) return
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      const response = await fetch(`/servers/${this.currentServerId}/voice_showcases/request_speak`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })
      const data = await response.json()
      if (!response.ok) {
        this._showError(data.error || "Failed to send request")
        return
      }
      // Show confirmation
      const toast = document.createElement("div")
      toast.className = "fixed top-4 right-4 z-50 bg-green-600 text-white px-4 py-2 rounded-lg shadow-lg"
      toast.textContent = "Request to speak sent"
      document.body.appendChild(toast)
      setTimeout(() => toast.remove(), 3000)
    } catch (err) {
      this._showError("Failed to send request")
    }
  }

  // ─── Hierarchical Voice: UI Helpers ──────────────────────────

  _updateHierarchyButtons() {
    const hasChildren = this._childChannels.length > 0
    const hasParent = this._ancestorRooms.size > 0

    if (this.hasBroadcastBtnTarget) {
      this.broadcastBtnTarget.classList.toggle("hidden", !hasChildren)
      this.broadcastBtnTarget.classList.toggle("flex", hasChildren)
    }

    if (this.hasRequestSpeakBtnTarget) {
      this.requestSpeakBtnTarget.classList.toggle("hidden", !hasParent)
      this.requestSpeakBtnTarget.classList.toggle("flex", hasParent)
    }

    // Show the row only if at least one button is visible
    if (this.hasHierarchyRowTarget) {
      const show = hasChildren || hasParent
      this.hierarchyRowTarget.classList.toggle("hidden", !show)
      this.hierarchyRowTarget.classList.toggle("flex", show)
    }

    this._updateBroadcastIcon()
  }
}

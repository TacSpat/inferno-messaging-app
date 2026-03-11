import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["canvas", "icon", "flamePath", "title", "subtitle"]
  static values = {
    level: String,
    saveUrl: String
  }

  static TEXT = {
    standard: ["Firewall Active", "Full protection is on. Harmful images, spam, and unknown senders are blocked."],
    relaxed:  ["Firewall Lowered", "Image protection stays on. Spam and sender filtering are off."]
  }

  connect() {
    this.ctx = this.canvasTarget.getContext("2d")
    this.level = this.levelValue
    this.running = true
    this.particles = []
    this.spawnAccum = 0
    this.frame = 0
    this.flashAlpha = 0
    this.flashDecay = 0
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    this.CW = 300
    this.CH = 330
    const dpr = window.devicePixelRatio || 1
    this.canvasTarget.width = this.CW * dpr
    this.canvasTarget.height = this.CH * dpr
    this.canvasTarget.style.width = this.CW + "px"
    this.canvasTarget.style.height = this.CH + "px"
    this.ctx.scale(dpr, dpr)

    this.SHIELD_CX = this.CW / 2
    this.SHIELD_CY = this.CH / 2 + 20
    this.FLAME_CX = this.SHIELD_CX
    this.FLAME_CY = this.SHIELD_CY + 3

    this.initStillAshes()
    this.setText(this.level)
    this.tick = this.tick.bind(this)
    requestAnimationFrame(this.tick)
  }

  disconnect() {
    this.running = false
  }

  setText(l) {
    const text = this.constructor.TEXT[l]
    this.titleTarget.textContent = text[0]
    this.subtitleTarget.textContent = text[1]
  }

  crossfadeText(l) {
    this.titleTarget.style.opacity = "0"
    this.subtitleTarget.style.opacity = "0"
    setTimeout(() => {
      this.setText(l)
      this.titleTarget.style.opacity = ""
      this.subtitleTarget.style.opacity = ""
    }, 400)
  }

  // ── Hearth beat ──

  hearthBeat(frame) {
    const slow   = Math.sin(frame * 0.007) * 0.5 + 0.5
    const medium = Math.sin(frame * 0.019 + 1.2) * 0.3 + 0.5
    const fast   = Math.sin(frame * 0.05 + 2.7) * 0.1 + 0.5
    return slow * 0.6 + medium * 0.28 + fast * 0.12
  }

  applyHearthBeat(beat) {
    const fp = this.flamePathTarget
    fp.style.fillOpacity = 0.55 + beat * 0.45
    fp.style.stroke = `rgba(251,191,36,${0.3 + beat * 0.7})`
    fp.style.filter = `drop-shadow(0 0 ${2 + beat * 6}px rgba(249,115,22,${0.2 + beat * 0.4}))`

    const ctx = this.ctx
    const glowRadius = 60 + beat * 50
    const glowAlpha = 0.1 + beat * 0.18
    ctx.save()
    const grad = ctx.createRadialGradient(this.FLAME_CX, this.FLAME_CY, 0, this.FLAME_CX, this.FLAME_CY, glowRadius)
    grad.addColorStop(0, `rgba(249,115,22,${glowAlpha.toFixed(3)})`)
    grad.addColorStop(0.5, `rgba(220,38,38,${(glowAlpha * 0.4).toFixed(3)})`)
    grad.addColorStop(1, "transparent")
    ctx.globalCompositeOperation = "lighter"
    ctx.fillStyle = grad
    ctx.beginPath()
    ctx.arc(this.FLAME_CX, this.FLAME_CY, glowRadius, 0, Math.PI * 2)
    ctx.fill()
    ctx.restore()
    ctx.globalCompositeOperation = "source-over"
  }

  // ── Embers (standard mode) ──

  spawnEmber(beat) {
    const t = Math.random()
    const spreadX = (Math.random() - 0.5) * 36
    const intensity = 0.6 + beat * 0.4
    this.particles.push({
      type: "ember",
      x: this.SHIELD_CX + spreadX,
      y: this.SHIELD_CY - 5 + Math.random() * 8,
      vx: (Math.random() - 0.5) * 0.3,
      vy: -(0.15 + Math.random() * 0.4) * intensity,
      wobbleAmp: 0.08 + Math.random() * 0.25,
      wobbleFreq: 0.012 + Math.random() * 0.018,
      wobblePhase: Math.random() * Math.PI * 2,
      age: 0,
      lifespan: 110 + Math.random() * 100,
      size: (1 + Math.random() * 1.6) * intensity,
      r: 200 + t * 55,
      g: 70 + t * 120,
      b: 8 + Math.random() * 25,
      maxAlpha: (0.35 + Math.random() * 0.35) * intensity
    })
  }

  // ── Windblown ash (relaxed mode) ──

  spawnAsh() {
    const startY = 30 + Math.random() * (this.CH - 80)
    const t = Math.random()
    const warm = Math.random() < 0.15
    this.particles.push({
      type: "ash",
      x: -5 - Math.random() * 20,
      y: startY,
      vx: 0.5 + Math.random() * 0.8,
      vy: -0.1 + (Math.random() - 0.5) * 0.3,
      tumble: Math.random() * Math.PI * 2,
      tumbleSpeed: 0.02 + Math.random() * 0.04,
      flutterAmp: 0.3 + Math.random() * 0.6,
      flutterFreq: 0.015 + Math.random() * 0.025,
      flutterPhase: Math.random() * Math.PI * 2,
      age: 0,
      lifespan: 200 + Math.random() * 120,
      sizeW: 1 + Math.random() * 2.5,
      sizeH: 0.5 + Math.random() * 1,
      r: warm ? 140 + t * 40 : 130 + t * 50,
      g: warm ? 90 + t * 20 : 125 + t * 45,
      b: warm ? 70 + t * 15 : 120 + t * 45,
      maxAlpha: 0.15 + Math.random() * 0.2
    })
  }

  // ── Still glowing ashes (relaxed mode) ──

  initStillAshes() {
    this.stillAshes = []
    for (let i = 0; i < 12; i++) {
      const angle = Math.random() * Math.PI * 2
      const dist = 30 + Math.random() * 45
      this.stillAshes.push({
        x: this.SHIELD_CX + Math.cos(angle) * dist,
        y: this.SHIELD_CY + Math.sin(angle) * dist + 10,
        size: 0.8 + Math.random() * 1.5,
        pulseSpeed: 0.008 + Math.random() * 0.015,
        pulsePhase: Math.random() * Math.PI * 2,
        baseAlpha: 0.08 + Math.random() * 0.15,
        warm: Math.random() < 0.4
      })
    }
  }

  drawStillAshes(frame) {
    const ctx = this.ctx
    this.stillAshes.forEach(a => {
      const pulse = Math.sin(frame * a.pulseSpeed + a.pulsePhase) * 0.5 + 0.5
      const alpha = a.baseAlpha + pulse * 0.12
      const r = a.warm ? 160 + pulse * 40 : 120
      const g = a.warm ? 80 + pulse * 20 : 110
      const b = a.warm ? 30 : 105

      if (a.warm) {
        ctx.globalCompositeOperation = "lighter"
        ctx.beginPath()
        ctx.arc(a.x, a.y, a.size * 3, 0, Math.PI * 2)
        ctx.fillStyle = `rgba(${r},${g | 0},${b},${(alpha * 0.06).toFixed(3)})`
        ctx.fill()
        ctx.globalCompositeOperation = "source-over"
      }

      ctx.beginPath()
      ctx.arc(a.x, a.y, a.size, 0, Math.PI * 2)
      ctx.fillStyle = `rgba(${r | 0},${g | 0},${b | 0},${alpha.toFixed(3)})`
      ctx.fill()
    })
  }

  // ── Transition effects ──

  whoosh() {
    this.particles.forEach(p => {
      if (p.type === "ember") {
        p.vx += 2.5 + Math.random() * 2
        p.vy -= 0.5 + Math.random() * 1
        p.lifespan = p.age + 20 + Math.random() * 25
      }
    })
    for (let i = 0; i < 8; i++) {
      const t = Math.random()
      this.particles.push({
        type: "ember",
        x: this.FLAME_CX + (Math.random() - 0.5) * 16,
        y: this.FLAME_CY + (Math.random() - 0.5) * 12,
        vx: 1.5 + Math.random() * 2.5,
        vy: -(0.3 + Math.random() * 0.8),
        wobbleAmp: 0.1, wobbleFreq: 0.02, wobblePhase: Math.random() * Math.PI * 2,
        age: 0,
        lifespan: 30 + Math.random() * 30,
        size: 0.8 + Math.random() * 1.2,
        r: 160 + t * 40, g: 100 + t * 40, b: 60 + t * 30,
        maxAlpha: 0.2 + Math.random() * 0.2
      })
    }
  }

  combust() {
    this.flashAlpha = 0.6
    this.flashDecay = 0.03
    for (let i = 0; i < 50; i++) {
      const angle = Math.random() * Math.PI * 2
      const speed = 0.8 + Math.random() * 2.5
      const t = Math.random()
      this.particles.push({
        type: "ember",
        x: this.FLAME_CX,
        y: this.FLAME_CY,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed - 1,
        wobbleAmp: 0.1 + Math.random() * 0.2,
        wobbleFreq: 0.02 + Math.random() * 0.02,
        wobblePhase: Math.random() * Math.PI * 2,
        age: 0,
        lifespan: 50 + Math.random() * 70,
        size: 1.2 + Math.random() * 2.2,
        r: 240 + t * 15, g: 140 + t * 80, b: 10 + Math.random() * 40,
        maxAlpha: 0.5 + Math.random() * 0.5
      })
    }
  }

  drawFlash() {
    if (this.flashAlpha <= 0) return
    const ctx = this.ctx
    const grad = ctx.createRadialGradient(this.FLAME_CX, this.FLAME_CY, 0, this.FLAME_CX, this.FLAME_CY, 90)
    grad.addColorStop(0, `rgba(255,200,50,${this.flashAlpha.toFixed(3)})`)
    grad.addColorStop(0.4, `rgba(249,115,22,${(this.flashAlpha * 0.5).toFixed(3)})`)
    grad.addColorStop(1, "transparent")
    ctx.globalCompositeOperation = "lighter"
    ctx.fillStyle = grad
    ctx.beginPath()
    ctx.arc(this.FLAME_CX, this.FLAME_CY, 90, 0, Math.PI * 2)
    ctx.fill()
    ctx.globalCompositeOperation = "source-over"
    this.flashAlpha -= this.flashDecay
    if (this.flashAlpha < 0) this.flashAlpha = 0
  }

  // ── Render loop ──

  alphaEnvelope(t, maxAlpha) {
    if (t < 0.15) {
      const n = t / 0.15
      return maxAlpha * n * n
    } else if (t < 0.55) {
      return maxAlpha
    } else {
      const n = (t - 0.55) / 0.45
      return maxAlpha * (1 - n * n)
    }
  }

  tick() {
    if (!this.running) return
    this.frame++
    const ctx = this.ctx
    ctx.clearRect(0, 0, this.CW, this.CH)
    this.drawFlash()

    const isStandard = this.level === "standard"
    const beat = this.hearthBeat(this.frame)

    if (isStandard) {
      this.applyHearthBeat(beat)
    } else {
      this.drawStillAshes(this.frame)
    }

    const rate = isStandard ? 0.18 + beat * 0.3 : 0.18
    this.spawnAccum += rate
    while (this.spawnAccum >= 1) {
      isStandard ? this.spawnEmber(beat) : this.spawnAsh()
      this.spawnAccum -= 1
    }

    this.particles = this.particles.filter(p => {
      p.age++
      const t = p.age / p.lifespan
      if (t >= 1) return false

      const alpha = this.alphaEnvelope(t, p.maxAlpha)

      if (p.type === "ember") {
        p.vy *= 0.997
        p.x += p.vx + Math.sin(p.age * p.wobbleFreq + p.wobblePhase) * p.wobbleAmp
        p.y += p.vy
        const size = p.size * (t < 0.65 ? 1 : 1 - (t - 0.65) / 0.35 * 0.5)

        ctx.globalCompositeOperation = "lighter"
        ctx.beginPath()
        ctx.arc(p.x, p.y, size * 2.8, 0, Math.PI * 2)
        ctx.fillStyle = `rgba(${p.r | 0},${p.g | 0},${p.b | 0},${(alpha * 0.08).toFixed(3)})`
        ctx.fill()
        ctx.beginPath()
        ctx.arc(p.x, p.y, size, 0, Math.PI * 2)
        ctx.fillStyle = `rgba(${p.r | 0},${p.g | 0},${p.b | 0},${alpha.toFixed(3)})`
        ctx.fill()
        ctx.globalCompositeOperation = "source-over"

      } else {
        p.tumble += p.tumbleSpeed
        const flutter = Math.sin(p.age * p.flutterFreq + p.flutterPhase) * p.flutterAmp
        p.x += p.vx
        p.y += p.vy + flutter * 0.15
        const apparentW = p.sizeW * Math.abs(Math.cos(p.tumble))

        ctx.save()
        ctx.translate(p.x, p.y)
        ctx.rotate(p.tumble * 0.3)
        ctx.globalAlpha = alpha
        ctx.fillStyle = `rgb(${p.r | 0},${p.g | 0},${p.b | 0})`
        ctx.beginPath()
        ctx.ellipse(0, 0, Math.max(0.4, apparentW), p.sizeH, 0, 0, Math.PI * 2)
        ctx.fill()
        ctx.restore()
        ctx.globalAlpha = 1
      }

      return true
    })

    requestAnimationFrame(this.tick)
  }

  // ── Toggle action ──

  toggle() {
    const newLevel = this.level === "standard" ? "relaxed" : "standard"
    const wasStandard = this.level === "standard"

    this.element.dataset.level = newLevel
    this.level = newLevel

    if (wasStandard) {
      this.whoosh()
      const fp = this.flamePathTarget
      fp.style.fillOpacity = ""
      fp.style.stroke = ""
      fp.style.filter = ""
    } else {
      this.combust()
    }

    this.crossfadeText(newLevel)

    fetch(this.saveUrlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      body: "safety_protection_level=" + newLevel
    })
  }
}

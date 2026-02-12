// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/swarmshield"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Handle clipboard copy events from LiveView
window.addEventListener("phx:clipboard:copy", (event) => {
  const text = event.detail.text
  if (text && navigator.clipboard) {
    navigator.clipboard.writeText(text)
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// ============================================================
// Landing Page: Globe Animation (Canvas 2D) — Futuristic
// ============================================================
function initGlobeAnimation(canvas) {
  const ctx = canvas.getContext("2d")
  let width, height, centerX, centerY, radius
  let rotation = 0
  let scanAngle = 0
  let animId = null
  const threats = []
  const particles = []
  const ambientParticles = []
  const shieldRipples = []
  const TWO_PI = Math.PI * 2

  function resize() {
    const rect = canvas.parentElement.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    width = rect.width
    height = rect.height
    canvas.width = width * dpr
    canvas.height = height * dpr
    canvas.style.width = width + "px"
    canvas.style.height = height + "px"
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    centerX = width / 2
    centerY = height / 2
    radius = Math.min(width, height) * 0.32
  }

  function getThemeColors() {
    const isDark = document.documentElement.getAttribute("data-theme") === "dark"
    return {
      grid: isDark ? "rgba(80,140,255,0.15)" : "rgba(60,100,200,0.12)",
      gridBright: isDark ? "rgba(100,160,255,0.30)" : "rgba(60,120,220,0.22)",
      shield: isDark ? "rgba(80,160,255,0.60)" : "rgba(50,120,230,0.50)",
      shieldGlow: isDark ? "rgba(80,160,255,0.20)" : "rgba(50,120,230,0.14)",
      shieldSeg: isDark ? "rgba(100,180,255,0.50)" : "rgba(60,140,230,0.35)",
      coreInner: isDark ? "rgba(60,140,255,0.10)" : "rgba(40,100,220,0.07)",
      coreOuter: isDark ? "rgba(80,160,255,0.04)" : "rgba(50,120,230,0.02)",
      threatIn: isDark ? "rgba(255,80,60,0.9)" : "rgba(230,50,30,0.8)",
      threatOut: isDark ? "rgba(60,220,140,0.9)" : "rgba(30,190,100,0.8)",
      particle: isDark ? "rgba(80,200,255,0.9)" : "rgba(50,150,230,0.8)",
      node: isDark ? "rgba(120,200,255,0.85)" : "rgba(60,140,230,0.75)",
      nodeLink: isDark ? "rgba(100,180,255,0.40)" : "rgba(60,140,220,0.30)",
      orbit: isDark ? "rgba(100,170,255,0.30)" : "rgba(60,130,220,0.22)",
      orbitDot: isDark ? "rgba(140,200,255,0.90)" : "rgba(80,160,230,0.80)",
      scanEdge: isDark ? "rgba(255,60,40,0.70)" : "rgba(220,40,20,0.55)",
      scanMid: isDark ? "rgba(255,100,60,0.35)" : "rgba(220,70,40,0.25)",
      scanFade: isDark ? "rgba(255,40,20,0.08)" : "rgba(200,30,10,0.05)",
      ambient: isDark ? "rgba(160,210,255,0.60)" : "rgba(100,160,230,0.45)",
      ripple: isDark ? "rgba(100,200,255,0.75)" : "rgba(60,160,230,0.60)",
      hexLine: isDark ? "rgba(80,160,255,0.35)" : "rgba(50,120,230,0.25)",
    }
  }

  // Pre-generate surface node positions for consistent rendering
  const surfaceNodes = []
  for (let i = 0; i < 14; i++) {
    surfaceNodes.push({
      lat: (Math.random() - 0.5) * Math.PI * 0.8,
      lon: Math.random() * TWO_PI,
      pulseOffset: Math.random() * TWO_PI,
      size: 2 + Math.random() * 2,
    })
  }

  // Pre-generate ambient star field
  function initAmbient() {
    const count = 60
    for (let i = 0; i < count; i++) {
      ambientParticles.push({
        x: Math.random() * 2 - 1, // normalized -1 to 1
        y: Math.random() * 2 - 1,
        size: 0.5 + Math.random() * 1.5,
        speed: 0.0002 + Math.random() * 0.0005,
        phase: Math.random() * TWO_PI,
        drift: (Math.random() - 0.5) * 0.0003,
      })
    }
  }

  // ---- Core glow ----
  function drawCoreGlow(colors) {
    const grad = ctx.createRadialGradient(
      centerX, centerY, 0,
      centerX, centerY, radius * 0.9
    )
    grad.addColorStop(0, colors.coreInner)
    grad.addColorStop(0.6, colors.coreOuter)
    grad.addColorStop(1, "transparent")
    ctx.beginPath()
    ctx.arc(centerX, centerY, radius * 0.9, 0, TWO_PI)
    ctx.fillStyle = grad
    ctx.fill()
  }

  // ---- Wireframe globe with hex-inspired grid ----
  function drawGlobe(colors) {
    const latLines = 8
    const lonLines = 16

    // Latitude rings
    ctx.lineWidth = 0.5
    for (let i = 1; i < latLines; i++) {
      const lat = (Math.PI / latLines) * i - Math.PI / 2
      const r = radius * Math.cos(lat)
      const y = centerY + radius * Math.sin(lat)
      // Vary opacity per ring for depth
      const dist = Math.abs(i - latLines / 2) / (latLines / 2)
      ctx.strokeStyle = colors.grid
      ctx.globalAlpha = 0.4 + dist * 0.4
      ctx.beginPath()
      ctx.ellipse(centerX, y, Math.abs(r), Math.abs(r) * 0.3, 0, 0, TWO_PI)
      ctx.stroke()
    }
    ctx.globalAlpha = 1

    // Longitude arcs (front-facing only)
    ctx.strokeStyle = colors.grid
    ctx.lineWidth = 0.5
    for (let i = 0; i < lonLines; i++) {
      const lon = (TWO_PI / lonLines) * i + rotation
      ctx.beginPath()
      let drawing = false
      for (let j = 0; j <= 64; j++) {
        const lat = (Math.PI / 64) * j - Math.PI / 2
        const x = centerX + radius * Math.cos(lat) * Math.sin(lon)
        const y = centerY + radius * Math.sin(lat)
        const z = Math.cos(lat) * Math.cos(lon)
        if (z < -0.05) { drawing = false; continue }
        if (!drawing) { ctx.moveTo(x, y); drawing = true }
        else ctx.lineTo(x, y)
      }
      ctx.stroke()
    }

    // Hex accent marks at intersections (front-facing)
    ctx.fillStyle = colors.gridBright
    for (let li = 1; li < latLines; li++) {
      const lat = (Math.PI / latLines) * li - Math.PI / 2
      for (let lo = 0; lo < lonLines; lo += 2) {
        const lon = (TWO_PI / lonLines) * lo + rotation
        const z = Math.cos(lat) * Math.cos(lon)
        if (z < 0.1) continue
        const x = centerX + radius * Math.cos(lat) * Math.sin(lon)
        const y = centerY + radius * Math.sin(lat)
        ctx.globalAlpha = z * 0.5
        drawHexDot(x, y, 2)
      }
    }
    ctx.globalAlpha = 1
  }

  function drawHexDot(x, y, r) {
    ctx.beginPath()
    for (let i = 0; i < 6; i++) {
      const a = (TWO_PI / 6) * i - Math.PI / 6
      const px = x + r * Math.cos(a)
      const py = y + r * Math.sin(a)
      if (i === 0) ctx.moveTo(px, py)
      else ctx.lineTo(px, py)
    }
    ctx.closePath()
    ctx.fill()
  }

  // ---- Surface nodes with connection lines ----
  function drawNodes(colors, time) {
    const projected = []
    for (const node of surfaceNodes) {
      const lon = node.lon + rotation
      const z = Math.cos(node.lat) * Math.cos(lon)
      if (z < 0.05) continue
      const x = centerX + radius * Math.cos(node.lat) * Math.sin(lon)
      const y = centerY + radius * Math.sin(node.lat)
      const pulse = 0.6 + 0.4 * Math.sin(time * 0.003 + node.pulseOffset)
      projected.push({ x, y, z, size: node.size, pulse })
    }

    // Connection lines between nearby visible nodes
    ctx.strokeStyle = colors.nodeLink
    ctx.lineWidth = 1.5
    for (let i = 0; i < projected.length; i++) {
      for (let j = i + 1; j < projected.length; j++) {
        const dx = projected[i].x - projected[j].x
        const dy = projected[i].y - projected[j].y
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist < radius * 1.0) {
          ctx.globalAlpha = (1 - dist / (radius * 1.0)) * 0.85 * Math.min(projected[i].z, projected[j].z)
          ctx.beginPath()
          ctx.moveTo(projected[i].x, projected[i].y)
          ctx.lineTo(projected[j].x, projected[j].y)
          ctx.stroke()
        }
      }
    }
    ctx.globalAlpha = 1

    // Draw nodes with glow
    for (const p of projected) {
      const glowR = p.size * 5 * p.pulse
      const grad = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, glowR)
      grad.addColorStop(0, colors.node)
      grad.addColorStop(1, "transparent")
      ctx.globalAlpha = p.z * 0.7
      ctx.beginPath()
      ctx.arc(p.x, p.y, glowR, 0, TWO_PI)
      ctx.fillStyle = grad
      ctx.fill()

      ctx.globalAlpha = p.z * p.pulse
      ctx.beginPath()
      ctx.arc(p.x, p.y, p.size * 1.3, 0, TWO_PI)
      ctx.fillStyle = colors.node
      ctx.fill()
    }
    ctx.globalAlpha = 1
  }

  // ---- Orbit rings ----
  function drawOrbits(colors) {
    const orbits = [
      { tilt: 0.3, yScale: 0.22, r: radius * 1.35, speed: 0.6 },
      { tilt: -0.5, yScale: 0.28, r: radius * 1.52, speed: -0.4 },
      { tilt: 0.15, yScale: 0.18, r: radius * 1.68, speed: 0.3 },
    ]
    for (const orb of orbits) {
      ctx.save()
      ctx.translate(centerX, centerY)
      ctx.rotate(orb.tilt)

      // Bold dashed ring
      ctx.strokeStyle = colors.orbit
      ctx.lineWidth = 1.5
      ctx.setLineDash([6, 10])
      ctx.beginPath()
      ctx.ellipse(0, 0, orb.r, orb.r * orb.yScale, 0, 0, TWO_PI)
      ctx.stroke()
      ctx.setLineDash([])

      // Orbiting dot with glow trail
      const dotAngle = rotation * orb.speed * 2
      const dx = orb.r * Math.cos(dotAngle)
      const dy = orb.r * orb.yScale * Math.sin(dotAngle)

      // Glow halo around dot
      const dotGlow = ctx.createRadialGradient(dx, dy, 0, dx, dy, 14)
      dotGlow.addColorStop(0, colors.orbitDot)
      dotGlow.addColorStop(1, "transparent")
      ctx.beginPath()
      ctx.arc(dx, dy, 14, 0, TWO_PI)
      ctx.fillStyle = dotGlow
      ctx.globalAlpha = 0.5
      ctx.fill()

      // Solid dot
      ctx.beginPath()
      ctx.arc(dx, dy, 4, 0, TWO_PI)
      ctx.fillStyle = colors.orbitDot
      ctx.globalAlpha = 1
      ctx.fill()

      ctx.restore()
    }
  }

  // ---- Hexagonal shield segments ----
  function drawShield(colors, time) {
    const shieldR = radius * 1.18
    const segments = 24
    const gapAngle = 0.02

    // Outer glow ring
    const glow = ctx.createRadialGradient(
      centerX, centerY, shieldR - 12,
      centerX, centerY, shieldR + 20
    )
    glow.addColorStop(0, "transparent")
    glow.addColorStop(0.4, colors.shieldGlow)
    glow.addColorStop(1, "transparent")
    ctx.beginPath()
    ctx.arc(centerX, centerY, shieldR + 10, 0, TWO_PI)
    ctx.fillStyle = glow
    ctx.fill()

    // Segmented arcs
    const segArc = TWO_PI / segments
    for (let i = 0; i < segments; i++) {
      const startA = segArc * i + gapAngle
      const endA = segArc * (i + 1) - gapAngle
      const pulse = 0.4 + 0.6 * Math.sin(time * 0.002 + i * 0.7)
      ctx.beginPath()
      ctx.arc(centerX, centerY, shieldR, startA, endA)
      ctx.strokeStyle = colors.shieldSeg
      ctx.globalAlpha = pulse
      ctx.lineWidth = 2.5
      ctx.stroke()
    }
    ctx.globalAlpha = 1

    // Inner thin ring
    ctx.beginPath()
    ctx.arc(centerX, centerY, shieldR - 6, 0, TWO_PI)
    ctx.strokeStyle = colors.shield
    ctx.lineWidth = 0.5
    ctx.globalAlpha = 0.3
    ctx.stroke()
    ctx.globalAlpha = 1
  }

  // ---- Scanning beam (bold red radar sweep triangle) ----
  function drawScanBeam(colors) {
    const shieldR = radius * 1.18
    const beamWidth = 0.8 // radians — the sweep wedge width
    const slices = 30 // draw many thin wedge slices for smooth gradient

    ctx.save()
    ctx.translate(centerX, centerY)

    // Draw the wedge as thin slices, trailing edge = transparent, leading edge = bold red
    for (let i = 0; i < slices; i++) {
      const t = i / slices // 0 = trailing edge, 1 = leading edge
      const sliceStart = scanAngle - beamWidth + (beamWidth / slices) * i
      const sliceEnd = sliceStart + (beamWidth / slices) + 0.005 // tiny overlap to avoid gaps

      // Cubic ease-in: faint at tail, strong at front
      const alpha = t * t * t
      ctx.beginPath()
      ctx.moveTo(0, 0)
      ctx.arc(0, 0, shieldR, sliceStart, sliceEnd)
      ctx.closePath()
      ctx.fillStyle = colors.scanEdge
      ctx.globalAlpha = alpha * 0.7
      ctx.fill()
    }
    ctx.globalAlpha = 1

    // Sharp leading edge line
    const edgeX = shieldR * Math.cos(scanAngle)
    const edgeY = shieldR * Math.sin(scanAngle)
    ctx.beginPath()
    ctx.moveTo(0, 0)
    ctx.lineTo(edgeX, edgeY)
    ctx.strokeStyle = colors.scanEdge
    ctx.lineWidth = 2.5
    ctx.stroke()

    // Bright glow dot at tip
    const tipGlow = ctx.createRadialGradient(edgeX, edgeY, 0, edgeX, edgeY, 14)
    tipGlow.addColorStop(0, colors.scanEdge)
    tipGlow.addColorStop(1, "transparent")
    ctx.beginPath()
    ctx.arc(edgeX, edgeY, 14, 0, TWO_PI)
    ctx.fillStyle = tipGlow
    ctx.fill()

    ctx.restore()
  }

  // ---- Shield ripple effect on impact ----
  function drawRipples(colors) {
    for (let i = shieldRipples.length - 1; i >= 0; i--) {
      const r = shieldRipples[i]
      r.radius += 2.5
      r.alpha -= 0.025
      if (r.alpha <= 0) { shieldRipples.splice(i, 1); continue }

      // Draw hex-shaped ripple
      ctx.save()
      ctx.translate(r.x, r.y)
      ctx.beginPath()
      for (let h = 0; h < 6; h++) {
        const a = (TWO_PI / 6) * h
        const px = r.radius * Math.cos(a)
        const py = r.radius * Math.sin(a)
        if (h === 0) ctx.moveTo(px, py)
        else ctx.lineTo(px, py)
      }
      ctx.closePath()
      ctx.strokeStyle = colors.ripple
      ctx.globalAlpha = r.alpha
      ctx.lineWidth = 2.5
      ctx.stroke()
      ctx.restore()
    }
    ctx.globalAlpha = 1
  }

  // ---- Ambient particle field ----
  function drawAmbient(colors, time) {
    for (const p of ambientParticles) {
      const x = centerX + p.x * width * 0.5
      const y = centerY + p.y * height * 0.5
      const twinkle = 0.4 + 0.6 * Math.sin(time * p.speed * 50 + p.phase)

      // Glow halo
      const gR = p.size * 4
      const glow = ctx.createRadialGradient(x, y, 0, x, y, gR)
      glow.addColorStop(0, colors.ambient)
      glow.addColorStop(1, "transparent")
      ctx.globalAlpha = twinkle * 0.35
      ctx.beginPath()
      ctx.arc(x, y, gR, 0, TWO_PI)
      ctx.fillStyle = glow
      ctx.fill()

      // Bright core
      ctx.globalAlpha = twinkle * 0.8
      ctx.beginPath()
      ctx.arc(x, y, p.size * 1.2, 0, TWO_PI)
      ctx.fillStyle = colors.ambient
      ctx.fill()

      // Slow drift
      p.x += p.drift
      p.y += p.drift * 0.6
      if (p.x > 1.1) p.x = -1.1
      if (p.x < -1.1) p.x = 1.1
      if (p.y > 1.1) p.y = -1.1
      if (p.y < -1.1) p.y = 1.1
    }
    ctx.globalAlpha = 1
  }

  // ---- Threat spawning ----
  function spawnThreat() {
    const angle = Math.random() * TWO_PI
    const edgeDist = Math.max(width, height) * 0.6
    const speed = 1.2 + Math.random() * 2.5
    threats.push({
      x: centerX + Math.cos(angle) * edgeDist,
      y: centerY + Math.sin(angle) * edgeDist,
      angle: angle + Math.PI,
      speed,
      trail: [],
      deflected: false,
      deflectAngle: 0,
      alpha: 1,
      size: 2 + Math.random() * 2,
    })
  }

  function spawnBurst() {
    const count = 3 + Math.floor(Math.random() * 5)
    const baseAngle = Math.random() * TWO_PI
    const spread = 0.4
    for (let i = 0; i < count; i++) {
      const angle = baseAngle + (Math.random() - 0.5) * spread
      const edgeDist = Math.max(width, height) * 0.6
      const speed = 1.5 + Math.random() * 2
      threats.push({
        x: centerX + Math.cos(angle) * edgeDist,
        y: centerY + Math.sin(angle) * edgeDist,
        angle: angle + Math.PI,
        speed,
        trail: [],
        deflected: false,
        deflectAngle: 0,
        alpha: 1,
        size: 2 + Math.random() * 2,
      })
    }
  }

  const MAX_TRAIL = 40

  function updateThreats(colors) {
    const shieldR = radius * 1.18
    for (let i = threats.length - 1; i >= 0; i--) {
      const t = threats[i]
      t.trail.push({ x: t.x, y: t.y })
      if (t.trail.length > MAX_TRAIL) t.trail.shift()

      if (!t.deflected) {
        t.x += Math.cos(t.angle) * t.speed
        t.y += Math.sin(t.angle) * t.speed
        const dx = t.x - centerX
        const dy = t.y - centerY
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist <= shieldR) {
          t.deflected = true
          const normal = Math.atan2(dy, dx)
          t.deflectAngle = normal + (Math.random() - 0.5) * 1.2

          // Hex ripple at impact point
          shieldRipples.push({
            x: t.x, y: t.y,
            radius: 4, alpha: 0.8,
          })

          // Particle burst
          const burstCount = 6 + Math.floor(Math.random() * 8)
          for (let p = 0; p < burstCount; p++) {
            const sp = (Math.random() - 0.5) * 2.5
            const vel = 1.5 + Math.random() * 3
            particles.push({
              x: t.x, y: t.y,
              vx: Math.cos(normal + sp) * vel,
              vy: Math.sin(normal + sp) * vel,
              life: 0.6 + Math.random() * 0.5,
            })
          }
        }
      } else {
        t.x += Math.cos(t.deflectAngle) * t.speed * 1.5
        t.y += Math.sin(t.deflectAngle) * t.speed * 1.5
        t.alpha -= 0.018
      }

      if (t.alpha <= 0 || t.x < -80 || t.x > width + 80 || t.y < -80 || t.y > height + 80) {
        threats.splice(i, 1)
        continue
      }

      const color = t.deflected ? colors.threatOut : colors.threatIn

      // Trail with gradient fade
      if (t.trail.length > 1) {
        for (let j = 1; j < t.trail.length; j++) {
          const segAlpha = (j / t.trail.length) * t.alpha * 0.6
          ctx.beginPath()
          ctx.moveTo(t.trail[j - 1].x, t.trail[j - 1].y)
          ctx.lineTo(t.trail[j].x, t.trail[j].y)
          ctx.strokeStyle = color
          ctx.globalAlpha = segAlpha
          ctx.lineWidth = 1.5 * (j / t.trail.length)
          ctx.stroke()
        }
        ctx.beginPath()
        ctx.moveTo(t.trail[t.trail.length - 1].x, t.trail[t.trail.length - 1].y)
        ctx.lineTo(t.x, t.y)
        ctx.strokeStyle = color
        ctx.globalAlpha = t.alpha * 0.8
        ctx.lineWidth = 2
        ctx.stroke()
      }

      // Threat head with glow
      const headGlow = ctx.createRadialGradient(t.x, t.y, 0, t.x, t.y, t.size * 4)
      headGlow.addColorStop(0, color)
      headGlow.addColorStop(1, "transparent")
      ctx.globalAlpha = t.alpha * 0.3
      ctx.beginPath()
      ctx.arc(t.x, t.y, t.size * 4, 0, TWO_PI)
      ctx.fillStyle = headGlow
      ctx.fill()

      ctx.beginPath()
      ctx.arc(t.x, t.y, t.size, 0, TWO_PI)
      ctx.fillStyle = color
      ctx.globalAlpha = t.alpha
      ctx.fill()
      ctx.globalAlpha = 1
    }
  }

  function updateParticles(colors) {
    for (let i = particles.length - 1; i >= 0; i--) {
      const p = particles[i]
      p.x += p.vx
      p.y += p.vy
      p.vx *= 0.98
      p.vy *= 0.98
      p.life -= 0.025
      if (p.life <= 0) { particles.splice(i, 1); continue }
      ctx.beginPath()
      ctx.arc(p.x, p.y, 2.5 * p.life, 0, TWO_PI)
      ctx.fillStyle = colors.particle
      ctx.globalAlpha = p.life
      ctx.fill()
      ctx.globalAlpha = 1
    }
  }

  let frameCount = 0
  function animate() {
    const time = performance.now()
    ctx.clearRect(0, 0, width, height)
    const colors = getThemeColors()
    rotation += 0.003
    scanAngle += 0.012

    drawAmbient(colors, time)
    drawCoreGlow(colors)
    drawOrbits(colors)
    drawGlobe(colors)
    drawNodes(colors, time)
    drawScanBeam(colors)
    drawShield(colors, time)
    drawRipples(colors)
    updateThreats(colors)
    updateParticles(colors)

    frameCount++
    if (frameCount % 8 === 0 && threats.length < 50) spawnThreat()
    if (frameCount % 60 === 0 && threats.length < 40) spawnBurst()
    if (frameCount % 180 === 0) { spawnBurst(); spawnBurst() }

    animId = requestAnimationFrame(animate)
  }

  resize()
  window.addEventListener("resize", resize)
  initAmbient()
  for (let i = 0; i < 12; i++) spawnThreat()
  animate()

  return () => {
    cancelAnimationFrame(animId)
    window.removeEventListener("resize", resize)
  }
}

// ============================================================
// Landing Page: Scroll Reveal via IntersectionObserver
// ============================================================
function initScrollReveal() {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add("revealed")
        observer.unobserve(entry.target)
      }
    })
  }, { threshold: 0.1, rootMargin: "0px 0px -40px 0px" })

  document.querySelectorAll(".reveal-on-scroll").forEach(el => observer.observe(el))
}

// ============================================================
// Landing Page: Animated counters
// ============================================================
function initCounters() {
  const counters = document.querySelectorAll("[data-counter]")
  if (!counters.length) return

  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return
      const el = entry.target
      const target = el.getAttribute("data-counter")
      const prefix = el.getAttribute("data-prefix") || ""
      const suffix = el.getAttribute("data-suffix") || ""
      const isFloat = target.includes(".")
      const end = parseFloat(target)
      const duration = 1500
      const start = performance.now()

      function step(now) {
        const progress = Math.min((now - start) / duration, 1)
        const eased = 1 - Math.pow(1 - progress, 3)
        const current = eased * end
        el.textContent = prefix + (isFloat ? current.toFixed(1) : Math.round(current)) + suffix
        if (progress < 1) requestAnimationFrame(step)
      }
      requestAnimationFrame(step)
      observer.unobserve(el)
    })
  }, { threshold: 0.5 })

  counters.forEach(el => observer.observe(el))
}

// ============================================================
// Landing Page: Mobile nav toggle
// ============================================================
function initMobileNav() {
  const toggle = document.getElementById("landing-mobile-toggle")
  const menu = document.getElementById("landing-mobile-menu")
  const close = document.getElementById("landing-mobile-close")
  if (!toggle || !menu) return

  toggle.addEventListener("click", () => {
    menu.classList.toggle("hidden")
  })
  if (close) close.addEventListener("click", () => menu.classList.add("hidden"))

  menu.querySelectorAll("a[href^='#']").forEach(link => {
    link.addEventListener("click", () => menu.classList.add("hidden"))
  })
}

// ============================================================
// Landing Page: Initialize all
// ============================================================
document.addEventListener("DOMContentLoaded", () => {
  const globeCanvas = document.getElementById("globe-canvas")
  if (globeCanvas) initGlobeAnimation(globeCanvas)

  initScrollReveal()
  initCounters()
  initMobileNav()
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}


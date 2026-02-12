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
// Landing Page: Globe Animation (Canvas 2D)
// ============================================================
function initGlobeAnimation(canvas) {
  const ctx = canvas.getContext("2d")
  let width, height, centerX, centerY, radius
  let rotation = 0
  let animId = null
  const threats = []
  const particles = []
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
    radius = Math.min(width, height) * 0.35
  }

  function getThemeColors() {
    const style = getComputedStyle(document.documentElement)
    const isDark = document.documentElement.getAttribute("data-theme") === "dark"
    return {
      grid: isDark ? "rgba(140,160,255,0.12)" : "rgba(80,100,200,0.1)",
      shield: isDark ? "rgba(100,140,255,0.5)" : "rgba(60,100,220,0.4)",
      shieldGlow: isDark ? "rgba(100,140,255,0.15)" : "rgba(60,100,220,0.1)",
      threatIn: isDark ? "rgba(255,100,80,0.7)" : "rgba(220,60,40,0.6)",
      threatOut: isDark ? "rgba(80,200,160,0.7)" : "rgba(40,180,120,0.6)",
      particle: isDark ? "rgba(100,200,255,0.8)" : "rgba(60,140,220,0.7)",
      node: isDark ? "rgba(140,180,255,0.6)" : "rgba(80,120,220,0.5)",
    }
  }

  function drawGlobe(colors) {
    const latLines = 7
    const lonLines = 12

    ctx.strokeStyle = colors.grid
    ctx.lineWidth = 0.6

    for (let i = 1; i < latLines; i++) {
      const lat = (Math.PI / latLines) * i - Math.PI / 2
      const r = radius * Math.cos(lat)
      const y = centerY + radius * Math.sin(lat)
      ctx.beginPath()
      ctx.ellipse(centerX, y, Math.abs(r), Math.abs(r) * 0.3, 0, 0, TWO_PI)
      ctx.stroke()
    }

    for (let i = 0; i < lonLines; i++) {
      const lon = (TWO_PI / lonLines) * i + rotation
      ctx.beginPath()
      for (let j = 0; j <= 60; j++) {
        const lat = (Math.PI / 60) * j - Math.PI / 2
        const x = centerX + radius * Math.cos(lat) * Math.sin(lon)
        const y = centerY + radius * Math.sin(lat)
        const z = Math.cos(lat) * Math.cos(lon)
        if (z < -0.1) continue
        if (j === 0 || z < -0.05) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.stroke()
    }
  }

  function drawShield(colors) {
    const shieldRadius = radius * 1.15
    ctx.beginPath()
    ctx.arc(centerX, centerY, shieldRadius, 0, TWO_PI)
    ctx.strokeStyle = colors.shield
    ctx.lineWidth = 2
    ctx.stroke()

    const glow = ctx.createRadialGradient(
      centerX, centerY, shieldRadius - 8,
      centerX, centerY, shieldRadius + 12
    )
    glow.addColorStop(0, "transparent")
    glow.addColorStop(0.5, colors.shieldGlow)
    glow.addColorStop(1, "transparent")
    ctx.beginPath()
    ctx.arc(centerX, centerY, shieldRadius, 0, TWO_PI)
    ctx.fillStyle = glow
    ctx.fill()
  }

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
      size: 2 + Math.random() * 2
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
        size: 2 + Math.random() * 2
      })
    }
  }

  const MAX_TRAIL = 40

  function updateThreats(colors) {
    const shieldR = radius * 1.15
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
          const burstCount = 5 + Math.floor(Math.random() * 7)
          for (let p = 0; p < burstCount; p++) {
            const spread = (Math.random() - 0.5) * 2.5
            const vel = 1.5 + Math.random() * 3
            particles.push({
              x: t.x, y: t.y,
              vx: Math.cos(normal + spread) * vel,
              vy: Math.sin(normal + spread) * vel,
              life: 0.6 + Math.random() * 0.5
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
      p.life -= 0.03
      if (p.life <= 0) { particles.splice(i, 1); continue }
      ctx.beginPath()
      ctx.arc(p.x, p.y, 2 * p.life, 0, TWO_PI)
      ctx.fillStyle = colors.particle
      ctx.globalAlpha = p.life
      ctx.fill()
      ctx.globalAlpha = 1
    }
  }

  function drawNodes(colors) {
    const count = 8
    for (let i = 0; i < count; i++) {
      const angle = (TWO_PI / count) * i + rotation * 0.5
      const lat = Math.sin(angle * 2.3) * 0.6
      const x = centerX + radius * Math.cos(lat) * Math.sin(angle)
      const y = centerY + radius * Math.sin(lat) * 0.8
      const z = Math.cos(lat) * Math.cos(angle)
      if (z < 0) continue
      ctx.beginPath()
      ctx.arc(x, y, 3, 0, TWO_PI)
      ctx.fillStyle = colors.node
      ctx.fill()
    }
  }

  let frameCount = 0
  function animate() {
    ctx.clearRect(0, 0, width, height)
    const colors = getThemeColors()
    rotation += 0.004
    drawGlobe(colors)
    drawShield(colors)
    drawNodes(colors)
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


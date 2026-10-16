// The buddy's behavior and drawing. Each frame picks a target pose for the current mode, springs the
// displayed pose toward it, updates particles, and redraws. Mirrors BuddyController.swift + BuddyView.swift.
//
// Coordinates: x is px from the window's left edge, y is px UP from the window's bottom edge
// (the top of the taskbar). The window's bottom never moves, so these stay valid when it grows.
'use strict'

const canvas = document.getElementById('stage')
const ctx = canvas.getContext('2d')
const { PoseLibrary, Renderer } = Hero

let state = null
let look = Hero.presets[0]
let animator = new Hero.PoseAnimator()
let particles = []

let mode = { kind: 'idle', until: Date.now() + 3000 }
let x = window.innerWidth / 2
let y = 0
let vy = 0
let facingRight = true
let dragOffset = { x: 0, y: 0 }
let dragSwing = 0
let lastDragX = 0
let time = 0
let walkPhase = 0
let lastTick = performance.now()
let lastReminderCheck = 0
let nextEffect = 0
const alerted = new Set()
let transient = null           // { bubble, until }
let nag = null                 // { id, line, since }
let nextChatter = Date.now() + rand(240, 480) * 1000
let isThinking = false
let celebrateStage = 0
let frameCount = 0
let cursor = { x: -9999, y: -9999 }
let ignoring = true
let bubble = null
let bubbleRect = null
let audio = null

function rand(a, b) { return a + Math.random() * (b - a) }
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v))
const pick = (list) => (list && list.length ? list[Math.floor(Math.random() * list.length)] : null)

// MARK: - State

function lookFor(name) {
  const id = (name || '').replace(/^hero:/, '')
  return state.customHeroes.find(h => h.id === id) || Hero.preset(id) || Hero.presets[0]
}

const height = () => state ? state.buddyHeight : 180
const unit = () => height() / Renderer.height
const spriteWidth = () => Math.round(height() * Renderer.aspect)
const buddyName = () => look.name

function applyState(s, first) {
  const prevChar = state && state.selectedCharacter
  state = s
  look = lookFor(s.selectedCharacter)
  if (first) {
    if (s.isFirstLaunch) say(`Hi! I'm ${buddyName()} 👋`, 'double-click to chat · right-click for more', 8)
  } else if (prevChar !== s.selectedCharacter) {
    celebrate()
    say(`Hi, I'm ${buddyName()}! ✨`, null, 3)
  }
}

function reminder(id) { return state.reminders.find(r => r.id === id) }
const nextDue = (r) => r.lastDone + r.intervalMinutes * 60000

function isSuppressed() {
  if (state.pausedUntil && state.pausedUntil > Date.now()) return true
  if (!state.quietHoursEnabled || state.quietStart === state.quietEnd) return false
  const h = new Date().getHours()
  return state.quietStart < state.quietEnd
    ? h >= state.quietStart && h < state.quietEnd
    : h >= state.quietStart || h < state.quietEnd
}

function dueReminder() {
  if (isSuppressed()) return null
  const now = Date.now()
  return state.reminders.filter(r => r.enabled && nextDue(r) <= now).sort((a, b) => nextDue(a) - nextDue(b))[0] || null
}

function nextUpcoming() {
  return state.reminders.filter(r => r.enabled).sort((a, b) => nextDue(a) - nextDue(b))[0] || null
}

const pack = () => state.linePack
const nagLine = (r) => pick(pack()?.nag?.[r.id]) || `${r.emoji} ${r.message}`
const praiseLine = (r) => pick(pack()?.praise?.[r.id]) || pick(['Ahh, refreshing!', 'Nice one!', "You're doing great!", 'Proud of you!'])
const idleLine = () => pick(pack()?.idle)
const sleepyLine = () => pick(pack()?.sleepy) || 'Zzz… 💤'
const count = (id) => (state.countsDate === dayKey() ? state.todayCounts[id] || 0 : 0)
function dayKey(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// MARK: - Canvas

// The canvas is a narrow column that slides with the buddy, so each frame only repaints a small area.
const canvasWidth = () => Math.round(Math.max(380, height() * 1.7))
let canvasLeft = null

function resize() {
  const dpr = window.devicePixelRatio || 1
  const cw = canvasWidth()
  canvas.style.width = `${cw}px`
  canvas.width = Math.round(cw * dpr)
  canvas.height = Math.round(window.innerHeight * dpr)
  canvasLeft = null
}
window.addEventListener('resize', resize)

// MARK: - Tick

function step(target, speed, dt) {
  const dir = target >= x ? 1 : -1
  facingRight = dir > 0
  const delta = dir * speed * dt
  x += delta
  walkPhase += Math.abs(delta) / Math.max(40, height()) * 7.5
  if ((dir > 0 && x >= target) || (dir < 0 && x <= target)) { x = target; return true }
  return false
}

function tick(now) {
  requestAnimationFrame(tick)
  if (!state) return
  const dt = Math.min((now - lastTick) / 1000, 0.1)
  lastTick = now
  time += dt

  if (now - lastReminderCheck > 2000) {
    lastReminderCheck = now
    checkReminders()
  }

  const W = window.innerWidth
  const half = spriteWidth() / 2
  const speed = state.walkSpeed * Math.max(1, height() / 120)
  let target = PoseLibrary.idle(time)
  let shownBubble = null

  switch (mode.kind) {
    case 'idle':
      if (isSuppressed()) {
        target = PoseLibrary.sleep(time)
        emit(1.6, () => spawn('💤', 40, 230, 30, 12, 2.4, 26))
      } else {
        if (Date.now() >= nextChatter) {
          nextChatter = Date.now() + rand(420, 900) * 1000
          const line = idleLine()
          if (!transient && line) say(line, null, 5)
        }
        if (Date.now() >= mode.until) mode = { kind: 'walking', to: rand(half + 20, W - half - 20) }
      }
      break

    case 'walking':
      target = PoseLibrary.walk(walkPhase, time)
      if (step(mode.to, speed, dt)) mode = { kind: 'idle', until: Date.now() + rand(5, 14) * 1000 }
      break

    case 'reminding': {
      const r = reminder(mode.id)
      if (!r) { mode = { kind: 'idle', until: Date.now() }; break }
      // Pick a fresh line now and then so a long-ignored reminder doesn't repeat itself.
      if (!nag || nag.id !== mode.id || Date.now() - nag.since > 75000) nag = { id: mode.id, line: nagLine(r), since: Date.now() }
      shownBubble = { title: nag.line, subtitle: 'click me when done' }
      // Follow the cursor along the taskbar until noticed, then hop and wave.
      const mouseX = clamp(cursor.x, half, W - half)
      if (Math.abs(mouseX - x) > 160) {
        target = PoseLibrary.walk(walkPhase, time)
        step(mouseX, speed * 1.8, dt)
      } else {
        target = PoseLibrary.remind(time)
        emit(1.2, () => spawn('💧', 70, 200, 60, 30, 1.2, 22, -160))
      }
      break
    }

    case 'celebrating': {
      const t = (Date.now() - mode.started) / 1000
      if (t < PoseLibrary.drinkDuration) {
        target = PoseLibrary.drink(t, time)
        if (celebrateStage === 0 && t > 0.6) celebrateStage = 1
      } else if (t < PoseLibrary.drinkDuration + PoseLibrary.cheerDuration) {
        const c = t - PoseLibrary.drinkDuration
        target = PoseLibrary.cheer(c, time)
        if (celebrateStage === 1 && c > 0.25) {
          celebrateStage = 2
          for (let i = 0; i < 9; i++) {
            const a = i / 9 * Math.PI + 0.2
            spawn(['✨', '⭐️', '💖', '💧'][i % 4], 0, 160, Math.sin(a) * 260, Math.cos(a) * 220, 1.3, 24, -380)
          }
        }
      } else {
        mode = { kind: 'idle', until: Date.now() + 5000 }
      }
      break
    }

    case 'dragging': {
      const vx = (x - lastDragX) / Math.max(dt, 0.001)
      lastDragX = x
      dragSwing += (clamp(-vx / 900, -0.7, 0.7) - dragSwing) * Math.min(1, dt * 8)
      target = PoseLibrary.dangle(time, dragSwing)
      break
    }

    case 'falling':
      vy -= 2400 * dt
      y += vy * dt
      target = PoseLibrary.falling(time)
      if (y <= 0) {
        y = 0
        vy = 0
        animator.kick('squash', -5.5) // squishy landing
        mode = { kind: 'idle', until: Date.now() + 2000 }
        sip.expand(false)
      }
      break
  }

  // Eyes follow the cursor.
  const headY = y + height() * 0.78
  const facing = facingRight ? 1 : -1
  if (target.eyesOpen > 0.5) {
    target.lookX = clamp((cursor.x - x) / 350, -1, 1) * facing
    target.lookY = clamp((cursor.y - headY) / 350, -1, 1)
  }

  if (isThinking && !shownBubble) {
    shownBubble = { title: '•'.repeat(1 + Math.floor(time * 3) % 3), subtitle: null }
  } else if (!shownBubble && transient) {
    if (now < transient.until) shownBubble = transient.bubble
    else transient = null
  }

  x = clamp(x, half, W - half)
  if (mode.kind !== 'dragging' && mode.kind !== 'falling') y = 0

  animator.update(target, dt)
  updateParticles(dt)

  // Full 60 fps only while moving; calm states redraw less often to save battery.
  frameCount++
  const divisor = mode.kind === 'idle' ? (isSuppressed() ? 6 : 3) : mode.kind === 'reminding' || mode.kind === 'walking' ? 2 : 1
  const bubbleChanged = JSON.stringify(shownBubble) !== JSON.stringify(bubble)
  bubble = shownBubble
  if (frameCount % divisor === 0 || bubbleChanged) draw()
  updateMousePassthrough()
}

// MARK: - Drawing

function draw() {
  const dpr = window.devicePixelRatio || 1
  const H = window.innerHeight
  const pose = animator.pose
  const u = unit()
  const flip = facingRight ? 1 : -1

  if (canvas.width !== Math.round(canvasWidth() * dpr) || canvas.height !== Math.round(H * dpr)) resize()
  const left = Math.round(x - canvasWidth() / 2)
  if (left !== canvasLeft) {
    canvasLeft = left
    canvas.style.transform = `translateX(${left}px)`
  }
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, canvas.width, canvas.height)
  // Draw in window coordinates.
  ctx.setTransform(dpr, 0, 0, dpr, -left * dpr, 0)
  ctx.save()
  ctx.translate(x, H - y)
  ctx.scale(u * flip, -u)
  Renderer.draw(ctx, look, pose)
  ctx.restore()

  drawParticles(H, u)
  drawBubble(H, u)
}

function drawParticles(H, u) {
  const flip = facingRight ? 1 : -1
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'
  for (const p of particles) {
    ctx.globalAlpha = Math.min(1, p.life / (p.maxLife * 0.35))
    ctx.font = `${p.size * u}px "Segoe UI Emoji", "Apple Color Emoji", sans-serif`
    ctx.fillText(p.text, x + p.x * u * flip, H - (y + p.y * u))
  }
  ctx.globalAlpha = 1
}

function wrap(text, font, maxWidth) {
  ctx.font = font
  const lines = []
  for (const para of text.split('\n')) {
    let line = ''
    for (const word of para.split(' ')) {
      const test = line ? `${line} ${word}` : word
      if (ctx.measureText(test).width > maxWidth && line) { lines.push(line); line = word }
      else line = test
    }
    lines.push(line)
  }
  return lines
}

function drawBubble(H, u) {
  if (!bubble) { bubbleRect = null; return }
  const ink = '#2b1c1a'
  const titleFont = '700 13px "Segoe UI", system-ui, sans-serif'
  const subFont = '500 10.5px "Segoe UI", system-ui, sans-serif'
  const maxText = Math.min(window.innerWidth - 30, 210)
  const titleLines = wrap(bubble.title, titleFont, maxText)
  const subLines = bubble.subtitle ? wrap(bubble.subtitle, subFont, maxText) : []
  let textW = 0
  ctx.font = titleFont; for (const l of titleLines) textW = Math.max(textW, ctx.measureText(l).width)
  ctx.font = subFont; for (const l of subLines) textW = Math.max(textW, ctx.measureText(l).width)
  const textH = titleLines.length * 17 + subLines.length * 14
  const w = Math.ceil(textW) + 24, h = textH + 14
  const bottom = H - (y + (262 + Math.max(0, animator.pose.lift)) * u + 14)
  const lo = Math.max(4, canvasLeft + 4), hi = Math.min(window.innerWidth, canvasLeft + canvasWidth()) - w - 4
  const bx = Math.round(clamp(x - w / 2, lo, Math.max(lo, hi)))
  const by = Math.round(bottom - h)
  bubbleRect = { x: bx - 2, y: by - 12, w: w + 4, h: h + 24 }

  ctx.lineWidth = 2
  ctx.strokeStyle = ink
  ctx.fillStyle = '#fff'
  ctx.beginPath()
  ctx.roundRect(bx, by, w, h, 10)
  ctx.fill(); ctx.stroke()
  const tx = clamp(x, bx + 14, bx + w - 14)
  ctx.beginPath()
  ctx.moveTo(tx - 7, by + h); ctx.lineTo(tx, by + h + 9); ctx.lineTo(tx + 7, by + h)
  ctx.fillStyle = ink; ctx.fill(); ctx.stroke()
  ctx.fillStyle = '#fff'
  ctx.fillRect(tx - 6, by + h - 2, 12, 3)

  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'
  let ty = by + 7
  ctx.font = titleFont; ctx.fillStyle = ink
  for (const l of titleLines) { ctx.fillText(l, bx + w / 2, ty); ty += 17 }
  ctx.font = subFont; ctx.fillStyle = '#6b6b6b'
  for (const l of subLines) { ctx.fillText(l, bx + w / 2, ty); ty += 14 }
}

// MARK: - Hit testing / click-through

/** Area that should receive clicks (in client coords); everything else passes through. */
function hitTest(cx, cy) {
  const H = window.innerHeight
  const u = unit()
  const w = spriteWidth() * 1.2
  const lift = Math.max(0, animator.pose.lift) * u
  const bodyTop = H - y - lift - height()
  const bodyBottom = H - y - lift + 4
  if (cx >= x - w / 2 && cx <= x + w / 2 && cy >= bodyTop && cy <= bodyBottom) return true
  if (bubbleRect && cx >= bubbleRect.x && cx <= bubbleRect.x + bubbleRect.w && cy >= bubbleRect.y && cy <= bubbleRect.y + bubbleRect.h) return true
  return false
}

function updateMousePassthrough() {
  if (mode.kind === 'dragging' || pointer) return setIgnore(false)
  setIgnore(!hitTest(cursor.x, window.innerHeight - cursor.y))
}

function setIgnore(v) {
  if (ignoring === v) return
  ignoring = v
  sip.ignoreMouse(v)
}

// MARK: - Effects

function emit(interval, make) {
  if (time >= nextEffect) { nextEffect = time + interval; make() }
}

function spawn(text, px, py, pvy, pvx, life, size, gravity = 0) {
  particles.push({ text, x: px, y: py, vx: pvx, vy: pvy, life, maxLife: life, size, gravity })
}

function updateParticles(dt) {
  for (const p of particles) {
    p.vy += p.gravity * dt
    p.x += p.vx * dt
    p.y += p.vy * dt
    p.life -= dt
  }
  particles = particles.filter(p => p.life > 0)
}

/** A soft two-tone glass chime (the macOS app uses the "Glass" system sound). */
function chime() {
  try {
    audio = audio || new AudioContext()
    const t = audio.currentTime
    for (const [freq, delay, gain] of [[1318.5, 0, 0.18], [1975.5, 0.09, 0.12]]) {
      const osc = audio.createOscillator()
      const g = audio.createGain()
      osc.type = 'sine'
      osc.frequency.value = freq
      g.gain.setValueAtTime(0, t + delay)
      g.gain.linearRampToValueAtTime(gain, t + delay + 0.01)
      g.gain.exponentialRampToValueAtTime(0.0001, t + delay + 1.1)
      osc.connect(g).connect(audio.destination)
      osc.start(t + delay)
      osc.stop(t + delay + 1.2)
    }
  } catch {}
}

// MARK: - Reminders

function checkReminders() {
  if (mode.kind === 'reminding') {
    if (isSuppressed()) mode = { kind: 'idle', until: Date.now() + 3000 }
    return
  }
  if (['dragging', 'falling', 'celebrating'].includes(mode.kind)) return
  if (isSuppressed() && mode.kind === 'idle' && !transient && Math.random() < 1 / 300) say(sleepyLine(), null, 4)
  const due = dueReminder()
  if (!due) return
  mode = { kind: 'reminding', id: due.id }
  animator.kick('squash', 3)
  if (!alerted.has(due.id)) {
    alerted.add(due.id)
    if (state.soundEnabled) chime()
  }
}

function celebrate() {
  celebrateStage = 0
  mode = { kind: 'celebrating', started: Date.now() }
}

function complete(id) {
  const r = reminder(id)
  if (!r) return
  const n = count(id) + 1
  sip.act('markDone', id)
  alerted.delete(id)
  nag = null
  celebrate()
  say(praiseLine(r), `${r.emoji} ${n} today`, 4)
}

function completeNow() {
  if (mode.kind === 'reminding') return complete(mode.id)
  const r = state.reminders.find(r => r.enabled)
  if (r) complete(r.id)
}

function say(title, subtitle, seconds) {
  transient = { bubble: { title, subtitle: subtitle || null }, until: performance.now() + seconds * 1000 }
}

// MARK: - Interaction

function handleClick() {
  if (mode.kind === 'reminding') return complete(mode.id)
  if (mode.kind === 'falling') return
  // Little hop, and say when the next reminder is.
  mode = { kind: 'falling' }
  vy = 560
  animator.kick('squash', 4)
  spawn('💖', 30, 250, 70, 20, 1.1, 22)
  const next = nextUpcoming()
  if (next) {
    const mins = Math.max(0, Math.ceil((nextDue(next) - Date.now()) / 60000))
    say(`${next.emoji} ${next.title} in ${mins} min`, `${count(next.id)} today · double-click to chat`, 2.5)
  } else {
    say('Hi there! 👋', null, 2)
  }
}

let pointer = null // { startX, startY, dragging }

canvas.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return
  canvas.setPointerCapture(e.pointerId)
  pointer = { startX: e.clientX, startY: e.clientY, dragging: false }
})

canvas.addEventListener('pointermove', (e) => {
  // Forwarded moves keep hover detection snappy while the window ignores clicks.
  cursor = { x: e.clientX, y: window.innerHeight - e.clientY }
  if (!pointer) return updateMousePassthrough()
  const H = window.innerHeight
  if (!pointer.dragging && Math.hypot(e.clientX - pointer.startX, e.clientY - pointer.startY) > 4) {
    pointer.dragging = true
    dragOffset = { x: e.clientX - x, y: (H - e.clientY) - y }
    lastDragX = x
    dragSwing = 0
    mode = { kind: 'dragging' }
    say('Wheee!', null, 1.2)
    sip.expand(true)
  }
  if (pointer.dragging) {
    x = e.clientX - dragOffset.x
    y = Math.max(0, (H - e.clientY) - dragOffset.y)
  }
})

canvas.addEventListener('pointerup', (e) => {
  if (!pointer) return
  if (pointer.dragging) {
    mode = { kind: 'falling' }
    vy = 0
  } else if (hitTest(e.clientX, e.clientY)) {
    if (e.detail >= 2) sip.openChat({ x, top: y + height() + 10 })
    else handleClick()
  }
  pointer = null
})

canvas.addEventListener('contextmenu', (e) => {
  e.preventDefault()
  const r = mode.kind === 'reminding' ? reminder(mode.id) : null
  sip.contextMenu({ reminding: r ? { emoji: r.emoji, title: r.title } : null })
})

// MARK: - Wiring

sip.onCursor((c) => { if (!pointer) cursor = c })
sip.onState((s) => applyState(s, false))
sip.onThinking((v) => { isThinking = v })
sip.onSay((reply) => {
  animator.kick('squash', 2.5)
  say(reply, null, Math.min(12, 3 + reply.length / 14))
})
sip.onMenu((action) => {
  switch (action) {
    case 'done': if (mode.kind === 'reminding') complete(mode.id); break
    case 'done-now': completeNow(); break
    case 'snooze':
      if (mode.kind !== 'reminding') break
      sip.act('snooze', mode.id, 10)
      alerted.delete(mode.id); nag = null
      mode = { kind: 'idle', until: Date.now() + 3000 }
      say('Okay, 10 more minutes 😴', null, 2)
      break
    case 'skip':
      if (mode.kind !== 'reminding') break
      sip.act('skip', mode.id)
      alerted.delete(mode.id); nag = null
      mode = { kind: 'idle', until: Date.now() + 3000 }
      say('Fine… 😒', null, 2)
      break
    case 'chat': sip.openChat({ x, top: y + height() + 10 }); break
  }
})

resize()
sip.getState().then((s) => {
  applyState(s, true)
  x = window.innerWidth / 2
  requestAnimationFrame(tick)
})

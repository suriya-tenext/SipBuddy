// Settings window: reminders, hero picker, hero builder, general. Mirrors SettingsView.swift.
'use strict'

const { PoseLibrary, Renderer } = Hero
let state = null
const $ = (id) => document.getElementById(id)
const el = (tag, props = {}, ...children) => {
  const e = Object.assign(document.createElement(tag), props)
  for (const c of children) e.append(c)
  return e
}

// MARK: - Tabs

function showTab(name) {
  for (const b of document.querySelectorAll('nav button')) b.classList.toggle('active', b.dataset.tab === name)
  for (const s of document.querySelectorAll('.tab')) s.classList.toggle('active', s.id === name)
}
for (const b of document.querySelectorAll('nav button')) b.onclick = () => showTab(b.dataset.tab)
sip.onTab(showTab)
if (location.hash) showTab(location.hash.slice(1))

// MARK: - Reminders

function renderReminders() {
  const list = $('reminderList')
  // Don't rebuild while the user is typing in a row.
  if (list.contains(document.activeElement) && document.activeElement.tagName === 'INPUT' &&
      document.activeElement.type !== 'checkbox') return
  list.replaceChildren()
  if (!state.reminders.length) list.append(el('p', { className: 'muted', textContent: 'No reminders yet. Add one below and your buddy will nudge you.' }))
  for (const r of state.reminders) {
    const update = (patch) => {
      Object.assign(r, patch)
      sip.act('set', 'reminders', state.reminders)
    }
    const enabled = el('input', { type: 'checkbox', checked: r.enabled, onchange: (e) => update({ enabled: e.target.checked }) })
    const emoji = el('input', { type: 'text', className: 'emoji', value: r.emoji, onchange: (e) => update({ emoji: e.target.value }) })
    const title = el('input', { type: 'text', className: 'title', value: r.title, placeholder: 'Title', onchange: (e) => update({ title: e.target.value }) })
    const message = el('input', { type: 'text', value: r.message, placeholder: 'What should your buddy say?', onchange: (e) => update({ message: e.target.value }) })
    const every = el('input', { type: 'number', min: 1, max: 480, step: 5, value: r.intervalMinutes,
      onchange: (e) => update({ intervalMinutes: Math.max(1, Math.min(480, parseInt(e.target.value) || 30)) }) })
    const count = state.countsDate === dayKey() ? state.todayCounts[r.id] || 0 : 0
    const del = el('button', { className: 'del', title: 'Delete', textContent: '🗑',
      onclick: () => sip.act('set', 'reminders', state.reminders.filter(x => x.id !== r.id)) })
    list.append(el('div', { className: 'reminder' },
      enabled, emoji,
      el('div', { className: 'texts' }, title, message),
      el('div', { className: 'every' }, 'every', every, 'min'),
      el('div', { className: 'count', textContent: `${count} today` }),
      del))
  }
  $('pausedNote').textContent = state.isSuppressed ? '🌙 Reminders paused right now' : ''
}

function dayKey(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function setupAddReminder() {
  const sel = $('addReminder')
  state.reminderPresets.forEach((p, i) => sel.append(el('option', { value: i, textContent: `${p.emoji}  ${p.title} · every ${p.intervalMinutes} min` })))
  sel.append(el('option', { value: 'custom', textContent: '⭐️  Custom…' }))
  sel.onchange = () => {
    const v = sel.value
    sel.value = ''
    if (v === 'custom') sip.act('add', { emoji: '⭐️', title: 'Custom', message: 'Reminder time!', intervalMinutes: 30 })
    else if (v !== '') sip.act('add', state.reminderPresets[+v])
  }
}

// MARK: - Buddies

const thumbCache = new Map()

function thumbCanvas(look, px = 220) {
  const key = JSON.stringify(look) + px
  if (!thumbCache.has(key)) thumbCache.set(key, Renderer.snapshot(look, PoseLibrary.idle(0.5), px))
  const src = thumbCache.get(key)
  const c = el('canvas', { width: src.width, height: src.height })
  c.getContext('2d').drawImage(src, 0, 0)
  return c
}

function heroCard(look, custom) {
  const name = `hero:${look.id}`
  const card = el('div', { className: 'thumb' + (state.selectedCharacter === name ? ' active' : ''), title: look.tagline },
    thumbCanvas(look),
    el('div', { className: 'name', textContent: look.name }),
    el('div', { className: 'tag', textContent: look.tagline }))
  card.onclick = () => sip.act('set', 'selectedCharacter', name)
  if (custom) {
    const actions = el('div', { className: 'row center' },
      el('button', { textContent: 'Edit', onclick: (e) => { e.stopPropagation(); editInBuilder(look) } }))
    card.append(actions)
    card.append(el('button', { className: 'x', title: 'Delete', textContent: '✕',
      onclick: (e) => { e.stopPropagation(); if (confirm(`Delete ${look.name}?`)) sip.act('deleteHero', look.id) } }))
  }
  return card
}

function renderBuddies() {
  const chips = $('personalities')
  chips.replaceChildren()
  for (const [label, prompt] of state.personalities) {
    chips.append(el('button', { className: state.personality === prompt ? 'active' : '', textContent: label,
      onclick: () => sip.act('set', 'personality', prompt) }))
  }
  $('brainNote').textContent = state.hasAnthropicKey
    ? 'Your buddy writes fresh lines in this personality with Claude.'
    : 'Add an Anthropic API key under General to give your buddy fresh lines and chat.'
  $('size').value = state.buddyHeight
  if (showHeroines === null) showHeroines = lookFor(state.selectedCharacter)?.figure === 'feminine'
  for (const b of document.querySelectorAll('#roster button')) b.classList.toggle('active', (b.dataset.roster === 'heroines') === showHeroines)
  $('heroGrid').replaceChildren(...(showHeroines ? Hero.heroines : Hero.heroes).map(l => heroCard(l, false)))
  $('customGrid').replaceChildren(...state.customHeroes.map(l => heroCard(l, true)))
  $('customTitle').style.display = state.customHeroes.length ? '' : 'none'
}

$('size').oninput = (e) => sip.act('set', 'buddyHeight', +e.target.value)

// Heroes / Heroines roster switch; starts on the one the current buddy belongs to.
let showHeroines = null
const lookFor = (name) => {
  const id = (name || '').replace(/^hero:/, '')
  return state.customHeroes.find(h => h.id === id) || Hero.preset(id)
}
for (const b of document.querySelectorAll('#roster button')) {
  b.onclick = () => { showHeroines = b.dataset.roster === 'heroines'; renderBuddies() }
}

// MARK: - Hero Builder

const OPTIONS = {
  hairStyle: ['short', 'long', 'spiky', 'bun', 'ponytail', 'curly', 'bald'],
  mask: ['none', 'domino', 'shades', 'cowl', 'helmet', 'armor', 'fullface'],
  ears: ['none', 'pointy', 'cat', 'antenna'],
  emblem: ['none', 'star', 'bolt', 'drop', 'circle', 'diamond', 'heart', 'core', 'spider'],
  outfit: ['bodysuit', 'tux', 'bare', 'armor'],
  build: ['regular', 'big'],
  attitude: ['cheerful', 'stoic', 'fierce'],
  figure: ['masculine', 'feminine'],
}
const OUTFIT_LABELS = { bodysuit: 'Bodysuit', tux: 'Suit & tie', bare: 'Bare', armor: 'Armor' }
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1)

let draft = { ...Hero.presets[0], id: 'new', name: 'My Hero', tagline: 'Hydration hero', voice: 'friendly and upbeat' }
let previewAnim = 'idle'

function editInBuilder(look) {
  draft = JSON.parse(JSON.stringify(look))
  buildControls()
  $('savedNote').textContent = ''
  showTab('builder')
}

function buildControls() {
  const c = $('controls')
  c.replaceChildren()
  const row = (label, ...fields) => c.append(el('div', { className: 'label', textContent: label }), el('div', { className: 'field' }, ...fields))
  const section = (t) => c.append(el('div', { className: 'section', textContent: t }))
  const text = (key, placeholder) => el('input', { type: 'text', value: draft[key] || '', placeholder, oninput: (e) => { draft[key] = e.target.value } })
  const color = (key) => el('input', { type: 'color', value: draft[key] || '#000000', title: key, oninput: (e) => { draft[key] = e.target.value.toUpperCase() } })
  const select = (key, labels = {}) => {
    const s = el('select', { onchange: (e) => { draft[key] = e.target.value } })
    for (const o of OPTIONS[key]) s.append(el('option', { value: o, textContent: labels[o] || cap(o) }))
    s.value = draft[key] || OPTIONS[key][0]
    return s
  }
  const check = (key, label, onchange) => el('label', { className: 'line' },
    el('input', { type: 'checkbox', checked: !!draft[key], onchange: (e) => { draft[key] = e.target.checked; onchange?.() } }), label)

  section('Identity')
  row('Name', text('name', 'Hero name'))
  row('Tagline', text('tagline', 'One-line motto'))
  row('Voice', text('voice', 'How they talk'))
  row('Attitude', select('attitude'))
  section('Body')
  row('Body', select('figure', { masculine: 'Male', feminine: 'Female' }), select('build'), select('outfit', OUTFIT_LABELS))
  row('Skin', color('skin'))
  row('Hair', select('hairStyle'), color('hair'))
  row('Mask', select('mask'), color('maskColor'), check('glasses', 'Glasses'), check('beard', 'Beard'))
  row('Ears', select('ears'))
  section('Costume')
  row('Suit', color('suit'), color('accent'), check('belt', 'Belt'))
  row('Emblem', select('emblem'), color('emblemColor'))
  const capeColor = el('input', { type: 'color', value: draft.cape || '#D93A3A', disabled: !draft.cape,
    oninput: (e) => { draft.cape = e.target.value.toUpperCase() } })
  const capeToggle = el('label', { className: 'line' }, el('input', { type: 'checkbox', checked: !!draft.cape,
    onchange: (e) => { draft.cape = e.target.checked ? capeColor.value.toUpperCase() : null; capeColor.disabled = !e.target.checked } }), 'Cape')
  row('Cape', capeToggle, capeColor)
  row('Pants · boots · gloves', color('pants'), color('boots'), color('gloves'))
  row('Cup', color('cup'))
}

function randomHex() {
  const h = Math.random(), s = 0.45 + Math.random() * 0.4, l = 0.35 + Math.random() * 0.25
  const f = (n) => {
    const k = (n + h * 12) % 12
    const a = s * Math.min(l, 1 - l)
    return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))))
  }
  return '#' + [f(0), f(8), f(4)].map(v => v.toString(16).padStart(2, '0')).join('').toUpperCase()
}
const any = (list) => list[Math.floor(Math.random() * list.length)]

$('randomize').onclick = () => {
  const skins = ['#F2C6A0', '#E0B48C', '#C68A5E', '#8D5A3B', '#6B4430', '#FFD9B8', '#F7DCCB']
  const suit = randomHex(), accent = randomHex()
  Object.assign(draft, {
    skin: any(skins), hair: any(['#1B1B1B', '#3A2A1A', '#5A3A2A', '#F4D06F', '#F2582A', '#DDEEFF']),
    hairStyle: any(OPTIONS.hairStyle), suit, accent, pants: any([suit, accent, '#23232B']),
    boots: any([accent, '#1B1B1B', suit]), gloves: any([accent, suit, '#F4F4F4']),
    belt: Math.random() < 0.5, cape: Math.random() < 0.4 ? randomHex() : null,
    mask: any(['none', 'domino', 'domino', 'cowl', 'helmet', 'fullface', 'shades']), maskColor: any([suit, accent, '#1B1B1B']),
    ears: any(['none', 'none', 'none', 'pointy', 'cat', 'antenna']),
    emblem: any(OPTIONS.emblem.filter(e => e !== 'core')), emblemColor: Math.random() < 0.5 ? accent : '#FFFFFF',
    glasses: Math.random() < 0.15, outfit: any(['bodysuit', 'bodysuit', 'bodysuit', 'tux', 'armor']),
    build: Math.random() < 0.2 ? 'big' : 'regular', beard: Math.random() < 0.2, attitude: any(OPTIONS.attitude),
  })
  buildControls()
}

$('saveHero').onclick = async () => {
  if (!draft.name.trim()) draft.name = 'My Hero'
  const id = await sip.act('saveHero', draft)
  draft.id = id
  $('savedNote').textContent = `Saved! ${draft.name} is now on your taskbar.`
}

for (const b of document.querySelectorAll('#previewAnim button')) {
  b.onclick = () => {
    previewAnim = b.dataset.anim
    for (const x of document.querySelectorAll('#previewAnim button')) x.classList.toggle('active', x === b)
  }
}

// Live preview, sprung like the real buddy.
const previewCtx = $('preview').getContext('2d')
const previewAnimator = new Hero.PoseAnimator()
let previewLast = performance.now()
let previewTime = 0

function previewPose(t) {
  switch (previewAnim) {
    case 'walk': return PoseLibrary.walk(t * 7.5, t)
    case 'remind': return PoseLibrary.remind(t)
    case 'drink': return PoseLibrary.drink(t % (PoseLibrary.drinkDuration + 0.8), t)
    case 'cheer': return PoseLibrary.cheer(t % (PoseLibrary.cheerDuration + 0.6), t)
    case 'sleep': return PoseLibrary.sleep(t)
    default: return PoseLibrary.idle(t)
  }
}

function drawPreview(now) {
  requestAnimationFrame(drawPreview)
  if (!$('builder').classList.contains('active')) return
  const dt = Math.min((now - previewLast) / 1000, 0.1)
  previewLast = now
  previewTime += dt
  previewAnimator.update(previewPose(previewTime), dt)

  const canvas = $('preview')
  const dpr = window.devicePixelRatio || 1
  const W = 260, H = 320
  if (canvas.width !== W * dpr) { canvas.width = W * dpr; canvas.height = H * dpr }
  previewCtx.setTransform(1, 0, 0, 1, 0, 0)
  previewCtx.clearRect(0, 0, canvas.width, canvas.height)
  const s = H / (Renderer.height + 80)
  previewCtx.setTransform(dpr * s, 0, 0, -dpr * s, dpr * W / 2, dpr * (H - 16))
  Renderer.draw(previewCtx, draft, previewAnimator.pose)
}
requestAnimationFrame(drawPreview)

// MARK: - General

function renderGeneral() {
  $('keyStatus').textContent = state.hasAnthropicKey ? '✓ Key saved. Double-click your buddy to chat.' : 'No key yet.'
  $('presence').value = state.onlyForReminders ? 'reminders' : 'always'
  $('presenceNote').textContent = state.onlyForReminders
    ? 'Your buddy stays out of the way and walks in when it\'s time. Click it when you\'re done and it heads back off-screen. Use the tray 💧 to call it for a chat.'
    : 'Your buddy hangs out on your taskbar all day.'
  $('sound').checked = state.soundEnabled
  $('walkSpeed').value = state.walkSpeed
  $('quiet').checked = state.quietHoursEnabled
  $('quietStart').value = state.quietStart
  $('quietEnd').value = state.quietEnd
  $('login').checked = state.launchAtLogin
}

function setupGeneral() {
  for (const id of ['quietStart', 'quietEnd']) {
    for (let h = 0; h < 24; h++) $(id).append(el('option', { value: h, textContent: `${String(h).padStart(2, '0')}:00` }))
  }
  $('saveKey').onclick = async () => {
    const v = $('anthropicKey').value.trim()
    if (!v) return
    await sip.act('setAnthropicKey', v)
    $('anthropicKey').value = ''
  }
  $('clearKey').onclick = () => sip.act('setAnthropicKey', '')
  $('presence').onchange = (e) => sip.act('set', 'onlyForReminders', e.target.value === 'reminders')
  $('sound').onchange = (e) => sip.act('set', 'soundEnabled', e.target.checked)
  $('walkSpeed').onchange = (e) => sip.act('set', 'walkSpeed', +e.target.value)
  $('quiet').onchange = (e) => sip.act('set', 'quietHoursEnabled', e.target.checked)
  $('quietStart').onchange = (e) => sip.act('set', 'quietStart', +e.target.value)
  $('quietEnd').onchange = (e) => sip.act('set', 'quietEnd', +e.target.value)
  $('login').onchange = (e) => sip.act('setLaunchAtLogin', e.target.checked)
}

// MARK: - Boot

function render() {
  renderReminders()
  renderBuddies()
  renderGeneral()
}

sip.onState((s) => { state = s; render() })
sip.getState().then((s) => {
  state = s
  setupAddReminder()
  setupGeneral()
  buildControls()
  render()
})

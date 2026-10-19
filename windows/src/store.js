// App state: reminders, settings, today's counts and saved heroes, persisted as JSON in userData.
// Mirrors AppState.swift from the macOS app.
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { app, safeStorage } = require('electron')

const REMINDER_PRESETS = [
  { emoji: '💧', title: 'Water', message: 'Time to drink some water!', intervalMinutes: 45 },
  { emoji: '🧘', title: 'Stretch', message: 'Stand up and stretch a bit!', intervalMinutes: 60 },
  { emoji: '👀', title: 'Eyes', message: 'Look 20 ft away for 20 seconds', intervalMinutes: 20 },
  { emoji: '🪑', title: 'Posture', message: 'Sit up straight!', intervalMinutes: 30 },
  { emoji: '💊', title: 'Meds', message: 'Take your meds!', intervalMinutes: 240 },
]

const PERSONALITIES = [
  ['🌞 Cheerful', 'Cheerful, warm and encouraging, with a goofy streak.'],
  ['💅 Sassy', 'Sassy and dramatic, playfully roasts the user when they forget, secretly adores them.'],
  ['😌 Chill', 'Laid-back and calm, speaks softly, cozy lo-fi vibes.'],
  ['💪 Coach', 'High-energy sports coach, hype and motivational, loves streaks.'],
  ['🎭 Theatrical', "Over-the-top Shakespearean drama queen; every sip is an epic."],
  ['🐱 Cat', "Acts like a smug little cat; occasional 'nya', judges the user lovingly."],
]

const DEFAULT_CHARACTER = 'hero:ironclad'

const dayKey = (d = new Date()) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

const newReminder = (preset) => ({
  id: crypto.randomUUID(), enabled: true, lastDone: Date.now(), ...preset,
})

class Store {
  constructor() {
    this.file = path.join(app.getPath('userData'), 'state.json')
    let saved = null
    try { saved = JSON.parse(fs.readFileSync(this.file, 'utf8')) } catch {}
    this.isFirstLaunch = !saved
    this.data = {
      reminders: [newReminder(REMINDER_PRESETS[0])],
      buddyHeight: 180,
      walkSpeed: 45,
      soundEnabled: true,
      onlyForReminders: true, // stay off-screen; walk in only when a reminder is due
      quietHoursEnabled: false,
      quietStart: 22,
      quietEnd: 8,
      selectedCharacter: DEFAULT_CHARACTER,
      personality: PERSONALITIES[0][1],
      pausedUntil: null,
      todayCounts: {},
      countsDate: dayKey(),
      customHeroes: [],
      linePack: null,
      anthropicKey: null, // encrypted with the OS keychain (DPAPI on Windows) when available
      ...saved,
    }
    this.listeners = []
    this.rollCounts()
    if (this.isFirstLaunch) this.save()
  }

  onChange(fn) { this.listeners.push(fn) }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true })
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 1))
  }

  changed() {
    this.save()
    for (const fn of this.listeners) fn()
  }

  /** Everything the windows need, without secrets. */
  get publicState() {
    const { anthropicKey, ...rest } = this.data
    return {
      ...rest,
      hasAnthropicKey: !!this.anthropicKey,
      isFirstLaunch: this.isFirstLaunch,
      isSuppressed: this.isSuppressed,
      personalities: PERSONALITIES,
      reminderPresets: REMINDER_PRESETS,
      launchAtLogin: app.getLoginItemSettings().openAtLogin,
    }
  }

  // MARK: keys

  get anthropicKey() {
    if (process.env.ANTHROPIC_API_KEY) return process.env.ANTHROPIC_API_KEY
    const v = this.data.anthropicKey
    if (!v) return null
    try {
      return v.enc ? safeStorage.decryptString(Buffer.from(v.enc, 'base64')) : v.plain
    } catch { return null }
  }

  setAnthropicKey(key) {
    key = (key || '').trim()
    if (!key) this.data.anthropicKey = null
    else if (safeStorage.isEncryptionAvailable()) this.data.anthropicKey = { enc: safeStorage.encryptString(key).toString('base64') }
    else this.data.anthropicKey = { plain: key }
    this.changed()
  }

  // MARK: settings

  set(key, value) {
    const allowed = ['buddyHeight', 'walkSpeed', 'soundEnabled', 'onlyForReminders', 'quietHoursEnabled', 'quietStart', 'quietEnd',
      'selectedCharacter', 'personality', 'reminders', 'linePack']
    if (!allowed.includes(key)) return
    this.data[key] = value
    this.changed()
  }

  // MARK: reminders

  rollCounts() {
    const today = dayKey()
    if (this.data.countsDate !== today) {
      this.data.countsDate = today
      this.data.todayCounts = {}
    }
  }

  count(id) { this.rollCounts(); return this.data.todayCounts[id] || 0 }
  reminder(id) { return this.data.reminders.find(r => r.id === id) }
  nextDue(r) { return r.lastDone + r.intervalMinutes * 60000 }

  add(preset) {
    this.data.reminders.push(newReminder(preset))
    this.changed()
  }

  markDone(id) {
    this.rollCounts()
    const r = this.reminder(id)
    if (!r) return
    r.lastDone = Date.now()
    this.data.todayCounts[id] = (this.data.todayCounts[id] || 0) + 1
    this.changed()
  }

  snooze(id, minutes) {
    const r = this.reminder(id)
    if (!r) return
    r.lastDone = Date.now() - r.intervalMinutes * 60000 + minutes * 60000
    this.changed()
  }

  skip(id) {
    const r = this.reminder(id)
    if (!r) return
    r.lastDone = Date.now()
    this.changed()
  }

  pause(minutes) {
    this.data.pausedUntil = minutes > 0 ? Date.now() + minutes * 60000 : null
    this.changed()
  }

  /** Reminders are silent while paused or during quiet hours. */
  get isSuppressed() {
    const d = this.data
    if (d.pausedUntil && d.pausedUntil > Date.now()) return true
    if (!d.quietHoursEnabled || d.quietStart === d.quietEnd) return false
    const hour = new Date().getHours()
    return d.quietStart < d.quietEnd
      ? hour >= d.quietStart && hour < d.quietEnd
      : hour >= d.quietStart || hour < d.quietEnd
  }

  dueReminder() {
    if (this.isSuppressed) return null
    const now = Date.now()
    return this.data.reminders
      .filter(r => r.enabled && this.nextDue(r) <= now)
      .sort((a, b) => this.nextDue(a) - this.nextDue(b))[0] || null
  }

  nextUpcoming() {
    return this.data.reminders.filter(r => r.enabled).sort((a, b) => this.nextDue(a) - this.nextDue(b))[0] || null
  }

  // MARK: heroes

  saveHero(look) {
    const hero = { ...look, id: look.id && look.id.startsWith('custom-') ? look.id : `custom-${Date.now()}` }
    const i = this.data.customHeroes.findIndex(h => h.id === hero.id)
    if (i >= 0) this.data.customHeroes[i] = hero
    else this.data.customHeroes.push(hero)
    this.data.selectedCharacter = `hero:${hero.id}`
    this.changed()
    return hero.id
  }

  deleteHero(id) {
    this.data.customHeroes = this.data.customHeroes.filter(h => h.id !== id)
    if (this.data.selectedCharacter === `hero:${id}`) this.data.selectedCharacter = DEFAULT_CHARACTER
    this.changed()
  }
}

module.exports = { Store, REMINDER_PRESETS, PERSONALITIES }

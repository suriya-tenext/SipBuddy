// Claude gives the buddy its voice: line packs written ahead of time, plus live chat with
// tools that edit reminders. Mirrors BuddyBrain.swift (raw HTTP to the Messages API).
const MODEL = 'claude-opus-5-5'

class AIError extends Error {}

async function send(apiKey, { system, messages, tools, schema, effort, maxTokens = 16000 }) {
  const body = {
    model: MODEL,
    max_tokens: maxTokens,
    messages,
    // If a safety classifier declines, let the API retry on its recommended fallback model.
    fallbacks: 'default',
    output_config: schema ? { effort, format: { type: 'json_schema', schema } } : { effort },
  }
  if (system) body.system = system
  if (tools) body.tools = tools
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'anthropic-beta': 'server-side-fallback-2026-07-01',
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(300000),
  })
  const json = await res.json().catch(() => ({}))
  if (!res.ok) throw new AIError(json.error?.message || `HTTP ${res.status}`)
  if (json.stop_reason === 'refusal') throw new AIError('Claude declined this request.')
  return json
}

const textOf = (response) => (response.content || []).filter(b => b.type === 'text').map(b => b.text).join('')

// Strict JSON schemas, tersely (structured outputs require additionalProperties: false).
const Schema = {
  string: { type: 'string' },
  integer: { type: 'integer' },
  boolean: { type: 'boolean' },
  array: (items) => ({ type: 'array', items }),
  nullable: (s) => ({ anyOf: [s, { type: 'null' }] }),
  object: (props) => ({ type: 'object', properties: props, required: Object.keys(props).sort(), additionalProperties: false }),
}

const tool = (name, description, props) => ({ name, description, strict: true, input_schema: Schema.object(props) })

const TOOLS = [
  tool('add_reminder', 'Create a new recurring reminder.', {
    emoji: Schema.string, title: Schema.string, message: Schema.string, interval_minutes: Schema.integer,
  }),
  tool('update_reminder', 'Change an existing reminder, found by its title. Pass null for fields to keep.', {
    title: Schema.string,
    interval_minutes: Schema.nullable(Schema.integer),
    message: Schema.nullable(Schema.string),
    enabled: Schema.nullable(Schema.boolean),
  }),
  tool('remove_reminder', 'Delete a reminder, found by its title.', { title: Schema.string }),
  tool('log_done', 'Record that the user just did a reminder (e.g. drank water).', { title: Schema.string }),
  tool('pause_reminders', 'Pause all reminders for some minutes (0 resumes them now).', { minutes: Schema.integer }),
]

const pick = (list) => (list && list.length ? list[Math.floor(Math.random() * list.length)] : null)

class Brain {
  /** `bible()` returns { name, appearance, voice } for the selected character. */
  constructor(store, bible) {
    this.store = store
    this.bible = bible
    this.history = []
    this.historyKey = ''
    this.isRefreshing = false
    this.lastError = null
  }

  get persona() {
    const b = this.bible()
    return `You are ${b.name}, a tiny animated superhero companion who lives on the user's Windows taskbar and helps them build healthy habits.
Look: ${b.appearance}
Voice: ${b.voice}
Personality the user picked: ${this.store.data.personality}`
  }

  // MARK: pre-written lines

  get packKey() {
    const d = this.store.data
    const reminders = d.reminders.map(r => `${r.id}|${r.title}|${r.message}`).join(';')
    return [d.selectedCharacter, d.personality, reminders].join('#')
  }

  refreshIfNeeded() {
    if (!this.store.anthropicKey || this.isRefreshing) return
    const pack = this.store.data.linePack
    if (pack && pack.key === this.packKey && Date.now() - pack.date < 6 * 3600000) return
    this.refresh()
  }

  async refresh() {
    const key = this.store.anthropicKey
    if (!key || this.isRefreshing) return
    this.isRefreshing = true
    const wantedKey = this.packKey
    const reminders = this.store.data.reminders.map(r => ({
      id: r.id, emoji: r.emoji, title: r.title, message: r.message, every_minutes: r.intervalMinutes,
    }))
    const schema = Schema.object({
      reminders: Schema.array(Schema.object({ id: Schema.string, nag: Schema.array(Schema.string), praise: Schema.array(Schema.string) })),
      idle: Schema.array(Schema.string),
      sleepy: Schema.array(Schema.string),
    })
    try {
      const response = await send(key, {
        system: this.persona,
        messages: [{ role: 'user', content: [{ type: 'text', text: `Write the speech-bubble lines you'll use today. Bubbles are tiny: keep every line under 55 characters, at most one emoji.
Reminders (JSON): ${JSON.stringify(reminders)}

- reminders: for EACH reminder id, 8 "nag" lines (it's time to do it; varied, playful, increasingly insistent, clearly about that reminder) and 6 "praise" lines (they just did it).
- idle: 14 short ambient lines you say while hanging out on the taskbar (cozy observations, tiny jokes, encouragement, fun facts about hydration or breaks). Never nag here.
- sleepy: 4 lines for quiet hours when you're dozing.
Stay in character.` }] }],
        schema,
        effort: 'low',
      })
      const json = JSON.parse(textOf(response))
      const nag = {}, praise = {}
      for (const r of json.reminders || []) { nag[r.id] = r.nag || []; praise[r.id] = r.praise || [] }
      this.store.set('linePack', { key: wantedKey, date: Date.now(), nag, praise, idle: json.idle || [], sleepy: json.sleepy || [] })
      this.lastError = null
    } catch (e) {
      this.lastError = e.message
    } finally {
      this.isRefreshing = false
    }
  }

  // MARK: chat

  get chatSystem() {
    return this.persona + `

The user is chatting with you through a tiny text box; your reply appears in a speech bubble, so answer in at most 2 short sentences.
You can manage their reminders with tools. Act directly when they ask (e.g. "remind me to stretch every hour", "pause for 30 min", "I just drank water").
Each user message starts with a [status] line describing the current reminders; it's context, not something the user typed.`
  }

  get statusLine() {
    const s = this.store
    const now = new Date()
    const when = now.toLocaleString('en-US', { weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })
    const reminders = s.data.reminders.map(r => {
      const mins = Math.max(0, Math.floor((s.nextDue(r) - Date.now()) / 60000))
      return `${r.emoji} ${r.title} every ${r.intervalMinutes}m, ${r.enabled ? `next in ${mins}m` : 'off'}, ${s.count(r.id)} today`
    })
    const paused = s.isSuppressed ? ' Reminders are currently paused/quiet.' : ''
    return `[status: ${when}. ${reminders.length ? reminders.join('; ') : 'No reminders'}.${paused}]`
  }

  async chat(text) {
    const key = this.store.anthropicKey
    if (!key) return 'Add an Anthropic API key in Settings so I can talk! 🗝️'
    // The history is append-only; start a fresh conversation instead of trimming it.
    const hk = this.store.data.selectedCharacter + this.store.data.personality
    if (this.history.length > 40 || this.historyKey !== hk) { this.history = []; this.historyKey = hk }
    this.history.push({ role: 'user', content: `${this.statusLine}\n${text}` })
    try {
      for (let i = 0; i < 6; i++) {
        const response = await send(key, { system: this.chatSystem, messages: this.history, tools: TOOLS, effort: 'low', maxTokens: 4000 })
        const content = response.content || []
        this.history.push({ role: 'assistant', content })
        const calls = content.filter(b => b.type === 'tool_use')
        if (response.stop_reason !== 'tool_use' || !calls.length) {
          const reply = textOf(response).trim()
          return reply || '👍'
        }
        this.history.push({
          role: 'user',
          content: calls.map(c => ({ type: 'tool_result', tool_use_id: c.id, content: this.run(c.name, c.input || {}) })),
        })
      }
      return 'Done! ✨'
    } catch (e) {
      this.history = []
      return `Oops, my brain glitched: ${e.message}`
    }
  }

  find(title) {
    const t = (title || '').toLowerCase()
    const list = this.store.data.reminders
    return list.find(r => r.title.toLowerCase() === t)
      || list.find(r => r.title.toLowerCase().includes(t) || t.includes(r.title.toLowerCase()))
  }

  run(name, input) {
    const s = this.store
    const title = input.title || ''
    switch (name) {
      case 'add_reminder': {
        const minutes = Math.max(1, input.interval_minutes || 30)
        s.add({ emoji: input.emoji || '⭐️', title, message: input.message || title, intervalMinutes: minutes })
        return `Added ${title} every ${minutes} minutes.`
      }
      case 'update_reminder': {
        const r = this.find(title)
        if (!r) return `No reminder titled ${title}.`
        if (Number.isInteger(input.interval_minutes)) r.intervalMinutes = Math.max(1, input.interval_minutes)
        if (typeof input.message === 'string') r.message = input.message
        if (typeof input.enabled === 'boolean') r.enabled = input.enabled
        s.changed()
        return `Updated ${r.title}.`
      }
      case 'remove_reminder': {
        const r = this.find(title)
        if (!r) return `No reminder titled ${title}.`
        s.set('reminders', s.data.reminders.filter(x => x.id !== r.id))
        return `Removed ${r.title}.`
      }
      case 'log_done': {
        const r = this.find(title)
        if (!r) return `No reminder titled ${title}.`
        s.markDone(r.id)
        return `Logged ${r.title}. ${s.count(r.id)} today.`
      }
      case 'pause_reminders': {
        const minutes = input.minutes || 0
        s.pause(minutes)
        return minutes > 0 ? `Paused for ${minutes} minutes.` : 'Resumed.'
      }
      default:
        return `Unknown tool ${name}.`
    }
  }

  // MARK: line picking (pack lives in the store, so renderers can read it too)

  nagLine(r) { return pick(this.store.data.linePack?.nag?.[r.id]) || `${r.emoji} ${r.message}` }
  praiseLine(r) { return pick(this.store.data.linePack?.praise?.[r.id]) || pick(['Ahh, refreshing!', 'Nice one!', "You're doing great!", 'Proud of you!']) }
  idleLine() { return pick(this.store.data.linePack?.idle) }
  sleepyLine() { return pick(this.store.data.linePack?.sleepy) || 'Zzz… 💤' }
}

module.exports = { Brain }

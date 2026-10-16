// SipBuddy for Windows: a tiny superhero who walks along the taskbar and reminds you to drink water.
// The buddy lives in a transparent, click-through strip window above the taskbar; the tray icon
// plays the role of the macOS menu-bar item.
const path = require('path')
const { app, BrowserWindow, Tray, Menu, ipcMain, screen, nativeImage, shell } = require('electron')
const { Store } = require('./store')
const { Brain } = require('./brain')
require('./shared/hero.js')
const Hero = globalThis.Hero

if (!app.requestSingleInstanceLock()) app.quit()
app.setAppUserModelId('in.tenext.sipbuddy')

let store, brain, tray
let buddyWin, settingsWin, chatWin
let buddyVisible = true
let expanded = false
let refreshTimer = null

const asset = (name) => path.join(__dirname, '..', 'assets', name)
const page = (name) => path.join(__dirname, name, 'index.html')

function lookFor(name) {
  const id = (name || '').replace(/^hero:/, '')
  return store.data.customHeroes.find(h => h.id === id) || Hero.preset(id) || Hero.presets[0]
}

function appearance(l) {
  const parts = [`${l.hairStyle} ${l.hair} hair`, `${l.suit} suit with ${l.accent} accents`]
  if (l.cape) parts.push(`${l.cape} cape`)
  if (l.mask !== 'none') parts.push(`${l.maskColor} ${l.mask}`)
  if (l.emblem !== 'none') parts.push(`${l.emblem} chest emblem`)
  if (l.ears !== 'none') parts.push(`${l.ears} ears`)
  if (l.glasses) parts.push('glasses')
  return parts.join(', ')
}

function bible() {
  const look = lookFor(store.data.selectedCharacter)
  return { name: look.name, appearance: appearance(look), voice: look.voice }
}

// MARK: - Buddy window

function workArea() { return screen.getPrimaryDisplay().workArea }

function stripBounds() {
  const wa = workArea()
  const h = Math.round(store.data.buddyHeight * 1.12 + 170)
  return { x: wa.x, y: wa.y + wa.height - h, width: wa.width, height: h }
}

/** While dragging or falling the window grows to the whole work area; its bottom edge never moves,
 *  so the renderer's bottom-up coordinates stay valid either way. */
function layoutBuddy() {
  if (!buddyWin) return
  buddyWin.setBounds(expanded ? workArea() : stripBounds())
}

function createBuddy() {
  buddyWin = new BrowserWindow({
    ...stripBounds(),
    transparent: true,
    frame: false,
    resizable: false,
    movable: false,
    focusable: false,
    skipTaskbar: true,
    hasShadow: false,
    alwaysOnTop: true,
    backgroundColor: '#00000000',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), backgroundThrottling: false },
  })
  buddyWin.setAlwaysOnTop(true, 'screen-saver')
  buddyWin.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  buddyWin.setIgnoreMouseEvents(true, { forward: true })
  buddyWin.loadFile(page('buddy'))
  buddyWin.on('closed', () => { buddyWin = null })

  // The cursor drives eye tracking and "follow me" while reminding, even when it's outside the window.
  setInterval(() => {
    if (!buddyWin || !buddyVisible) return
    const p = screen.getCursorScreenPoint()
    const b = buddyWin.getBounds()
    buddyWin.webContents.send('cursor', { x: p.x - b.x, y: b.y + b.height - p.y })
  }, 40)
}

function setBuddyVisible(v) {
  buddyVisible = v
  if (!buddyWin) return
  if (v) buddyWin.showInactive()
  else { buddyWin.hide(); chatWin?.hide() }
  updateTray()
}

// MARK: - Settings & chat windows

function openSettings(tab) {
  if (settingsWin) {
    settingsWin.show(); settingsWin.focus()
    if (tab) settingsWin.webContents.send('tab', tab)
    return
  }
  settingsWin = new BrowserWindow({
    width: 820, height: 700, minWidth: 720, minHeight: 560,
    title: 'SipBuddy',
    icon: asset('icon.png'),
    autoHideMenuBar: true,
    backgroundColor: '#f6f6f9',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  })
  settingsWin.loadFile(page('settings'), tab ? { hash: tab } : undefined)
  settingsWin.on('closed', () => { settingsWin = null })
}

function openChat(anchor) {
  if (!buddyWin || !buddyVisible) return
  const b = buddyWin.getBounds()
  const w = 320, h = 52
  const x = Math.round(b.x + anchor.x - w / 2)
  const y = Math.round(b.y + b.height - anchor.top - h - 8)
  if (!chatWin) {
    chatWin = new BrowserWindow({
      width: w, height: h, frame: false, transparent: true, resizable: false, skipTaskbar: true,
      alwaysOnTop: true, show: false, hasShadow: false, backgroundColor: '#00000000',
      webPreferences: { preload: path.join(__dirname, 'preload.js') },
    })
    chatWin.setAlwaysOnTop(true, 'screen-saver')
    chatWin.loadFile(page('chat'))
    chatWin.on('blur', () => chatWin?.hide())
    chatWin.on('closed', () => { chatWin = null })
    chatWin.once('ready-to-show', () => { chatWin.show(); chatWin.focus() })
  } else {
    chatWin.show(); chatWin.focus()
  }
  const wa = workArea()
  chatWin.setBounds({ x: Math.max(wa.x, Math.min(x, wa.x + wa.width - w)), y: Math.max(wa.y, y), width: w, height: h })
  chatWin.webContents.send('chat-open', { placeholder: `Talk to ${bible().name}…  (esc to close)` })
}

// MARK: - Tray

function trayMenu() {
  const items = []
  for (const r of store.data.reminders.filter(r => r.enabled)) {
    const mins = Math.max(0, Math.ceil((store.nextDue(r) - Date.now()) / 60000))
    items.push({ label: `${r.emoji} ${r.title} · ${mins === 0 ? 'now' : `in ${mins} min`} · ${store.count(r.id)} today`, enabled: false })
  }
  if (items.length) items.push({ type: 'separator' })
  const paused = store.data.pausedUntil && store.data.pausedUntil > Date.now()
  items.push(
    { label: 'Done ✓', click: () => buddyWin?.webContents.send('menu', 'done-now') },
    paused ? { label: 'Resume reminders', click: () => store.pause(0) } : { label: 'Pause for 1 hour', click: () => store.pause(60) },
    { label: buddyVisible ? 'Hide buddy' : 'Show buddy', click: () => setBuddyVisible(!buddyVisible) },
    { type: 'separator' },
    { label: 'Settings…', click: () => openSettings() },
    { label: 'Quit SipBuddy', click: () => app.quit() },
  )
  return Menu.buildFromTemplate(items)
}

function updateTray() {
  if (!tray) return
  tray.setContextMenu(trayMenu())
  const next = store.nextUpcoming()
  tray.setToolTip(next ? `SipBuddy · ${next.emoji} ${next.title} in ${Math.max(0, Math.ceil((store.nextDue(next) - Date.now()) / 60000))} min` : 'SipBuddy')
}

function createTray() {
  const icon = nativeImage.createFromPath(asset(process.platform === 'darwin' ? 'trayTemplate.png' : 'tray.png'))
  tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon)
  if (icon.isEmpty()) tray.setTitle?.('💧')
  tray.on('click', () => { if (process.platform === 'win32') tray.popUpContextMenu() })
  tray.on('double-click', () => openSettings())
  updateTray()
  setInterval(updateTray, 30000)
}

// MARK: - IPC

function broadcast() {
  const s = store.publicState
  for (const w of [buddyWin, settingsWin, chatWin]) if (w && !w.isDestroyed()) w.webContents.send('state', s)
}

function setupIPC() {
  ipcMain.handle('state', () => store.publicState)
  ipcMain.handle('act', (_e, name, ...args) => {
    switch (name) {
      case 'set': return store.set(args[0], args[1])
      case 'add': return store.add(args[0])
      case 'markDone': return store.markDone(args[0])
      case 'snooze': return store.snooze(args[0], args[1])
      case 'skip': return store.skip(args[0])
      case 'pause': return store.pause(args[0])
      case 'saveHero': return store.saveHero(args[0])
      case 'deleteHero': return store.deleteHero(args[0])
      case 'setAnthropicKey': store.setAnthropicKey(args[0]); brain.refreshIfNeeded(); return
      case 'setLaunchAtLogin': app.setLoginItemSettings({ openAtLogin: !!args[0] }); broadcast(); return
      case 'refreshLines': return brain.refresh()
    }
  })
  ipcMain.handle('chat', (_e, text) => {
    buddyWin?.webContents.send('thinking', true)
    return brain.chat(text).then(reply => {
      buddyWin?.webContents.send('thinking', false)
      buddyWin?.webContents.send('say', reply)
      return reply
    })
  })
  ipcMain.handle('brainStatus', () => ({ refreshing: brain.isRefreshing, error: brain.lastError }))
  ipcMain.on('chat-close', () => chatWin?.hide())
  ipcMain.on('ignore-mouse', (_e, ignore) => {
    if (!buddyWin) return
    if (ignore) buddyWin.setIgnoreMouseEvents(true, { forward: true })
    else buddyWin.setIgnoreMouseEvents(false)
  })
  ipcMain.on('expand', (_e, on) => {
    if (expanded === on) return
    expanded = on
    layoutBuddy()
  })
  ipcMain.on('open-chat', (_e, anchor) => openChat(anchor))
  ipcMain.on('open-settings', () => openSettings())
  ipcMain.on('open-url', (_e, url) => { if (/^https:\/\//.test(url)) shell.openExternal(url) })
  ipcMain.on('context-menu', (_e, info) => {
    const send = (a) => () => buddyWin?.webContents.send('menu', a)
    const items = []
    if (info.reminding) {
      items.push(
        { label: `Done ✓  ${info.reminding.emoji} ${info.reminding.title}`, click: send('done') },
        { label: 'Snooze 10 min', click: send('snooze') },
        { label: 'Skip this one', click: send('skip') },
        { type: 'separator' },
      )
    }
    items.push(
      { label: `Talk to ${bible().name}…`, click: send('chat') },
      { label: 'Hide buddy', click: () => setBuddyVisible(false) },
      { label: 'Settings…', click: () => openSettings() },
      { type: 'separator' },
      { label: 'Quit SipBuddy', click: () => app.quit() },
    )
    Menu.buildFromTemplate(items).popup({ window: buddyWin })
  })
}

// MARK: - Lifecycle

app.whenReady().then(() => {
  if (process.platform === 'darwin') app.dock?.hide()
  store = new Store()
  brain = new Brain(store, bible)
  setupIPC()
  createBuddy()
  createTray()

  let lastHeight = store.data.buddyHeight
  store.onChange(() => {
    broadcast()
    updateTray()
    if (store.data.buddyHeight !== lastHeight) { lastHeight = store.data.buddyHeight; layoutBuddy() }
    // New reminders / personality / character → fresh lines (debounced so typing doesn't spam the API).
    clearTimeout(refreshTimer)
    refreshTimer = setTimeout(() => brain.refreshIfNeeded(), 4000)
  })
  brain.refreshIfNeeded()

  screen.on('display-metrics-changed', layoutBuddy)
  screen.on('display-added', layoutBuddy)
  screen.on('display-removed', layoutBuddy)

  if (process.argv.includes('--settings') || tabArg(process.argv)) openSettings(tabArg(process.argv))
})

const tabArg = (argv) => (argv.find(a => a.startsWith('--tab=')) || '').slice(6) || undefined
app.on('second-instance', (_e, argv) => openSettings(tabArg(argv)))
app.on('window-all-closed', () => {}) // keep running in the tray

// Headless check of reminders-only presence: away → walks in when due → click → celebrates → walks off → away.
// Usage (from windows/): npx electron tools/presence-test.js <outDir>
const { app, BrowserWindow, ipcMain } = require('electron')
const fs = require('fs')
const path = require('path')
const outDir = path.resolve(process.argv.slice(2).find((a) => !a.startsWith('-') && !a.endsWith('.js')) || 'presence-out')
const now = Date.now()
const state = {
  reminders: [{ id: 'w', emoji: '💧', title: 'Water', message: 'Time to drink some water!', intervalMinutes: 45, enabled: true, lastDone: now - 44.9 * 60000 }],
  buddyHeight: 180, walkSpeed: 45, soundEnabled: false, onlyForReminders: true,
  quietHoursEnabled: false, quietStart: 22, quietEnd: 8, selectedCharacter: 'hero:skyline-her',
  personality: '', pausedUntil: null, todayCounts: {}, countsDate: '', customHeroes: [], linePack: null,
  isFirstLaunch: false,
}
const log = []
ipcMain.handle('test-state', () => state)
ipcMain.on('test-log', (_e, entry) => log.push([((Date.now() - t0) / 1000).toFixed(1), ...entry]))
let t0 = Date.now()
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

app.whenReady().then(async () => {
  fs.mkdirSync(outDir, { recursive: true })
  const win = new BrowserWindow({ width: 1200, height: 380, show: false, transparent: true, frame: false,
    webPreferences: { preload: path.join(__dirname, 'test-preload.js'), offscreen: true, backgroundThrottling: false } })
  await win.loadFile(path.join(__dirname, '../src/buddy/index.html'))
  const js = (c) => win.webContents.executeJavaScript(c)
  const snap = async (name) => fs.writeFileSync(path.join(outDir, name), (await win.webContents.capturePage()).toPNG())
  const sample = async () => js(`({ mode: mode.kind, x: Math.round(x) })`)
  await js(`__test.cursor({ x: 900, y: 120 })`)
  t0 = Date.now()
  const timeline = []
  let clicked = false
  for (let i = 0; i < 120; i++) {
    const s = await sample()
    timeline.push(`${((Date.now() - t0) / 1000).toFixed(1)}s ${s.mode} x=${s.x}`)
    if (i === 2) await snap('0-away.png')
    if (s.mode === 'reminding' && Math.abs(s.x - 900) < 170 && !clicked) {
      await snap('1-reminding.png')
      // Make the reminder due "now" in the fake store once clicked.
      await js(`handleClick()`)
      // A second, accidental click during the celebration must be ignored.
      await sleep(300); await js(`handleClick()`)
      clicked = true
      // What the real store broadcasts after markDone.
      state.reminders[0].lastDone = Date.now()
      await js(`__test.state(${JSON.stringify(state)})`)
      await sleep(900); await snap('2-celebrating.png')
    }
    if (clicked && s.mode === 'leaving' && !fs.existsSync(path.join(outDir, '3-leaving.png'))) await snap('3-leaving.png')
    if (clicked && s.mode === 'away') { await snap('4-away.png'); break }
    await sleep(250)
  }
  fs.writeFileSync(path.join(outDir, 'timeline.txt'), timeline.join('\n') + '\n\nIPC:\n' + log.map((l) => l.join(' ')).join('\n'))
  console.log('done')
  app.quit()
})

// Renders the README demo: PNG frames for the video, plus still images.
// Usage (from windows/): npx electron tools/demo.js <outDir> [frames|stills|all]
const { app, BrowserWindow } = require('electron')
const fs = require('fs')
const path = require('path')

const args = process.argv.slice(2).filter((a) => !a.startsWith('-') && !a.endsWith('demo.js'))
const outDir = path.resolve(args[0] || 'demo-out')
const what = args[1] || 'all'

const save = (file, dataURL) => fs.writeFileSync(path.join(outDir, file), Buffer.from(dataURL.split(',')[1], 'base64'))

app.whenReady().then(async () => {
  fs.mkdirSync(path.join(outDir, 'frames'), { recursive: true })
  const win = new BrowserWindow({ show: false, webPreferences: { offscreen: true } })
  await win.loadFile(path.join(__dirname, 'demo.html'))
  const js = (code) => win.webContents.executeJavaScript(code)

  if (what === 'all' || what === 'stills') {
    save('banner.png', await js('demo.renderBanner()'))
    save('heroines.png', await js("demo.renderBanner('heroines')"))
    save('heroes.png', await js('demo.renderFour()'))
    console.log('stills done')
  }
  if (what === 'all' || what === 'frames') {
    await js('location.reload()')
    await new Promise((r) => win.webContents.once('did-finish-load', r))
    const n = await js('demo.frames')
    for (let i = 0; i < n; i++) {
      save(`frames/f${String(i).padStart(4, '0')}.png`, await js(`demo.renderFrame(${i})`))
    }
    console.log(`${n} frames done`)
  }
  app.quit()
})

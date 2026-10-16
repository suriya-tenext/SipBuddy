// Usage (from windows/): npx electron tools/contact.js out.png [onlyIds] [cellPx]
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');

const [out = 'contact.png', only = '', cell = '300'] = process.argv.slice(2).filter((a) => !a.startsWith('-') && !a.endsWith('contact.js'));

app.whenReady().then(async () => {
    const win = new BrowserWindow({ show: false, webPreferences: { offscreen: true } });
    await win.loadFile(path.join(__dirname, 'contact.html'), { query: { only, cell } });
    const err = await win.webContents.executeJavaScript('window.result ? null : "no result"');
    if (err) { console.error(err); app.exit(1); return; }
    const data = await win.webContents.executeJavaScript('window.result');
    const ms = await win.webContents.executeJavaScript('window.renderMs');
    fs.writeFileSync(path.resolve(out), Buffer.from(data.split(',')[1], 'base64'));
    console.log(`wrote ${out} (${ms.toFixed(1)} ms)`);
    app.quit();
});

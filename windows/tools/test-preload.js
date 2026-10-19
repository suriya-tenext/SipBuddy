// Stub of src/preload.js for headless tests: serves window.__testState and records calls.
const { contextBridge, ipcRenderer } = require('electron')
const handlers = {}
const on = (name) => (fn) => { handlers[name] = fn }
contextBridge.exposeInMainWorld('sip', {
  platform: 'test',
  getState: () => ipcRenderer.invoke('test-state'),
  act: (...a) => { ipcRenderer.send('test-log', ['act', ...a]); return Promise.resolve() },
  chat: () => Promise.resolve(''),
  brainStatus: () => Promise.resolve({}),
  onState: on('state'), onCursor: on('cursor'), onMenu: on('menu'), onSay: on('say'),
  onThinking: on('thinking'), onTab: on('tab'), onChatOpen: on('chatOpen'),
  ignoreMouse: () => {}, expand: () => {}, openChat: () => {}, openSettings: () => {}, openURL: () => {},
  contextMenu: () => {}, closeChat: () => {},
  setAway: (away) => ipcRenderer.send('test-log', ['away', away]),
})
contextBridge.exposeInMainWorld('__test', {
  cursor: (c) => handlers.cursor && handlers.cursor(c),
  state: (s) => handlers.state && handlers.state(s),
})

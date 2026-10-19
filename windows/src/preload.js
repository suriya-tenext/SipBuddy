// The only bridge between the pages and the main process.
const { contextBridge, ipcRenderer } = require('electron')

const on = (channel) => (fn) => ipcRenderer.on(channel, (_e, ...args) => fn(...args))

contextBridge.exposeInMainWorld('sip', {
  platform: process.platform,
  getState: () => ipcRenderer.invoke('state'),
  act: (name, ...args) => ipcRenderer.invoke('act', name, ...args),
  chat: (text) => ipcRenderer.invoke('chat', text),
  brainStatus: () => ipcRenderer.invoke('brainStatus'),
  onState: on('state'),
  onCursor: on('cursor'),
  onMenu: on('menu'),
  onSay: on('say'),
  onThinking: on('thinking'),
  onTab: on('tab'),
  onChatOpen: on('chat-open'),
  ignoreMouse: (ignore) => ipcRenderer.send('ignore-mouse', ignore),
  expand: (on) => ipcRenderer.send('expand', on),
  openChat: (anchor) => ipcRenderer.send('open-chat', anchor),
  openSettings: () => ipcRenderer.send('open-settings'),
  openURL: (url) => ipcRenderer.send('open-url', url),
  contextMenu: (info) => ipcRenderer.send('context-menu', info),
  closeChat: () => ipcRenderer.send('chat-close'),
  setAway: (away) => ipcRenderer.send('buddy-away', away),
})

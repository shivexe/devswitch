// Relays content-script requests to the DevSwitch app through the native host.
// Codes are never stored; they only pass through to the frame that asked.
const HOST = 'dev.notsg.devswitch';
let native = null;
let seq = 0;
const pending = new Map();
const waiters = new Set();

function connect() {
  if (native) return native;
  native = chrome.runtime.connectNative(HOST);
  native.onMessage.addListener(message => {
    if (message.push) {
      for (const port of waiters) port.postMessage({ otp: message.otp || null });
      return;
    }
    const resolve = pending.get(message.id);
    pending.delete(message.id);
    if (resolve) resolve(message);
  });
  native.onDisconnect.addListener(() => {
    native = null;
    for (const resolve of pending.values()) resolve(null);
    pending.clear();
    // Reconnect only while a frame is still waiting for a code.
    if (waiters.size) setTimeout(() => waiters.size && request('subscribe'), 2000);
  });
  return native;
}

function request(type) {
  return new Promise(resolve => {
    const id = ++seq;
    pending.set(id, resolve);
    setTimeout(() => pending.delete(id) && resolve(null), 3000);
    try { connect().postMessage({ id, type }); } catch { pending.delete(id); resolve(null); }
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id) return;
  if (message.type === 'get') {
    request('getOtp').then(reply => sendResponse(reply?.otp || null));
    return true;
  }
  if (message.type === 'consumed') request('consumed');
});

chrome.runtime.onConnect.addListener(port => {
  if (port.name !== 'otp-wait' || port.sender?.id !== chrome.runtime.id) return;
  waiters.add(port);
  port.onDisconnect.addListener(() => waiters.delete(port));
  request('subscribe');
});

// Test-only stand-in for the DevSwitch native host, prepended to the service worker.
// Tests drive it from the service worker with __setOtp(otp) and __push(otp).
(() => {
  let otp = null;
  self.__requests = 0;
  const subscribers = new Set();
  self.__setOtp = value => { otp = value; };
  self.__getOtp = () => otp;
  self.__push = value => { otp = value; for (const port of subscribers) port.emit({ push: true, otp }); };
  Object.defineProperty(chrome.runtime, 'connectNative', { configurable: true, value: () => {
    const messageListeners = [];
    const port = {
      onMessage: { addListener: f => messageListeners.push(f) },
      onDisconnect: { addListener: () => {} },
      emit: message => setTimeout(() => messageListeners.forEach(f => f(message))),
      postMessage(request) {
        if (request.type === 'getOtp') self.__requests++, port.emit({ id: request.id, otp });
        if (request.type === 'consumed') { otp = null; port.emit({ id: request.id, ok: true }); }
        if (request.type === 'subscribe') { subscribers.add(port); port.emit({ id: request.id, ok: true }); }
      },
    };
    return port;
  } });
})();

// Detects one-time-code fields and offers the phone's latest code in a chip.
// A code is requested only when a detected field is focused or hovered, and is
// written into the page only when the user clicks the chip.
(() => {
  const HINT = /\b(otp|one[-_ ]?time|2fa|mfa|totp|verification|verify|security|auth(entication)?)[-_ ]?(code|pin|token)?\b|\bcode\b/i;
  const BLOCK = /card|cvv|cvc|csc|zip|postal|phone|mobile|amount|captcha|coupon|promo|gift/i;
  const TYPES = new Set(['text', 'tel', 'number', '']);
  const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  let chip = null;
  let target = null;
  let waitPort = null;
  let lastAsk = { field: null, at: 0 };

  const usable = el => el instanceof HTMLInputElement && TYPES.has(el.getAttribute('type')?.toLowerCase() ?? '')
    && !el.disabled && !el.readOnly && el.getClientRects().length > 0;

  function describe(el) {
    const parts = [el.name, el.id, el.placeholder, el.getAttribute('aria-label')];
    for (const label of el.labels || []) parts.push(label.textContent);
    for (const id of (el.getAttribute('aria-labelledby') || '').split(/\s+/)) parts.push(document.getElementById(id)?.textContent);
    return parts.filter(Boolean).join(' ').replace(/([a-z])([A-Z])/g, '$1 $2');
  }

  function splitBoxes(el) {
    if (el.maxLength !== 1) return null;
    for (let box = el.parentElement, depth = 0; box && depth < 3; box = box.parentElement, depth++) {
      const top = el.getBoundingClientRect().top;
      const boxes = [...box.querySelectorAll('input')]
        .filter(i => usable(i) && i.maxLength === 1 && Math.abs(i.getBoundingClientRect().top - top) < 10);
      if (boxes.length >= 4 && boxes.length <= 8) {
        return boxes.sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
      }
    }
    return null;
  }

  // Returns the inputs to fill (one, or the split boxes left to right), or null.
  function detect(el) {
    if (!usable(el)) return null;
    const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
    const oneTimeCode = autocomplete.split(/\s+/).includes('one-time-code');
    const text = describe(el);
    if (!oneTimeCode && (BLOCK.test(text) || /cc-|tel|postal/.test(autocomplete))) return null;
    const boxes = splitBoxes(el);
    if (boxes) return boxes;
    if (oneTimeCode) return [el];
    const max = el.getAttribute('maxlength') === null ? 0 : el.maxLength;
    if (max && (max < 4 || max > 8)) return null;
    return HINT.test(text) ? [el] : null;
  }

  function fill(fields, code) {
    const chars = fields.length > 1 && code.length !== fields.length ? code.replace(/\D/g, '') : code;
    const values = fields.length > 1 ? [...chars] : [chars];
    fields.forEach((field, i) => {
      field.focus();
      setValue.call(field, values[i] ?? '');
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
    });
    const last = fields[fields.length - 1];
    last.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: values[values.length - 1] || '' }));
  }

  function hide() {
    chip?.remove();
    chip = null;
  }

  function stopWaiting() {
    waitPort?.disconnect();
    waitPort = null;
  }

  function domainMatches(domain) {
    const host = location.hostname;
    return !domain || host === domain || host.endsWith('.' + domain);
  }

  function show(fields, otp) {
    if (!otp?.code || !domainMatches(otp.domain) || target !== fields[0]) return;
    hide();
    chip = document.createElement('devswitch-otp-chip');
    const root = chip.attachShadow({ mode: 'closed' });
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = `From your phone: ${otp.code} · Fill`;
    if (otp.domain) button.title = `For ${otp.domain}`;
    const style = document.createElement('style');
    style.textContent = `button{all:initial;font:500 13px -apple-system,system-ui,sans-serif;color:#fff;background:#1f6feb;
      padding:6px 10px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,.25);cursor:pointer;white-space:nowrap}
      button:hover{background:#1858c4}`;
    root.append(style, button);
    const rect = fields[0].getBoundingClientRect();
    Object.assign(chip.style, { position: 'fixed', zIndex: 2147483647, left: `${rect.left}px`, top: `${rect.bottom + 4}px` });
    // Keep focus in the field while clicking the chip.
    button.addEventListener('pointerdown', e => e.preventDefault());
    button.addEventListener('click', e => {
      if (!e.isTrusted) return;
      fill(fields, otp.code);
      chrome.runtime.sendMessage({ type: 'consumed' });
      hide();
      stopWaiting();
    });
    document.documentElement.append(chip);
  }

  function offer(el) {
    const fields = detect(el);
    if (!fields) return;
    target = fields[0];
    if (chip) return;
    const now = Date.now();
    if (lastAsk.field === target && now - lastAsk.at < 2000) return;
    lastAsk = { field: target, at: now };
    chrome.runtime.sendMessage({ type: 'get' }, otp => {
      if (chrome.runtime.lastError) return;
      if (otp) return show(fields, otp);
      if (waitPort) return;
      // No code yet: wait up to 60 s for one to arrive.
      waitPort = chrome.runtime.connect({ name: 'otp-wait' });
      waitPort.onMessage.addListener(message => show(fields, message.otp));
      waitPort.onDisconnect.addListener(() => { waitPort = null; });
      setTimeout(stopWaiting, 60000);
    });
  }

  document.addEventListener('focusin', e => offer(e.target), true);
  document.addEventListener('pointerover', e => {
    if (detect(e.target)) return offer(e.target);
    // Pointer left a hovered (not focused) field: drop the chip.
    if (e.target !== chip && target && !detect(document.activeElement)) {
      hide();
      target = null;
    }
  }, true);
  document.addEventListener('focusout', () => setTimeout(() => {
    if (!detect(document.activeElement)) { hide(); target = null; }
  }, 200), true);
  document.addEventListener('keydown', e => e.key === 'Escape' && hide(), true);
  addEventListener('scroll', hide, true);
})();

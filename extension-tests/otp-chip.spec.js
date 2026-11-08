const { test, expect, chromium } = require('@playwright/test');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const ROOT = __dirname;
const CODE = '482913';
const OTP = { code: CODE, source: 'HDFC Bank', domain: null };
let context, worker, servers;

function serve(port) {
  return new Promise(resolve => {
    const server = http.createServer((req, res) => {
      const file = path.join(ROOT, decodeURIComponent(new URL(req.url, 'http://x').pathname));
      if (!file.startsWith(ROOT) || !fs.existsSync(file)) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : 'text/javascript' });
      fs.createReadStream(file).pipe(res);
    });
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

test.beforeAll(async () => {
  servers = await Promise.all([serve(4401), serve(4402)]);
  // Copy the real extension and swap the native host for the stub.
  const ext = fs.mkdtempSync(path.join(os.tmpdir(), 'devswitch-ext-'));
  fs.cpSync(path.join(ROOT, '..', 'extension'), ext, { recursive: true });
  const sw = path.join(ext, 'service-worker.js');
  fs.writeFileSync(sw, fs.readFileSync(path.join(ROOT, 'native-stub.js'), 'utf8') + fs.readFileSync(sw, 'utf8'));
  context = await chromium.launchPersistentContext('', {
    channel: 'chromium',
    headless: true,
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`],
  });
  [worker] = context.serviceWorkers();
  worker ??= await context.waitForEvent('serviceworker');
});

test.afterAll(async () => {
  await context?.close();
  servers?.forEach(s => s.close());
});

const setOtp = otp => worker.evaluate(value => self.__setOtp(value), otp);
const getOtp = () => worker.evaluate(() => self.__getOtp());

// The chip lives in a closed shadow root; read its text through CDP, which can pierce it.
async function chipText(page) {
  const cdp = await context.newCDPSession(page);
  const { root } = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
  const texts = [];
  const walk = node => {
    if (node.nodeType === 3 && node.nodeValue.includes('From your phone')) texts.push(node.nodeValue);
    for (const child of [...(node.children || []), ...(node.shadowRoots || []), ...(node.contentDocument ? [node.contentDocument] : [])]) walk(child);
  };
  walk(root);
  await cdp.detach();
  return texts.join('|');
}

async function open(name) {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:4401/fixtures/${name}.html`);
  return page;
}

test('autocomplete=one-time-code: chip on focus, one click fills and consumes', async () => {
  await setOtp(OTP);
  const page = await open('single');
  await page.click('#otp');
  const chip = page.locator('devswitch-otp-chip');
  await expect(chip).toBeVisible();
  expect(await chipText(page)).toBe(`From your phone: ${CODE} · Fill`);
  await chip.click();
  await expect(page.locator('#otp')).toHaveValue(CODE);
  await expect(chip).toHaveCount(0);
  await expect.poll(getOtp).toBeNull();
  await expect(page.locator('#otp')).toBeFocused();
  await page.close();
});

test('chip appears on hover without focus', async () => {
  await setOtp(OTP);
  const page = await open('single');
  await page.hover('#otp');
  await expect(page.locator('devswitch-otp-chip')).toBeVisible();
  await page.mouse.move(500, 500);
  await expect(page.locator('devswitch-otp-chip')).toHaveCount(0);
  await page.close();
});

test('split 6-box input fills one digit per box with input/change events', async () => {
  await setOtp(OTP);
  const page = await open('split');
  await page.evaluate(() => {
    window.events = [];
    document.querySelectorAll('input').forEach((el, i) => ['input', 'change'].forEach(t => el.addEventListener(t, () => events.push(`${t}${i}`))));
  });
  await page.locator('input').nth(2).click();
  await page.locator('devswitch-otp-chip').click();
  const values = await page.locator('input').evaluateAll(els => els.map(e => e.value));
  expect(values).toEqual([...CODE]);
  const events = await page.evaluate(() => window.events);
  for (let i = 0; i < 6; i++) expect(events).toEqual(expect.arrayContaining([`input${i}`, `change${i}`]));
  await page.close();
});

for (const id of ['byName', 'byLabel', 'byAria']) {
  test(`field without autocomplete hint is detected (${id})`, async () => {
    await setOtp(OTP);
    const page = await open('no-hints');
    await page.click(`#${id}`);
    await page.locator('devswitch-otp-chip').click();
    await expect(page.locator(`#${id}`)).toHaveValue(CODE);
    await page.close();
  });
}

test('non-OTP fields never show the chip or request a code', async () => {
  await setOtp(OTP);
  await worker.evaluate(() => { self.__requests = 0; });
  const page = await open('negatives');
  for (const id of ['password', 'cvv', 'phone', 'amount', 'name', 'zip', 'search']) {
    await page.click(`#${id}`);
    await page.hover(`#${id}`);
  }
  await page.waitForTimeout(800);
  await expect(page.locator('devswitch-otp-chip')).toHaveCount(0);
  expect(await getOtp()).toEqual(OTP);
  expect(await worker.evaluate(() => self.__requests)).toBe(0);
  await page.close();
});

test('React controlled input: component state updates', async () => {
  await setOtp(OTP);
  const page = await open('react');
  await page.click('#otp');
  await page.locator('devswitch-otp-chip').click();
  await expect(page.locator('#state')).toHaveText(CODE);
  await expect(page.locator('#otp')).toHaveValue(CODE);
  await page.close();
});

test('cross-origin iframe field gets the chip inside the frame', async () => {
  await setOtp(OTP);
  const page = await open('iframe');
  const frame = page.frameLocator('#frame');
  await frame.locator('#otp').click();
  await frame.locator('devswitch-otp-chip').click();
  await expect(frame.locator('#otp')).toHaveValue(CODE);
  await expect(page.locator('devswitch-otp-chip')).toHaveCount(0);
  await page.close();
});

test('code arriving after focus is pushed to the waiting field', async () => {
  await setOtp(null);
  const page = await open('single');
  await page.click('#otp');
  await page.waitForTimeout(500);
  await expect(page.locator('devswitch-otp-chip')).toHaveCount(0);
  await worker.evaluate(value => self.__push(value), OTP);
  await page.locator('devswitch-otp-chip').click();
  await expect(page.locator('#otp')).toHaveValue(CODE);
  await page.close();
});

test('domain-bound code is not offered on another site', async () => {
  await setOtp({ ...OTP, domain: 'example.com' });
  const page = await open('single');
  await page.click('#otp');
  await page.waitForTimeout(800);
  await expect(page.locator('devswitch-otp-chip')).toHaveCount(0);
  await page.close();
});

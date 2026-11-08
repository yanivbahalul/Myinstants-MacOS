// LAN server for the iPhone remote (the SwiftUI app in ios/). The phone browses the same lists the
// desktop window shows and tells this Mac which sound to play; nothing plays on the phone itself.
//
// - Off by default. Turned on from the app's 📱 menu, and the choice is remembered.
// - Every request must carry the 6-digit pairing PIN in an X-Pin header. Repeated wrong PINs lock
//   the server for a while, so the PIN can't be guessed by brute force from the local network.
// - Advertised over Bonjour (_myinstants._tcp) with macOS's own dns-sd tool, so the phone finds the
//   Mac by name without typing an IP address. Nothing secret goes in the advertisement.
const http = require('http');
const os = require('os');
const fs = require('fs');
const crypto = require('crypto');
const { spawn, execFileSync } = require('child_process');

const SERVICE_TYPE = '_myinstants._tcp';
const PORTS = [47800, 47801, 47802, 47803, 47804];
const MAX_BODY = 16 * 1024;
const LOCK_AFTER = 10; // wrong PINs within LOCK_WINDOW before the server stops answering
const LOCK_WINDOW = 10 * 60 * 1000;
// Only the site's own sound files: the phone must not be able to make this Mac play arbitrary URLs.
const SOUND_URL = /^https:\/\/www\.myinstants\.com\/media\/sounds\/[^\s"'<>\\]+$/;

const newPinValue = () => String(crypto.randomInt(0, 1000000)).padStart(6, '0');

function computerName() {
  if (process.platform === 'darwin') {
    try { return execFileSync('scutil', ['--get', 'ComputerName'], { encoding: 'utf8' }).trim() || os.hostname(); } catch {}
  }
  return os.hostname().replace(/\.local$/, '');
}

// IPv4 addresses on the local network, for typing in by hand when Bonjour can't be used.
function lanAddresses() {
  return Object.values(os.networkInterfaces()).flat()
    .filter((a) => a && a.family === 'IPv4' && !a.internal)
    .map((a) => a.address);
}

function createRemote({ configPath, version, handlers }) {
  let cfg = { enabled: false, pin: newPinValue() };
  try { cfg = { ...cfg, ...JSON.parse(fs.readFileSync(configPath, 'utf8')) }; } catch {}
  const save = () => { try { fs.writeFileSync(configPath, JSON.stringify(cfg)); } catch {} };
  save();

  const name = computerName();
  let server = null, port = null, advert = null, volume = 1, lastError = null;
  let failures = [];

  const pinMatches = (given) => {
    const a = Buffer.from(String(given || '')), b = Buffer.from(cfg.pin);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  };

  function send(res, status, body) {
    const data = JSON.stringify(body);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(data);
  }

  function readJson(req) {
    return new Promise((resolve, reject) => {
      let size = 0; const chunks = [];
      req.on('data', (c) => {
        size += c.length;
        if (size > MAX_BODY) { reject(new Error('body too large')); req.destroy(); return; }
        chunks.push(c);
      });
      req.on('end', () => {
        if (!chunks.length) return resolve({});
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { reject(new Error('bad JSON')); }
      });
      req.on('error', reject);
    });
  }

  async function route(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const now = Date.now();
    failures = failures.filter((t) => now - t < LOCK_WINDOW);
    if (failures.length >= LOCK_AFTER) return send(res, 429, { error: 'too many wrong PINs — try again in a few minutes' });
    if (!pinMatches(req.headers['x-pin'])) {
      failures.push(now);
      return send(res, 401, { error: 'wrong PIN' });
    }
    const r = `${req.method} ${url.pathname}`;
    switch (r) {
      case 'GET /api/hello':
        return send(res, 200, { name, version, loggedIn: await handlers.loggedIn().catch(() => false), volume });
      case 'GET /api/sounds': {
        const page = Math.max(1, Math.min(500, parseInt(url.searchParams.get('page'), 10) || 1));
        return send(res, 200, await handlers.sounds(url.searchParams.get('path'), page));
      }
      case 'GET /api/instant': {
        const d = await handlers.instant(url.searchParams.get('page'));
        return d ? send(res, 200, d) : send(res, 404, { error: "couldn't load that sound" });
      }
      case 'POST /api/play': {
        const { url: soundUrl, name: soundName } = await readJson(req);
        if (typeof soundUrl !== 'string' || !SOUND_URL.test(soundUrl)) return send(res, 400, { error: 'not a myinstants.com sound' });
        handlers.send({ action: 'play', url: soundUrl, name: typeof soundName === 'string' ? soundName.slice(0, 200) : '' });
        return send(res, 200, { ok: true });
      }
      case 'POST /api/stop':
        handlers.send({ action: 'stop' });
        return send(res, 200, { ok: true });
      case 'POST /api/volume': {
        const v = Number((await readJson(req)).volume);
        if (!Number.isFinite(v)) return send(res, 400, { error: 'bad volume' });
        volume = Math.max(0, Math.min(1, v));
        handlers.send({ action: 'volume', volume });
        return send(res, 200, { ok: true });
      }
      case 'POST /api/favorite': {
        const { id, on } = await readJson(req);
        await handlers.favorite(String(id), !!on);
        handlers.send({ action: 'favorites-changed' });
        return send(res, 200, { ok: true });
      }
      default:
        return send(res, 404, { error: 'not found' });
    }
  }

  function advertise() {
    if (process.platform !== 'darwin' || advert) return;
    try {
      advert = spawn('dns-sd', ['-R', name, SERVICE_TYPE, 'local', String(port), `v=${version}`], { stdio: 'ignore' });
      advert.on('exit', () => { advert = null; });
      advert.on('error', () => { advert = null; });
    } catch { advert = null; }
  }

  function listen(i = 0) {
    if (i >= PORTS.length) { lastError = 'all remote ports are in use'; server = null; return; }
    server.once('error', (e) => {
      if (e.code === 'EADDRINUSE') return listen(i + 1);
      lastError = e.message; server = null;
    });
    server.listen(PORTS[i], '0.0.0.0', () => {
      server.removeAllListeners('error');
      server.on('error', (e) => { lastError = e.message; });
      port = PORTS[i]; lastError = null; advertise();
    });
  }

  function start() {
    if (!cfg.enabled || server) return;
    server = http.createServer((req, res) => {
      route(req, res).catch((e) => { if (!res.headersSent) send(res, 500, { error: String(e.message || e).replace(/^Error: /, '') }); });
    });
    server.requestTimeout = 90 * 1000; // page loads go through the bot-check window and can be slow
    listen();
  }

  function stop() {
    if (advert) { advert.kill(); advert = null; }
    if (server) { server.close(); server.closeAllConnections?.(); server = null; }
    port = null;
  }

  const info = () => ({ enabled: cfg.enabled, running: !!port, port, pin: cfg.pin, name, addresses: lanAddresses(), error: lastError });

  return {
    start,
    shutdown: stop,
    info,
    setEnabled(on) {
      cfg.enabled = on; save();
      if (on) start(); else stop();
      // listen() is async; give it a moment so the menu shows the real port straight away
      return new Promise((r) => setTimeout(() => r(info()), 150));
    },
    newPin() { cfg.pin = newPinValue(); failures = []; save(); return info(); },
    setVolume(v) { if (Number.isFinite(+v)) volume = Math.max(0, Math.min(1, +v)); },
  };
}

module.exports = { createRemote };

const { app, BrowserWindow, BrowserView, ipcMain, shell, session } = require('electron');
const path = require('path');
const fs = require('fs');
const { parseSounds, parseProfile, parseInstant, parsePager } = require('./parse');
const os = require('os');
const { execFile } = require('child_process');

// myinstants.com rejects sounds over 300KB and MP3s with embedded cover art ("File type is not
// supported"). Stripping the tags is plain byte work done here, so a normal MP3 needs nothing
// installed; only shrinking an oversized file or converting a non-MP3 needs ffmpeg — bundled in
// ./bin if present, else Homebrew's (apps launched from Finder don't get Homebrew's PATH).
const MAX_SOUND_BYTES = 300 * 1024;
const FFMPEG = [path.join(__dirname, 'bin', 'ffmpeg'), '/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'].find((p) => fs.existsSync(p));
const ffmpeg = (args) => new Promise((resolve, reject) =>
  execFile(FFMPEG, ['-v', 'error', '-y', ...args], (err, _out, stderr) => (err ? reject(new Error(stderr || err.message)) : resolve())));

// Drops ID3v2 tags (where cover art lives) from the front and an ID3v1 tag from the end.
// Returns null when what's left doesn't start with an MP3 frame, i.e. it isn't a plain MP3.
function stripMp3Tags(buf) {
  let start = 0, end = buf.length;
  while (end - start >= 10 && buf.toString('latin1', start, start + 3) === 'ID3') {
    const size = ((buf[start + 6] & 0x7f) << 21) | ((buf[start + 7] & 0x7f) << 14) | ((buf[start + 8] & 0x7f) << 7) | (buf[start + 9] & 0x7f);
    start += 10 + size + (buf[start + 5] & 0x10 ? 10 : 0); // 0x10 flag = 10-byte footer
  }
  while (start < end && buf[start] === 0) start++; // padding some taggers leave past the declared size
  if (end - start >= 128 && buf.toString('latin1', end - 128, end - 125) === 'TAG') end -= 128;
  return buf[start] === 0xff && (buf[start + 1] & 0xe0) === 0xe0 ? buf.subarray(start, end) : null;
}

async function prepareSound(src) {
  const bare = stripMp3Tags(fs.readFileSync(src));
  if (bare && bare.length <= MAX_SOUND_BYTES) return bare;
  if (!FFMPEG) throw new Error(bare ? 'sound is over 300KB — shrinking it needs ffmpeg' : 'only MP3 files can be uploaded without ffmpeg');
  const out = path.join(os.tmpdir(), `myinstants-upload-${process.pid}-${Date.now()}.mp3`);
  try {
    for (const codec of [['-b:a', '96k'], ['-b:a', '64k'], ['-b:a', '48k'], ['-b:a', '32k'], ['-ac', '1', '-b:a', '24k']]) {
      await ffmpeg(['-i', src, '-map', '0:a:0', '-map_metadata', '-1', '-id3v2_version', '0', ...codec, '-f', 'mp3', out]);
      if (fs.statSync(out).size <= MAX_SOUND_BYTES) return fs.readFileSync(out);
    }
  } finally {
    fs.rmSync(out, { force: true });
  }
  throw new Error('sound is too long to fit under 300KB — trim it first');
}

const BASE = 'https://www.myinstants.com';
// loadURL's promise rejects on any failed or superseded load (ERR_ABORTED when the next request
// starts first). Failures are already handled through did-fail-load / waitForChallenge, so the
// promise itself is only silenced here instead of becoming an unhandled rejection.
const load = (wc, url) => wc.loadURL(url).catch(() => {});
// No User-Agent override, on purpose — this used to fake a plain-Chrome UA to hide that this is
// Electron, which is exactly backwards: a UA claiming "Chrome/x" with none of the Client Hints data
// (sec-ch-ua, userAgentData) a real Chrome install always sends alongside it is a textbook spoof
// signature, and it's what was tripping Cloudflare's Turnstile. A documented, merged fix for the
// same symptom in another Electron app (stablyai/orca#18749) ran a deterministic A/B on this exact
// question: every spoofed-Chrome variant stayed stuck on "Just a moment", while the stock Electron
// UA (Electron/x.y.z token included, left completely alone) cleared cleanly — same binary, same
// machine, same IP, only the UA handling differed. TLS/HTTP2 fingerprints were identical either way,
// so this was never a network-layer problem, just an honesty-of-headers one.
// A plain fetch() gets 403'd by the site's bot protection even for ordinary public pages (profiles
// included — no login needed, the protection just can't tell that from a bare HTTP request). A real
// (hidden) browser window passes the same automatic check a visible window does, because it actually
// runs the page's JS, so every page read goes through one here instead. Calls are serialized — one
// hidden window, one navigation at a time — since a single webContents can't run two navigations at once.
let hiddenWin = null;
const HIDDEN_WIN_HOSTS = new Set(['www.myinstants.com', 'myinstants.com', 'challenges.cloudflare.com']);
function getHiddenWindow() {
  if (!hiddenWin || hiddenWin.isDestroyed()) {
    // Images stay enabled even though this window is never shown and we only read HTML text: sites
    // behind Cloudflare bot-protection often use ordinary image loads as one of the signals that a
    // visitor is a real browser, and disabling them here was a likely cause of pages getting flagged.
    // (show: true was tried next, on the theory that a never-shown window reporting
    // document.visibilityState as "hidden" might be a factor — it made things worse (loads started
    // timing out generally, and a visible window flashed on screen), so back to show: false.)
    // backgroundThrottling defaults to true in Electron, which throttles timers/rendering for any
    // window that isn't visible — exactly this window, always. That's why a page loads instantly in
    // a real foreground browser tab but drags (or stalls) here: disable it so the hidden window gets
    // full priority instead of background-tab treatment.
    hiddenWin = new BrowserWindow({ show: false, webPreferences: { partition: 'persist:myinstants-read', backgroundThrottling: false } });
    // Nothing in this window is ever shown, so its ~100 ad/tracker requests per page (to ~56 other
    // hosts) are pure waste. Only the site itself (its own images included, per the note above) and
    // Cloudflare's challenge host get through. Scoped to this window: the visible login/settings
    // pages share the session but may need other hosts (e.g. signing in with Google).
    const ownId = hiddenWin.webContents.id;
    hiddenWin.webContents.session.webRequest.onBeforeRequest((d, cb) => {
      cb({ cancel: d.webContentsId === ownId && /^https?:/.test(d.url) && !HIDDEN_WIN_HOSTS.has(new URL(d.url).hostname) });
    });
  }
  return hiddenWin;
}

// Cloudflare's block/challenge pages come in several wordings; catch the common ones. A block page
// silently parsed as "this page has no sounds" is worse than an honest error, so getHtml below throws
// rather than ever handing one back as if it were real content.
// Only the page <title> and Cloudflare's own element ids are checked — never the body text, since a
// real list can contain a sound literally named "Access denied" or "Just a moment".
const CHALLENGE_TITLE = /^\s*(?:Just a moment|Checking your browser|Please wait)\s*(?:\.\.\.|…)?\s*$|\bCloudflare\b/i;
const CHALLENGE_MARKUP = /id="(?:cf-wrapper|cf-error-details|challenge-form|challenge-running)"|class="cf-browser-verification/;
const isChallenge = (html) => CHALLENGE_TITLE.test((html.match(/<title[^>]*>([^<]*)/i) || [])[1] || '') || CHALLENGE_MARKUP.test(html);

function waitForChallenge(win, maxPolls) {
  return new Promise((resolve, reject) => {
    const to = setTimeout(() => { cleanup(); reject(new Error('timeout loading page')); }, 25000);
    // dom-ready, not did-finish-load: the site renders every sound tile server-side, so the full
    // list is in the DOM as soon as the HTML is parsed (~1.5s), while did-finish-load also waits
    // for ~100 ad/tracker requests (~6.5s on a cold start). Measured on every page type the app
    // reads: identical sound counts either way. The read has to go through mainFrame:
    // webContents.executeJavaScript itself holds off until the page has finished loading.
    function onReady() { cleanup(); resolve(); }
    function onFail(_e, code, desc, _url, isMainFrame) {
      if (!isMainFrame || code === -3) return; // -3 is a cancelled load, e.g. a mid-page redirect
      cleanup(); reject(new Error(`${desc} (${code}) from myinstants.com`));
    }
    function cleanup() {
      clearTimeout(to);
      win.webContents.removeListener('dom-ready', onReady);
      win.webContents.removeListener('did-fail-load', onFail);
    }
    win.webContents.once('dom-ready', onReady);
    win.webContents.on('did-fail-load', onFail);
  }).then(async () => {
    // Give an automatic bot-check time to finish and redirect to the real page, if one is showing.
    for (let i = 0; i < maxPolls * 4; i++) {
      // the frame can be swapped out mid-redirect, so look it up fresh and retry if it's gone
      const html = await win.webContents.mainFrame.executeJavaScript('document.documentElement.outerHTML').catch(() => '');
      if (html && !isChallenge(html)) return html;
      await new Promise((r) => setTimeout(r, 250));
    }
    // Still a block/challenge page after waiting — surface that as an error rather than silently
    // handing back a page with no real content (which parses as "this page has no sounds"). Prefixed
    // so callers can tell "Cloudflare challenge" apart from a real network failure above.
    throw new Error('challenge: still showing a verification page after waiting');
  });
}

let visibleWin = null;
function getVisibleWindow() {
  if (!visibleWin || visibleWin.isDestroyed()) {
    visibleWin = new BrowserWindow({
      width: 480, height: 640, show: false,
      title: 'Verifying… (myinstants.com)',
      webPreferences: { partition: 'persist:myinstants-read', backgroundThrottling: false },
    });
  }
  return visibleWin;
}

// Rarely needed now that the hidden window sends Electron's own honest UA (see above), but kept as
// a fallback: open a real, visible window on the same partition and let the challenge resolve there
// (usually automatic within a few seconds, no click needed — but if Cloudflare shows an interactive
// checkbox instead, the window is left open so you can click it yourself). Once resolved, the
// clearance cookie lives in the shared partition, so the hidden window benefits too.
async function solveChallengeVisibly(p) {
  const win = getVisibleWindow();
  load(win, BASE + p);
  win.show();
  try {
    await waitForChallenge(win, 30);
    win.hide();
    return true;
  } catch {
    return false; // left visible on purpose — may need a manual click
  }
}

let queue = Promise.resolve();
function withQueue(fn) {
  const run = queue.then(fn, fn);
  queue = run.catch(() => {}); // keep the chain alive even after one call fails
  return run;
}

// Pages loaded in the last few minutes are reused instead of asking the site again: fewer requests,
// less chance of tripping its bot protection. Any change made through the app (upload, delete,
// favorite, sign in/out) clears it all, so lists never show a state from before that change.
const PAGE_TTL = 5 * 60 * 1000;
const pageCache = new Map();
const clearPageCache = () => pageCache.clear();
let lastSessionId;

function getHtml(p) {
  // Paths come from page markup, so only allow site-relative /en/ paths.
  if (!/^\/en\/[^/]/.test(p)) return Promise.reject(new Error('bad path'));
  const hit = pageCache.get(p);
  if (hit && Date.now() - hit.at < PAGE_TTL) return Promise.resolve(hit.html);
  return fetchHtml(p).then((html) => {
    for (const [k, v] of pageCache) if (Date.now() - v.at >= PAGE_TTL) pageCache.delete(k);
    pageCache.set(p, { html, at: Date.now() });
    return html;
  });
}

function fetchHtml(p) {
  // The site's edge cache serves stale copies (e.g. Uploaded missing a fresh upload) and ignores
  // no-cache request headers; only a unique URL gets a fresh page.
  p += (p.includes('?') ? '&' : '?') + '_=' + Date.now();
  return withQueue(async () => {
    const win = getHiddenWindow();
    load(win, BASE + p);
    try {
      return await waitForChallenge(win, 8);
    } catch (e) {
      if (!e.message.startsWith('challenge:')) throw e; // a real network failure, not a Cloudflare block — a visible window won't fix that
    }
    if (await solveChallengeVisibly(p)) {
      load(win, BASE + p);
      try { return await waitForChallenge(win, 8); } catch {}
    }
    throw new Error('blocked by myinstants.com (verification page)');
  });
}

const toTile = (s) => ({ name: s.name, url: BASE + s.path, page: s.page, color: s.color, id: s.id });
const withPage = (p, n) => (n > 1 ? p + (p.includes('?') ? '&' : '?') + 'page=' + n : p);

// Search used to go through Myinstants' public JSON API instead of scraping /en/search/ like every
// other list — it looked more stable, but that endpoint doesn't return a sound's numeric id, so
// nothing found via search could ever be favorited. /en/search/?name=X turns out to render the exact
// same tile markup (and real favorite(id) buttons) as every other list page, confirmed live, so
// 'sounds' below already handles it — no separate endpoint needed.
ipcMain.handle('sounds', async (_e, { path: p, page }) => {
  const tries = p === '/en/index/il/' ? [p, '/en/index/us/'] : [p];
  let html;
  for (const t of tries) {
    html = await getHtml(withPage(t, page || 1));
    const sounds = parseSounds(html);
    if (sounds.length) return { sounds: sounds.map(toTile), pager: parsePager(html) };
  }
  return { sounds: [], pager: parsePager(html) };
});

ipcMain.handle('profile', async (_e, soundPage) => {
  if (!/^\/en\/instant\/[^/]/.test(soundPage)) throw new Error('bad path');
  return parseProfile(await getHtml(soundPage)) || null;
});

ipcMain.handle('instant', async (_e, soundPage) => {
  if (!/^\/en\/instant\/[^/]/.test(soundPage)) throw new Error('bad path');
  const s = parseInstant(await getHtml(soundPage));
  if (!s) return null;
  return { ...s, url: s.path && BASE + s.path, related: s.related.map(toTile) };
});

// Adding and removing a favorite are two unrelated endpoints on the real site, not a symmetric
// pair — confirmed straight from its own markup/JS, not guessed:
//   add:    GET /api/v1/favorite/add/<id>/   (from the shipped `favorite(instant_id)` JS function)
//   remove: GET /remove/<id>/                (from the Favorites page's own button: a plain
//                                              `onclick="location.href='/remove/<id>/'"`, not an
//                                              /api/v1/ call, no JS function wrapping it at all)
// Both 200 once signed in, 401 (or in remove's case, just not succeed) otherwise. They need to run
// from a page already on myinstants.com so the request is same-origin and carries the session
// cookie automatically; the hidden window usually already is, from ordinary browsing.
// One status line per account action, in debug.log in the app's userData folder. Never page
// bodies: those carry CSRF tokens.
const DEBUG_LOG = path.join(app.getPath('userData'), 'debug.log');
function debugLog(msg) { try { fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`); } catch {} }

// Account actions run as scripts inside the hidden window so they're same-origin requests carrying
// the session cookie; this makes sure that window is actually on myinstants.com first.
async function ensureOnSite(win, p) {
  if (win.webContents.getURL().startsWith(BASE)) return;
  load(win, BASE + p);
  try { await waitForChallenge(win, 8); } catch {}
}

// In-page expression for the csrftoken Django will check. The site sets two 'csrftoken' cookies
// (domain-scoped and host-only) with different values; Django keeps whichever parses last, so take
// the last match — see submit-upload for the full story.
const CSRF_JS = `(() => { const m = [...document.cookie.matchAll(/(?:^|; )csrftoken=([^;]+)/g)]; return m.length ? m[m.length - 1][1] : null; })()`;

const signedOut = (status, finalUrl) => status === 401 || String(finalUrl).includes('/accounts/login');

function favAction(url, id) {
  if (!/^\d+$/.test(String(id))) return Promise.reject(new Error('bad id'));
  return withQueue(async () => {
    const win = getHiddenWindow();
    await ensureOnSite(win, '/en/index/il/');
    const { status, finalUrl } = await win.webContents.executeJavaScript(
      `fetch('${url}').then((r) => ({ status: r.status, finalUrl: r.url }))`
    );
    debugLog(`favAction ${url} — status: ${status} finalUrl: ${finalUrl}`);
    // /remove/<id>/ is a plain page, not the API: signed out it redirects to the login page with a
    // 200 instead of answering 401, so the final URL is checked too.
    if (signedOut(status, finalUrl)) throw new Error('sign in on myinstants.com first');
    if (status !== 200) throw new Error(`myinstants.com returned ${status}`);
    clearPageCache();
    return true;
  });
}
ipcMain.handle('favorite', (_e, id) => favAction(`/api/v1/favorite/add/${id}/`, id));
ipcMain.handle('unfavorite', (_e, id) => favAction(`/remove/${id}/`, id));

// Mirrors the delete button on the owner-only /en/uploaded/ page: each tile there is a
// <form method=POST action=/delete/<id>/> holding only csrfmiddlewaretoken. Permanent.
// The token comes from document.cookie for the same duplicate-cookie reason as submit-upload.
ipcMain.handle('delete-sound', (_e, id) => {
  if (!/^\d+$/.test(String(id))) return Promise.reject(new Error('bad id'));
  return withQueue(async () => {
    const win = getHiddenWindow();
    await ensureOnSite(win, '/en/uploaded/');
    const { status, finalUrl } = await win.webContents.executeJavaScript(`(async () => {
      const fd = new FormData();
      fd.append('csrfmiddlewaretoken', ${CSRF_JS} || '');
      const r = await fetch('/delete/${id}/', { method: 'POST', body: fd, credentials: 'include' });
      return { status: r.status, finalUrl: r.url };
    })()`);
    debugLog(`delete-sound ${id} — status: ${status} finalUrl: ${finalUrl}`);
    if (signedOut(status, finalUrl)) throw new Error('sign in on myinstants.com first');
    if (status !== 200) throw new Error(`myinstants.com returned ${status}`);
    clearPageCache();
    return true;
  });
});

// Submits the real upload form directly — not by embedding the real /en/new/ page (that one's full
// of ads and ran into the <webview>/BrowserView dropdown-positioning bug on its own Category <select>
// below), but by POSTing the exact same fields the real form does, read straight off its live markup:
// method POST, enctype multipart/form-data, action /en/new/, fields csrfmiddlewaretoken + name +
// sound (file) + image (file, optional) + color (hex, no '#') + category (numeric id) + description
// + tags + accept_terms. ses.fetch() (not the plain global fetch used elsewhere) is what lets this
// run from the main process while still using the signed-in partition's cookies — plain fetch only
// ever uses the default session. The csrfmiddlewaretoken field plus the browser's own Referer header
// (which ses.fetch sends automatically for a same-origin-styled request like this) is what a real
// <form> submission relies on for Django's CSRF check; unlike a <webview>'s own in-page form submit,
// this never produces the Origin: null that check rejects, because it's not a guest-view navigation.
ipcMain.handle('submit-upload', async (_e, { name, soundPath, imagePath, color, category, description, tags, acceptTerms }) => {
  if (!acceptTerms) throw new Error('accept the terms of use first');
  if (!name || !soundPath || !category) throw new Error('name, sound file and category are required');
  const ses = session.fromPartition('persist:myinstants-read');
  const anyCsrf = await ses.cookies.get({ name: 'csrftoken' });
  if (!anyCsrf.length) throw new Error('sign in on myinstants.com first');

  // ses.fetch() from the main process was getting a plain 403 here even while signed in — it
  // doesn't carry the same fingerprint/headers as a request made from inside the hidden window,
  // which is what actually cleared Cloudflare for this session. Same fix as favAction: run the
  // fetch as a script inside that already-cleared window instead, so it looks identical to a real
  // in-page form submit. Files go in as base64 since executeJavaScript can only pass JSON-able data.
  // The csrftoken is read from document.cookie INSIDE the page, not from ses.cookies.get() here —
  // myinstants.com sets two different 'csrftoken' cookies (one scoped to .www.myinstants.com, one
  // host-only to www.myinstants.com) with different values at the same time. ses.cookies.get() picks
  // one arbitrarily, which can disagree with the one Django actually resolves from the Cookie header
  // it receives (duplicate cookie names: the server keeps whichever one parses last), causing a
  // guaranteed-looking-like-CSRF 403 on every submit regardless of credentials. Reading document.cookie
  // at POST time and taking the last 'csrftoken=' match mirrors how Django's own cookie parser
  // resolves the duplicate, so the token we submit always matches what the server checks against.
  // Prepared before joining the queue: up to five ffmpeg passes shouldn't hold up page loads.
  const soundB64 = (await prepareSound(soundPath)).toString('base64');
  const imageB64 = imagePath ? fs.readFileSync(imagePath).toString('base64') : null;
  return withQueue(async () => {
    const win = getHiddenWindow();
    const beforeUrl = win.webContents.getURL();
    await ensureOnSite(win, '/en/index/il/');
    const script = `(async () => {
      try {
        function toBlob(b64) {
          const bin = atob(b64);
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          return new Blob([bytes]);
        }
        const csrfValue = ${CSRF_JS};
        if (!csrfValue) return { scriptError: 'no csrftoken cookie visible to document.cookie' };

        const fd = new FormData();
        fd.append('csrfmiddlewaretoken', csrfValue);
        fd.append('name', ${JSON.stringify(name)});
        fd.append('color', ${JSON.stringify(color)});
        fd.append('category', ${JSON.stringify(category)});
        fd.append('description', ${JSON.stringify(description || '')});
        fd.append('tags', ${JSON.stringify(tags || '')});
        fd.append('accept_terms', 'on');
        fd.append('sound', toBlob(${JSON.stringify(soundB64)}), ${JSON.stringify(path.parse(soundPath).name + '.mp3')});
        ${imageB64 ? `fd.append('image', toBlob(${JSON.stringify(imageB64)}), ${JSON.stringify(path.basename(imagePath))});` : ''}
        const r = await fetch('/en/new/', { method: 'POST', body: fd, credentials: 'include' });
        const text = await r.text();
        // On a re-rendered form (validation error), surface the real reason instead of a generic
        // message — e.g. myinstants.com rejects any sound file over 300KB.
        const errMatch = text.match(/<ul class="errorlist"(?: id="id_(\\w+)_error")?[^>]*><li>([^<]*)<\\/li>/);
        return { status: r.status, finalUrl: r.url, fieldError: errMatch && (errMatch[1] ? errMatch[1] + ': ' : '') + errMatch[2] };
      } catch (e) {
        return { scriptError: (e && e.stack) || String(e) };
      }
    })()`;
    const { status, finalUrl, fieldError, scriptError } = await win.webContents.executeJavaScript(script);
    if (scriptError) {
      debugLog(`submit-upload — window was on: ${beforeUrl || '(blank)'} — threw inside page: ${scriptError}`);
      throw new Error(`upload script failed: ${scriptError}`);
    }
    debugLog(`submit-upload — window was on: ${beforeUrl || '(blank)'} — status: ${status} finalUrl: ${finalUrl} fieldError: ${fieldError}`);
    if (signedOut(status, finalUrl)) throw new Error('sign in on myinstants.com first');
    if (status !== 200) throw new Error(`myinstants.com returned ${status}`);
    // Success redirects away from the form (to /en/uploaded/); staying on /en/new/ means the form
    // was re-rendered with validation errors instead (Django's usual pattern for a rejected POST).
    if (finalUrl.includes('/en/new/')) throw new Error(fieldError || 'myinstants.com rejected the submission — check the required fields');
    clearPageCache();
    return true;
  });
});

// Whether the shared session is actually signed in — a sessionid cookie is Django's own marker for
// that, so its presence is a good-enough signal without having to fetch and scrape a whole page for
// it. The renderer checks this on launch and again every time it leaves the in-app Login/Settings/
// Logout page, which is what makes the header "sync" after you sign in there.
ipcMain.handle('auth-status', async () => {
  const cookies = await session.fromPartition('persist:myinstants-read').cookies.get({ name: 'sessionid' });
  const sid = cookies.length ? cookies[0].value : null;
  if (sid !== lastSessionId) { lastSessionId = sid; clearPageCache(); } // signed in/out or switched account
  return cookies.length > 0;
});

// Login, Upload, Settings and Logout all used to kick out to the system browser because sign-in
// (Google/Facebook OAuth, the site's own CSRF check) was assumed not to survive Electron's embedded
// window — but that assumption was resting on the same spoofed-UA bug that broke Cloudflare above
// (a fake UA also gets Google's sign-in rejected at /v3/signin/rejected; see stablyai/orca#18749).
// Now that the UA is honest, all four render right inside the main window instead of a separate
// window or the system browser — see the BrowserView block below. Crucially they share the
// hidden/visible scraping windows' own partition, so logging in there actually signs in the session
// everything else already reads from; a separate external browser would have its own, unrelated
// cookies.
//
// What's left here is purely the fallback when a page fetch gets 403'd by the site's bot protection:
// a real browser (outside the app) can pass that check when a failed in-app scrape couldn't.
ipcMain.handle('open', (_e, what) => {
  if (typeof what === 'string' && /^\/en\/[^/]/.test(what)) return shell.openExternal(BASE + what);
  throw new Error('bad page');
});

// A real myinstants.com page (login, upload, settings, logout) shown inside the main window via
// BrowserView — a full top-level WebContents Electron positions over part of the window, not the
// <webview> tag this used to be. <webview> is a "guest view" with two real, confirmed problems for
// this exact use: it sends Origin: null on same-page form POSTs, which Django's CSRF protection
// always rejects (broke the login form outright), and native form controls like <select> can render
// their dropdown popup as a broken full-size overlay inside it (broke the upload form's category
// picker). BrowserView has neither issue — it behaves like any other window. (Electron's own docs
// now recommend avoiding <webview> for this reason.)
const HEADER_HEIGHT = 61; // matches `header { height: 61px }` in index.html
let mainWin = null;
let siteView = null;
function getSiteView() {
  if (!siteView) {
    siteView = new BrowserView({ webPreferences: { partition: 'persist:myinstants-read' } });
    // Brings its own full header, which would stack under this app's header — hidden on every
    // navigation so this app's own header stays the single, consistent one across every view.
    siteView.webContents.on('dom-ready', async () => {
      await siteView.webContents.insertCSS('nav.navbar { display: none !important; }');
      layoutSiteView(); // only reveals (see hide-to-0x0 below) once the hiding CSS has actually run
    });
  }
  return siteView;
}
function layoutSiteView() {
  if (!siteView || !mainWin) return;
  const [w, h] = mainWin.getContentSize();
  siteView.setBounds({ x: 0, y: HEADER_HEIGHT, width: w, height: h - HEADER_HEIGHT });
}
ipcMain.handle('show-site-page', (_e, p) => {
  // Same partition as the signed-in session, so only plain site paths (/en/..., /accounts/...).
  if (typeof p !== 'string' || !/^\/(?:en|accounts)\/[\w\/.-]*$/.test(p)) throw new Error('bad page');
  const view = getSiteView();
  mainWin.setBrowserView(view);
  view.setBounds({ x: 0, y: HEADER_HEIGHT, width: 0, height: 0 }); // 0x0 until dom-ready hides the real header
  load(view.webContents, BASE + p);
});
ipcMain.handle('hide-site-page', () => {
  if (mainWin) mainWin.setBrowserView(null);
});

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 1100, height: 760, minWidth: 920, minHeight: 400,
    backgroundColor: '#15202b',
    titleBarStyle: 'hiddenInset',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  mainWin = win;
  win.on('resize', layoutSiteView);
  // The hidden scraping window would otherwise keep the app alive with no window to show.
  win.on('closed', () => app.quit());
  win.loadFile('index.html');
});

app.on('window-all-closed', () => app.quit());

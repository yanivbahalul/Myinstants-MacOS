// shortcut: scrapes myinstants.com markup with regexes, breaks if the site changes its HTML; upgrade to a real parser or their API then.
const decode = (s) => s.replace(/&amp;/g, '&').replace(/&#0?39;|&#x27;/g, "'")
  .replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').trim();

const PLAY = /play\(\s*'([^']+\.mp3[^']*)'/;
const NAME = /class="instant-link[^"]*"[^>]*>([^<]+)</;
const PAGE = /href="(\/en\/instant\/[^"]+)"/;
const COLOR = /background-color:\s*(#[0-9a-fA-F]{3,8})/;
// Every tile's own favorite-toggling button carries the sound's numeric id, but which pattern
// depends on the page: everywhere EXCEPT the Favorites page it's an "add" button calling
// favorite('<id>') (what /api/v1/favorite/add/<id>/ expects); on the Favorites page specifically
// (where everything shown is already favorited) it's a "remove" button instead, a plain
// onclick="location.href='/remove/<id>/'" with no JS function at all — confirmed by inspecting
// both live, not guessed. Try both; exactly one will match per page.
const FAV_ID = /onclick="favorite\('?(\d+)'?\)"/;
const REMOVE_ID = /onclick="location\.href='\/remove\/(\d+)\/';"/;
// The owner-only /en/uploaded/ page has no favorite button; its tiles are each wrapped in a
// <form action="/delete/<id>/"> carrying the same numeric id instead.
const DELETE_ID = /action="\/delete\/(\d+)\/"/;
const favId = (s) => (s.match(FAV_ID) || s.match(REMOVE_ID) || s.match(DELETE_ID) || [])[1];

function parseSounds(html) {
  const out = [];
  const seen = new Set();
  const add = (path, name, page, color, id) => {
    if (!seen.has(path)) { seen.add(path); out.push({ name: decode(name), path, ...(page && { page }), ...(color && { color }), ...(id && { id }) }); }
  };
  // Preferred: one chunk per sound tile, so button/link order doesn't matter.
  for (const chunk of html.split(/<div[^>]*class="instant[ "][^>]*>/).slice(1)) {
    const p = chunk.match(PLAY), n = chunk.match(NAME);
    if (p && n) add(p[1], n[1], (chunk.match(PAGE) || [])[1], (chunk.match(COLOR) || [])[1], favId(chunk));
  }
  if (out.length) return out;
  // Fallback: pair each play() with the next link after it.
  const hits = [...html.matchAll(new RegExp(PLAY, 'g'))];
  hits.forEach((m, i) => {
    const seg = html.slice(m.index, i + 1 < hits.length ? hits[i + 1].index : html.length);
    const n = seg.match(NAME);
    if (n) add(m[1], n[1], (seg.match(PAGE) || [])[1], undefined, favId(seg));
  });
  return out;
}

// The uploader's profile name from a sound's own page.
// The uploader link on a sound page often continues as .../uploaded/" rather than stopping
// right after the name, so match the name and allow anything after it up to the closing quote.
const parseProfile = (html) => (html.match(/href="\/en\/profile\/([^\/"?]+)\/?[^"]*"/) || [])[1];

const TITLE = /<h1[^>]*>([^<]+)<\/h1>/;
const FAVS = /<b>\s*([\d,]+)\s*users?\s*<\/b>\s*favorited this sound button/i;
const UPLOADER = /Uploaded by\s*<a[^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>\s*-\s*([\d,]+)\s*views/i;
const HERO_COLOR = /<div[^>]*class="circle[^"]*"[^>]*style="background-color:\s*(#[0-9a-fA-F]{3,8})/;
const HERO_PLAY = /class="large-button"[^>]*onclick="play\(\s*'([^']+\.mp3[^']*)'/;

// A single sound's own page: title, favourite count, uploader, view count, and the "you might also like" strip.
function parseInstant(html) {
  const title = (html.match(TITLE) || [])[1];
  if (!title) return null;
  const favs = (html.match(FAVS) || [])[1];
  const up = html.match(UPLOADER);
  const color = (html.match(HERO_COLOR) || [])[1];
  const audioPath = (html.match(HERO_PLAY) || [])[1];
  return {
    name: decode(title),
    favorites: favs,
    views: up && up[3],
    // Keep the href as-is: it already points at .../uploaded/, the uploader's own sounds.
    // /en/profile/<name>/ (no suffix) is that person's *favorites* tab on myinstants.com, not
    // their uploads — stripping the suffix here used to send "see their profile" to the wrong tab.
    uploader: up && { name: decode(up[2]), path: up[1] },
    color,
    path: audioPath,
    related: parseSounds(html),
  };
}

module.exports = { parseSounds, parseProfile, parseInstant };

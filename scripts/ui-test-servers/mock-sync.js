// Stand-in for the CineFlix Sync server, used by the UI tests (kids profiles, PINs, ratings, episodes, Continue Watching).
// It follows the real server's contract (see cineflix-sync/src/profiles.js and sync.js) and keeps everything in memory.
// Extra /_test/* endpoints let a test reset it, create profiles, seed items and read back what the app pushed.
//
//   node scripts/ui-test-servers/mock-sync.js [port]      (default 8150)
const http = require('http');
const crypto = require('crypto');

const PORT = Number(process.argv[2] || process.env.PORT || 8150);
const RATINGS = ['G', 'PG', 'PG-13', 'R'];
const DEFAULT_AVATARS = ['fox', 'cat', 'panda', 'owl', 'robot', 'astronaut'];

let accounts, sessions, attempts;
function reset() { accounts = new Map(); sessions = new Map(); attempts = new Map(); }
reset();

class Fail extends Error { constructor(status, code, message) { super(message); this.status = status; this.code = code; } }
const id24 = () => crypto.randomBytes(12).toString('hex');

function view(p) {
  return { id: p.id, name: p.name, color: p.color, avatar: p.avatar, kids: !!p.kids, maxRating: p.maxRating || null, hasPin: !!p.pin, position: p.position };
}

function newProfile(acc, f) {
  const kids = !!f.kids;
  let maxRating = null;
  if (kids) {
    maxRating = f.maxRating === undefined || f.maxRating === null ? 'PG' : f.maxRating;
    if (!RATINGS.includes(maxRating)) throw new Fail(400, 'invalid_maxRating', 'maxRating must be one of ' + RATINGS.join(', '));
  }
  if (f.pin !== undefined && f.pin !== null && !/^\d{4,6}$/.test(f.pin)) throw new Fail(400, 'invalid_pin', 'PIN must be 4 to 6 digits');
  const position = acc.profiles.length;
  const p = {
    id: id24(), name: String(f.name || 'Me').slice(0, 24), color: f.color || '#3e63dd', avatar: f.avatar || DEFAULT_AVATARS[position % 6],
    kids, maxRating, pin: f.pin || null, position, rev: 0, items: new Map()
  };
  acc.profiles.push(p);
  return p;
}

function hit(key, limit, windowMs, message) {
  const t = Date.now();
  let a = attempts.get(key);
  if (!a || a.reset <= t) a = { count: 0, reset: t + windowMs };
  a.count += 1;
  attempts.set(key, a);
  if (a.count > limit) throw new Fail(429, 'rate_limited', message + ' Try again in ' + Math.ceil((a.reset - t) / 60000) + ' min.');
}

function checkPin(p, pin) {
  hit('pin:' + p.id, 5, 600000, 'Too many wrong PINs.');
  if (typeof pin !== 'string' || pin !== p.pin) throw new Fail(403, 'bad_pin', 'That PIN is not right');
  attempts.delete('pin:' + p.id);
}

function auth(req) {
  const t = (req.headers.authorization || '').replace(/^Bearer /, '');
  const s = sessions.get(t);
  if (!s) throw new Fail(401, 'unauthorized', 'Sign in again');
  return accounts.get(s);
}

function owned(acc, id) {
  const p = acc.profiles.find((x) => x.id === id);
  if (!p) throw new Fail(404, 'not_found', 'No such profile');
  return p;
}

function session(acc) { const t = crypto.randomBytes(24).toString('hex'); sessions.set(t, acc.email); return t; }

function applyChange(p, c, now) {
  const kinds = ['list', 'progress', 'watched', 'episode', 'prefs', 'video', 'rating'];
  if (!kinds.includes(c.kind)) throw new Fail(400, 'invalid_kind', 'kind must be one of ' + kinds.join(', '));
  if (typeof c.key !== 'string' || !/^[A-Za-z0-9:._-]{1,64}$/.test(c.key)) throw new Fail(400, 'invalid_key', 'bad key');
  const deleted = !!c.deleted;
  const value = deleted ? null : (c.value === undefined ? null : c.value);
  if (!deleted && JSON.stringify(value).length > 2048) throw new Fail(413, 'value_too_large', 'A value can be up to 2048 bytes');
  let updatedAt = Number(c.updatedAt);
  if (!Number.isFinite(updatedAt) || updatedAt <= 0) updatedAt = now;
  updatedAt = Math.min(Math.floor(updatedAt), now + 300000);
  const k = c.kind + '/' + c.key;
  const old = p.items.get(k);
  if (old && updatedAt < old.updatedAt) return false;
  p.rev += 1;
  p.items.set(k, { kind: c.kind, key: c.key, value, updatedAt, deleted, rev: p.rev });
  return true;
}

async function route(req, url, body) {
  const m = req.method, path = url.pathname.replace(/\/+$/, '') || '/';
  let r;

  // Test helpers
  if (path === '/_test/reset') { reset(); return [200, { ok: true }]; }
  // Creates an account that accepts any password, with the given profiles (name, kids, maxRating, pin), so a test can sign in
  // with everything in place. Returns the profile ids by name.
  if (path === '/_test/account' && m === 'POST') {
    const email = String(body.email).toLowerCase();
    const acc = { id: id24(), email, key: null, profiles: [] };
    accounts.set(email, acc);
    const ids = {};
    (body.profiles || [{ name: 'Me' }]).forEach((f) => { ids[f.name] = newProfile(acc, f).id; });
    return [200, ids];
  }
  if (path === '/_test/profile' && m === 'POST') {
    const acc = accounts.get(body.email);
    if (!acc) throw new Fail(404, 'not_found', 'no such account');
    return [200, view(newProfile(acc, body))];
  }
  if (path === '/_test/seed' && m === 'POST') {
    const p = owned(accounts.get(body.email) || { profiles: [] }, body.profileId);
    const now = Date.now();
    (body.changes || []).forEach((c) => applyChange(p, c, now));
    return [200, { rev: p.rev }];
  }
  if (path === '/_test/state' && m === 'GET') {
    const acc = accounts.get(url.searchParams.get('email'));
    if (!acc) return [200, { profiles: [] }];
    return [200, { profiles: acc.profiles.map((p) => ({ ...view(p), items: [...p.items.values()] })) }];
  }

  if (m === 'POST' && path === '/v1/auth/register') {
    const email = String(body.email || '').toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Fail(400, 'invalid_email', 'That email address does not look right');
    if (accounts.has(email)) throw new Fail(409, 'email_taken', 'An account with this email already exists');
    const acc = { id: id24(), email, key: body.key, profiles: [] };
    accounts.set(email, acc);
    const profile = newProfile(acc, { name: email.split('@')[0] });
    return [201, { token: session(acc), account: { id: acc.id, email }, profile: view(profile) }];
  }
  if (m === 'POST' && path === '/v1/auth/login') {
    const acc = accounts.get(String(body.email || '').toLowerCase());
    if (!acc || (acc.key !== null && acc.key !== body.key)) throw new Fail(401, 'bad_credentials', 'Email or password is not right');
    return [200, { token: session(acc), account: { id: acc.id, email: acc.email } }];
  }
  if (!path.startsWith('/v1/')) throw new Fail(404, 'not_found', 'Not found');

  const acc = auth(req);
  if (m === 'POST' && path === '/v1/auth/logout') {
    const t = (req.headers.authorization || '').replace(/^Bearer /, '');
    sessions.delete(t);
    return [200, { ok: true }];
  }
  if (m === 'GET' && path === '/v1/profiles') return [200, { profiles: acc.profiles.map(view), max: 5 }];
  if (m === 'POST' && path === '/v1/profiles') {
    if (acc.profiles.length >= 5) throw new Fail(409, 'too_many_profiles', 'An account can have up to 5 profiles');
    return [201, view(newProfile(acc, body))];
  }
  if ((r = path.match(/^\/v1\/profiles\/([0-9a-f]{24})$/))) {
    const p = owned(acc, r[1]);
    if (m === 'PATCH') {
      if (body.name !== undefined) p.name = String(body.name).slice(0, 24);
      if (body.color !== undefined) p.color = body.color;
      if (body.avatar !== undefined) p.avatar = body.avatar;
      if (body.kids !== undefined) p.kids = !!body.kids;
      if (body.maxRating !== undefined) {
        if (body.maxRating !== null && !RATINGS.includes(body.maxRating)) throw new Fail(400, 'invalid_maxRating', 'bad rating');
        p.maxRating = body.maxRating;
      }
      if (!p.kids) p.maxRating = null; else if (!p.maxRating) p.maxRating = 'PG';
      if (body.pin === null) { if (p.pin) checkPin(p, body.currentPin); p.pin = null; }
      else if (body.pin !== undefined) {
        if (!/^\d{4,6}$/.test(body.pin)) throw new Fail(400, 'invalid_pin', 'PIN must be 4 to 6 digits');
        if (p.pin) checkPin(p, body.currentPin);
        p.pin = body.pin;
      }
      return [200, view(p)];
    }
    if (m === 'DELETE') {
      if (acc.profiles.length <= 1) throw new Fail(409, 'last_profile', 'You cannot delete your only profile');
      if (p.pin) checkPin(p, body.pin);
      acc.profiles = acc.profiles.filter((x) => x !== p);
      return [200, { ok: true }];
    }
  }
  if (m === 'POST' && (r = path.match(/^\/v1\/profiles\/([0-9a-f]{24})\/verify-pin$/))) {
    const p = owned(acc, r[1]);
    if (p.pin) checkPin(p, body.pin);
    return [200, { ok: true }];
  }
  if ((r = path.match(/^\/v1\/profiles\/([0-9a-f]{24})\/sync$/))) {
    const p = owned(acc, r[1]);
    if (m === 'GET') {
      const since = Number(url.searchParams.get('since')) || 0;
      const rows = [...p.items.values()].filter((i) => i.rev > since).sort((a, b) => a.rev - b.rev);
      const page = rows.slice(0, 500);
      return [200, { rev: page.length ? page[page.length - 1].rev : p.rev, more: rows.length > 500, changes: page.map((i) => ({ kind: i.kind, key: i.key, value: i.value, updatedAt: i.updatedAt, deleted: i.deleted, rev: i.rev })) }];
    }
    if (m === 'POST') {
      if (!Array.isArray(body.changes)) throw new Fail(400, 'invalid_changes', 'changes must be a list');
      const now = Date.now();
      const stale = [];
      body.changes.forEach((c) => { if (!applyChange(p, c, now)) stale.push(c.kind + '/' + c.key); });
      return [200, { rev: p.rev, applied: body.changes.length - stale.length, stale }];
    }
  }
  throw new Fail(404, 'not_found', 'Not found');
}

http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    let status = 200, out;
    try {
      const text = Buffer.concat(chunks).toString();
      [status, out] = await route(req, new URL(req.url, 'http://x'), text ? JSON.parse(text) : {});
    } catch (e) {
      if (e instanceof Fail) { status = e.status; out = { error: { code: e.code, message: e.message } }; }
      else { status = 500; out = { error: { code: 'internal', message: String(e) } }; }
    }
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(out));
  });
}).listen(PORT, '127.0.0.1', () => console.log('mock-sync on ' + PORT));

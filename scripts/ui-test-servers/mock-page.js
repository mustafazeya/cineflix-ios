// A stand-in for a media server's HTML player page, used by the UI tests of "Play natively".
//
// The page plays its video through a blob: address, like hls.js / MediaSource pages do, so the video element never shows the real
// stream URL. The tests check that the app still finds that URL and can hand it to the native player.
//
//   node scripts/ui-test-servers/mock-page.js <video.mp4> [port]      (default 8161)
//
//   /page?via=mp4     fetch('/media/clip.mp4') -> Blob -> video.src = blob:...                (a progressive file; native playback works)
//   /page?via=xhr     the same with XMLHttpRequest
//   /page?via=hls     fetch master.m3u8 and both quality playlists, then play a blob (the "segments" are not real, native playback fails)
//   /page?via=hlsjs   like hls, but through a fake window.Hls defined late, with loadSource(url)
//   /page?via=src     video.src = '/media/clip.mp4' set directly, and a <source> element
//
// The stream and the playlists only answer a request that carries the page's Referer and its cookie, so the native player has to pass
// both. Requests for media are recorded: GET /_test/log, POST /_test/clear.
const http = require('http');
const fs = require('fs');
const file = process.argv[2];
const port = Number(process.argv[3] || 8161);
if (!file) { console.error('usage: mock-page.js <video.mp4> [port]'); process.exit(1); }
const size = fs.statSync(file).size;
let log = [];

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:#000;color:#bbb;font:14px -apple-system,sans-serif}video{width:100%;display:block}</style></head>
<body><video id="v" playsinline autoplay muted></video><p id="s">loading</p>
<script>
var via = new URLSearchParams(location.search).get('via') || 'mp4';
var v = document.getElementById('v');
function status(t) { document.getElementById('s').textContent = t; }
function get(url, type) {
  return new Promise(function (ok, bad) {
    var x = new XMLHttpRequest(); x.open('GET', url); x.responseType = type;
    x.onload = function () { x.status < 300 ? ok(x.response) : bad(x.status); }; x.onerror = bad; x.send();
  });
}
function playBlob(blob) { v.src = URL.createObjectURL(new Blob([blob], { type: 'video/mp4' })); v.play().catch(function () {}); status('playing ' + v.src.slice(0, 5)); }
function text(url) { return via === 'xhr' ? get(url, 'text') : fetch(url).then(function (r) { return r.text(); }); }
function bytes(url) { return via === 'xhr' ? get(url, 'blob') : fetch(url).then(function (r) { return r.blob(); }); }
function playlists(master) {
  return text(master).then(function (t) {
    var rel = t.split('\\n').filter(function (l) { return l && l[0] !== '#'; });
    return Promise.all(rel.map(function (r) { return text(new URL(r, new URL(master, location.href)).href); }));
  });
}
if (via === 'mp4' || via === 'xhr') bytes('/media/clip.mp4').then(playBlob);
else if (via === 'hls') playlists('/hls/master.m3u8').then(function () { return bytes('/media/clip.dat'); }).then(playBlob);
else if (via === 'hlsjs') setTimeout(function () {
  window.Hls = function () {};
  window.Hls.prototype.attachMedia = function () {};
  window.Hls.prototype.loadSource = function (u) { playlists(u).then(function () { return bytes('/media/clip.dat'); }).then(playBlob); };
  var h = new window.Hls(); h.attachMedia(v); h.loadSource('/hls/master.m3u8');
}, 300);
else if (via === 'src') { v.src = '/media/clip.mp4'; var s = document.createElement('source'); s.src = '/media/clip.mp4'; v.appendChild(s); status('src set'); }
</script></body></html>`;

const MASTER = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nv360.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\nv720.m3u8\n';
const VARIANT = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:6.0,\nseg0.ts\n#EXTINF:6.0,\nseg1.ts\n#EXT-X-ENDLIST\n';

function allowed(req) {
  return (req.headers.referer || '').startsWith(`http://127.0.0.1:${port}/page`) && /(^|; )sid=test(;|$)/.test(req.headers.cookie || '');
}

http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  const path = url.pathname;
  if (path === '/_test/log') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify(log)); }
  if (path === '/_test/clear') { log = []; res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{}'); }
  if (path === '/page') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'set-cookie': 'sid=test; Path=/' });
    return res.end(PAGE);
  }
  if (path.startsWith('/media/') || path.startsWith('/hls/')) {
    const ok = allowed(req);
    log.push({ path, ok, referer: req.headers.referer || '', ua: req.headers['user-agent'] || '', cookie: req.headers.cookie || '',
               native: !!req.headers['x-playback-session-id'], range: req.headers.range || '' });
    if (!ok) { res.writeHead(403); return res.end('Referer and cookie of the page required'); }
    if (path === '/hls/master.m3u8') { res.writeHead(200, { 'content-type': 'application/vnd.apple.mpegurl' }); return res.end(MASTER); }
    if (/^\/hls\/v\d+\.m3u8$/.test(path)) { res.writeHead(200, { 'content-type': 'application/vnd.apple.mpegurl' }); return res.end(VARIANT); }
    if (path === '/media/clip.mp4' || path === '/media/clip.dat') {
      const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
      let start = 0, end = size - 1, status = 200;
      if (range) { if (range[1]) start = Number(range[1]); if (range[2]) end = Math.min(Number(range[2]), size - 1); status = 206; }
      const headers = { 'content-type': path.endsWith('.mp4') ? 'video/mp4' : 'application/octet-stream', 'accept-ranges': 'bytes', 'content-length': end - start + 1 };
      if (status === 206) headers['content-range'] = `bytes ${start}-${end}/${size}`;
      res.writeHead(status, headers);
      if (req.method === 'HEAD') return res.end();
      return fs.createReadStream(file, { start, end }).pipe(res);
    }
  }
  res.writeHead(404);
  res.end('not found');
}).listen(port, '127.0.0.1', () => console.log('mock-page on ' + port));

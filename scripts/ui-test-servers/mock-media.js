// Serves one video file for every /movie/... and /tv/... request, with Range support. UI tests use it as "your media server".
//   node scripts/ui-test-servers/mock-media.js <video file> [port]
const http = require('http');
const fs = require('fs');
const file = process.argv[2];
const port = Number(process.argv[3] || 8160);
if (!file) { console.error('usage: mock-media.js <video file> [port]'); process.exit(1); }
const size = fs.statSync(file).size;
http.createServer((req, res) => {
  const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
  let start = 0, end = size - 1, status = 200;
  if (range) { if (range[1]) start = Number(range[1]); if (range[2]) end = Math.min(Number(range[2]), size - 1); status = 206; }
  const headers = { 'content-type': 'video/quicktime', 'accept-ranges': 'bytes', 'content-length': end - start + 1 };
  if (status === 206) headers['content-range'] = `bytes ${start}-${end}/${size}`;
  res.writeHead(status, headers);
  if (req.method === 'HEAD') return res.end();
  fs.createReadStream(file, { start, end }).pipe(res);
}).listen(port, '127.0.0.1', () => console.log('mock-media on ' + port));

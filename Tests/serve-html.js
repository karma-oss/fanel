const http = require('http');
const fs = require('fs');
const path = require('path');

const HTML_PATH = path.resolve(__dirname, '../Sources/FANEL/Resources/CommandRoom.html');
const html = fs.readFileSync(HTML_PATH, 'utf-8');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
});

server.listen(9222, '127.0.0.1', () => {
  console.log('Serving CommandRoom.html on http://127.0.0.1:9222');
});

#!/usr/bin/env node
// CI 用的假 dsh：写一条带 token 的启动行、按 token 换 dsh-auth cookie，
// 并在 /api/remote.mux 上提供一个最小的 WebSocket 流（open → item → end）。
import { createServer } from 'node:http';
import { appendFileSync, mkdirSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';

const port = Number(process.env.PORT ?? 3080);
let token = randomBytes(32).toString('base64url');
const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh');
mkdirSync(dshHome, { recursive: true });
appendFileSync(join(dshHome, 'dsh-web.log'), `dsh web: http://127.0.0.1:${port}/?token=${token}\n`);

// 第一次成功调用后 3 秒换一次 token，模拟 dsh 重启后的凭据失效。
let rotationScheduled = false;
function scheduleRotation() {
  if (rotationScheduled) return;
  rotationScheduled = true;
  setTimeout(() => {
    token = randomBytes(32).toString('base64url');
    appendFileSync(join(dshHome, 'dsh-web.log'), `dsh web: http://127.0.0.1:${port}/?token=${token}\n`);
  }, 3000);
}

function cookieOk(req) {
  const raw = req.headers.cookie ?? '';
  const match = raw.split(';').map((part) => part.trim()).find((part) => part.startsWith('dsh-auth-'));
  if (!match) return false;
  return match.slice(match.indexOf('=') + 1) === token;
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://127.0.0.1');

  if (req.method === 'POST' && url.pathname.startsWith('/api/')) {
    if (!cookieOk(req)) { res.writeHead(401).end('unauthorized'); return; }
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const request = JSON.parse(raw || '{}');
      const rpcId = request.rpcId ?? '';
      const method = request.method ?? url.pathname.slice('/api/'.length);
      const reply = (result) => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ type: 'server-response', rpcId, result }));
      };
      if (method === 'session/list') {
        scheduleRotation();
        reply({ ok: true, value: { items: [] } });
      } else if (method === 'session/big') {
        // 大响应回归：真实 session/list 约 1 MB，用来暴露转发层截断/丢字节。
        const items = Array.from({ length: 2000 }, (_, i) => ({
          sessionId: 'session-big-' + String(i).padStart(4, '0'),
          updatedAt: 1792937037475 + i,
          agentAvailable: true,
          formatStatus: 'current',
          running: false,
          blank: false,
          cwd: '/tmp/big-project',
          title: 'big response probe ' + 'x'.repeat(180),
        }));
        // 分块写、不设 Content-Length：与真实 dsh 的 chunked 传输一致。
        const body = JSON.stringify({ type: 'server-response', rpcId, result: { ok: true, value: { items } } });
        res.writeHead(200, { 'content-type': 'application/json' });
        for (let offset = 0; offset < body.length; offset += 64 * 1024) {
          res.write(body.slice(offset, offset + 64 * 1024));
        }
        res.end();
      } else {
        reply({ ok: false, error: { code: 'gateway/not-found', message: 'unknown endpoint ' + method, details: {} } });
      }
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/' && url.searchParams.get('token') === token) {
    const authority = req.headers.host ?? '127.0.0.1:3080';
    res.writeHead(303, {
      location: './',
      'set-cookie': `dsh-auth-${authority}=${token}; Path=/; HttpOnly`,
    });
    res.end();
    return;
  }

  res.writeHead(401).end('unauthorized');
});

function serverFrame(payload) {
  const length = payload.length;
  if (length < 126) return Buffer.concat([Buffer.from([0x81, length]), payload]);
  return Buffer.concat([Buffer.from([0x81, 126, (length >> 8) & 0xff, length & 0xff]), payload]);
}

function handleSocket(socket, initial) {
  let buffer = Buffer.from(initial ?? Buffer.alloc(0));

  const pump = () => {
    for (;;) {
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;

      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) {
        const mask = buffer.subarray(maskOffset, maskOffset + 4);
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      }
      buffer = buffer.subarray(offset + length);

      if (opcode === 0x8) { socket.end(); return; }
      if (opcode !== 0x1) continue;

      let frame;
      try { frame = JSON.parse(payload.toString()); } catch { continue; }
      if (frame.type === 'open') {
        socket.write(serverFrame(Buffer.from(JSON.stringify({
          type: 'item', streamId: frame.streamId, value: { baseline: true, endpoint: frame.endpoint },
        }))));
        socket.write(serverFrame(Buffer.from(JSON.stringify({ type: 'end', streamId: frame.streamId }))));
      }
    }
  };

  pump();
  socket.on('data', (chunk) => { buffer = Buffer.concat([buffer, chunk]); pump(); });
  socket.on('error', () => {});
}

server.on('upgrade', (req, socket, head) => {
  if (!cookieOk(req)) { socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n'); socket.destroy(); return; }
  const accept = createHash('sha1')
    .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );
  handleSocket(socket, head);
});

server.listen(port, '127.0.0.1', () => console.error('fake dsh listening on 127.0.0.1:' + port));

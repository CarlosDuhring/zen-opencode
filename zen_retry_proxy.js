#!/usr/bin/env node
'use strict';
/*
 * zen_retry_proxy.js - proxy HTTP local com retry INVISIVEL no limite de cota.
 *
 * O opencode fala HTTP puro com 127.0.0.1:8897/zen/v1/... (baseURL local).
 * Este proxy repassa para https://opencode.ai via WARP (SOCKS 127.0.0.1:40000).
 * No 429 / "Free usage limit", gira o WARP (zen_rotate.py) e REPETE o mesmo
 * request ate conseguir. O cliente (opencode) nunca ve o erro: so demora um
 * pouco mais naquela request. Cada request e reenviada identica -> o modelo
 * "continua" sozinho, ilimitado.
 *
 * Uso: node zen_retry_proxy.js [porta]
 * Env:
 *   ZEN_RETRY_PORT      porta local (default 8897)
 *   ZEN_UP_HOST         host upstream (default opencode.ai)
 *   ZEN_WARP_SOCKS_PORT porta do SOCKS do WARP (default 40000)
 *   ZEN_RETRY_MAX       tentativas de rotacao por request (default 6)
 */
const http = require('http');
const https = require('https');
const net = require('net');
const tls = require('tls');
const path = require('path');
const { execFile } = require('child_process');

const PORT = parseInt(process.argv[2] || process.env.ZEN_RETRY_PORT || '8897', 10);
const UP_HOST = process.env.ZEN_UP_HOST || 'opencode.ai';
const UP_PORT = 443;
const SOCKS_HOST = '127.0.0.1';
const SOCKS_PORT = parseInt(process.env.ZEN_WARP_SOCKS_PORT || '40000', 10);
const MAX_RETRIES = parseInt(process.env.ZEN_RETRY_MAX || '6', 10);
const ROTATE = path.join(__dirname, 'zen_rotate.py');
const QUOTA_RE = /Free usage limit|FreeTierError|Free usage exceeded/i;

function log(m) {
  console.log(`[${new Date().toISOString().slice(11, 19)}] ${m}`);
}

// --- SOCKS5 (sem auth) CONNECT ate dest, devolve o socket TCP cru ---
function socksConnect(destHost, destPort, cb) {
  const s = net.connect(SOCKS_PORT, SOCKS_HOST);
  let stage = 0, buf = Buffer.alloc(0), done = false;
  const fail = (e) => { if (done) return; done = true; try { s.destroy(); } catch (_) {} cb(e); };
  s.on('error', fail);
  s.setTimeout(30000, () => fail(new Error('socks timeout')));
  s.once('connect', () => s.write(Buffer.from([5, 1, 0])));
  const onData = (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    if (stage === 0) {
      if (buf.length < 2) return;
      if (buf[0] !== 5 || buf[1] !== 0) return fail(new Error('socks auth falhou'));
      buf = buf.slice(2);
      stage = 1;
      const hb = Buffer.from(destHost);
      s.write(Buffer.concat([Buffer.from([5, 1, 0, 3, hb.length]), hb,
        Buffer.from([(destPort >> 8) & 0xff, destPort & 0xff])]));
    } else if (stage === 1) {
      if (buf.length < 4) return;
      if (buf[0] !== 5 || buf[1] !== 0) return fail(new Error('socks recusou 0x' + buf[1].toString(16)));
      const atyp = buf[3];
      let need = 4;
      if (atyp === 0x01) need = 4 + 4 + 2;
      else if (atyp === 0x03) { if (buf.length < 5) return; need = 5 + buf[4] + 2; }
      else if (atyp === 0x04) need = 4 + 16 + 2;
      if (buf.length < need) return;
      done = true;
      s.setTimeout(0);
      s.removeListener('data', onData);
      cb(null, s);
    }
  };
  s.on('data', onData);
}

// agent HTTPS que tuneliza cada conexao pelo SOCKS do WARP
class SocksAgent extends https.Agent {
  createConnection(_options, cb) {
    socksConnect(UP_HOST, UP_PORT, (err, raw) => {
      if (err) return cb(err);
      const t = tls.connect({ socket: raw, servername: UP_HOST }, () => cb(null, t));
      t.on('error', cb);
    });
  }
}
const agent = new SocksAgent({ keepAlive: false });

// --- rotacao serializada (uma de cada vez) ---
let rotating = false;
const rotateQueue = [];
function rotate(cb) {
  if (rotating) { rotateQueue.push(cb); return; }
  rotating = true;
  log('rotacionando WARP...');
  execFile('python3', [ROTATE], { timeout: 90000 }, (err, stdout) => {
    const out = (stdout || '').trim().split('\n').pop() || 'direct';
    log(`rotate -> ${out}`);
    // espera o SOCKS do WARP voltar a responder antes de liberar
    setTimeout(() => {
      rotating = false;
      cb();
      const q = rotateQueue.splice(0);
      q.forEach((fn) => fn());
    }, 1500);
  });
}

function handle(req, res) {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    log(`${req.method} ${req.url} (${body.length}b)`);
    const headers = Object.assign({}, req.headers);
    delete headers['proxy-connection'];
    delete headers['connection'];
    delete headers['transfer-encoding'];
    headers.host = UP_HOST;
    headers['content-length'] = body.length;

    let attempt = 0;
    const send502 = () => {
      try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('zen_retry_proxy: upstream falhou\n'); } catch (_) {}
    };

    const tryOnce = () => {
      attempt++;
      const upReq = https.request({
        host: UP_HOST, port: UP_PORT, path: req.url, method: req.method,
        headers, agent, timeout: 300000,
      }, (upRes) => {
        const sc = upRes.statusCode || 0;
        if (sc === 429) { upRes.resume(); return retry(); }
        if (sc >= 400) {
          const b = [];
          upRes.on('data', (c) => b.push(c));
          upRes.on('end', () => {
            const txt = Buffer.concat(b).toString('utf8');
            if (QUOTA_RE.test(txt)) return retry();
            const h = Object.assign({}, upRes.headers);
            delete h['transfer-encoding'];
            try { res.writeHead(sc, h); res.end(txt); } catch (_) {}
          });
          upRes.on('error', () => retry());
          return;
        }
        // 2xx/3xx: stream direto pro cliente
        const h = Object.assign({}, upRes.headers);
        delete h['transfer-encoding'];
        delete h['content-length'];
        try { res.writeHead(sc, h); } catch (_) {}
        upRes.pipe(res);
        upRes.on('error', () => { try { res.destroy(); } catch (_) {} });
      });
      upReq.on('timeout', () => { try { upReq.destroy(); } catch (_) {} retry(); });
      upReq.on('error', () => retry());
      if (body.length) upReq.write(body);
      upReq.end();
    };

    const retry = () => {
      if (attempt > MAX_RETRIES) { log(`  desisti apos ${MAX_RETRIES} tentativas em ${req.url}`); return send502(); }
      log(`  limite em ${req.method} ${req.url} -> gira WARP (tentativa ${attempt})`);
      rotate(tryOnce);
    };

    tryOnce();
  });
}

const server = http.createServer(handle);
server.on('error', (e) => { log('server erro: ' + e.message); process.exit(1); });
process.on('uncaughtException', (e) => log('uncaught: ' + (e && e.message)));
process.on('unhandledRejection', (e) => log('unhandled: ' + e));
server.listen(PORT, '127.0.0.1', () => {
  log(`zen_retry_proxy up: 127.0.0.1:${PORT} -> https://${UP_HOST} via WARP socks ${SOCKS_PORT}`);
});

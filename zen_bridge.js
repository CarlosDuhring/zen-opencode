#!/usr/bin/env node
/*
 * zen_bridge.js - proxy HTTP local que repassa para o SOCKS5 do WARP.
 *
 * O cliente opencode (Bun) honra HTTPS_PROXY mas nao fala socks5h.
 * Este bridge fala HTTP CONNECT e faz o handshake SOCKS5 com o WARP.
 *
 * Uso: node zen_bridge.js [porta] [socks_host] [socks_port]
 *      node zen_bridge.js 8899 127.0.0.1 40000
 */
const net = require('net');
const http = require('http');
const dns = require('dns');

const PORT = parseInt(process.argv[2] || '8899', 10);
const SOCKS_HOST = process.argv[3] || '127.0.0.1';
const SOCKS_PORT = parseInt(process.argv[4] || '40000', 10);

function log(msg) {
  const t = new Date().toISOString().slice(11, 19);
  console.log(`[${t}] ${msg}`);
}

// Handshake SOCKS5 (sem auth) e CONNECT ao destino. Chama cb(err, socket).
// Fallback: se o SOCKS do WARP estiver fora, conecta direto (sem VPN).
// Sem isso o cliente recebe ECONNREFUSED e o app inteiro quebra.
function noop() {}

function directConnect(destHost, destPort, cb) {
  const d = net.connect(destPort, destHost);
  d.on('error', noop); // nunca deixa um erro de socket virar crash do processo
  let done = false;
  const fail = (e) => { if (!done) { done = true; try { d.destroy(); } catch (_) {} cb(e); } };
  d.once('error', fail);
  d.once('timeout', () => fail(new Error('direct timeout')));
  d.setTimeout(15000);
  d.once('connect', () => {
    if (done) return;
    done = true;
    d.removeAllListeners('timeout');
    d.on('error', noop); // reassina o absorvedor de erro depois do connect
    d.setTimeout(0);
    log(`  fallback direto ok: ${destHost}:${destPort}`);
    cb(null, d, Buffer.alloc(0));
  });
}

// converte "2a09:bac5:ca1:79b::c2:e" em 16 bytes. Retorna null se invalido.
function ipv6ToBuffer(addr) {
  try {
    let a = String(addr).trim();
    if (a.startsWith('[') && a.endsWith(']')) a = a.slice(1, -1);
    const zone = a.indexOf('%');
    if (zone >= 0) a = a.slice(0, zone);
    const halves = a.split('::');
    if (halves.length > 2) return null;
    const head = halves[0] ? halves[0].split(':') : [];
    const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
    const missing = 8 - head.length - tail.length;
    if (halves.length === 2 && missing < 0) return null;
    const groups = halves.length === 2 ? head.concat(new Array(missing).fill('0'), tail) : head;
    if (groups.length !== 8) return null;
    const b = Buffer.alloc(16);
    for (let i = 0; i < 8; i++) {
      const v = parseInt(groups[i], 16);
      if (isNaN(v) || v < 0 || v > 0xffff) return null;
      b.writeUInt16BE(v, i * 2);
    }
    return b;
  } catch (_) { return null; }
}

function socksConnect(destHost, destPort, cb, destV6) {
  const s = net.connect(SOCKS_PORT, SOCKS_HOST);
  s.on('error', noop); // idem: erro pos-handshake (ECONNRESET) nao derruba o bridge
  let done = false;
  const fail = (e) => {
    if (done) return;
    done = true;
    try { s.destroy(); } catch (_) {}
    log(`  socks falhou (${e.message}), tentando direto`);
    directConnect(destHost, destPort, cb);
  };

  s.once('error', fail);
  s.once('timeout', () => fail(new Error('socks timeout')));
  s.setTimeout(15000);

  s.once('connect', () => {
    // greeting: ver 5, 1 metodo, sem auth
    s.write(Buffer.from([0x05, 0x01, 0x00]));
  });

  let stage = 0;
  let buf = Buffer.alloc(0);

  s.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    if (stage === 0) {
      if (buf.length < 2) return;
      if (buf[0] !== 0x05) return fail(new Error('socks: versao invalida'));
      if (buf[1] !== 0x00) return fail(new Error('socks: metodo nao aceito'));
      buf = buf.slice(2);
      stage = 1;
      // request CONNECT
      let req;
      if (destV6) {
        // ATYP 0x04: endereco IPv6 literal (16 bytes)
        const b = ipv6ToBuffer(destV6);
        if (!b) return fail(new Error('ipv6 invalido: ' + destV6));
        req = Buffer.concat([
          Buffer.from([0x05, 0x01, 0x00, 0x04]),
          b,
          Buffer.from([(destPort >> 8) & 0xff, destPort & 0xff]),
        ]);
      } else {
        const hostBuf = Buffer.from(destHost, 'utf8');
        req = Buffer.concat([
          Buffer.from([0x05, 0x01, 0x00, 0x03, hostBuf.length]),
          hostBuf,
          Buffer.from([(destPort >> 8) & 0xff, destPort & 0xff]),
        ]);
      }
      s.write(req);
    }
    if (stage === 1) {
      if (buf.length < 4) return;
      if (buf[0] !== 0x05) return fail(new Error('socks: resposta invalida'));
      const rep = buf[1];
      if (rep !== 0x00) return fail(new Error('socks: connect recusado 0x' + rep.toString(16)));
      const atyp = buf[3];
      let need = 4;
      if (atyp === 0x01) need = 4 + 4 + 2;
      else if (atyp === 0x03) { if (buf.length < 5) return; need = 5 + buf[4] + 2; }
      else if (atyp === 0x04) need = 4 + 16 + 2;
      if (buf.length < need) return;
      buf = buf.slice(need);
      stage = 2;
      done = true;
      s.setTimeout(0);
      cb(null, s, buf);
    }
  });
}

const server = http.createServer((req, res) => {
  res.writeHead(405, { 'Content-Type': 'text/plain' });
  res.end('use CONNECT\n');
});

// --- controle local: porta 8898 ---
// GET /rotate  -> derruba todos os tuneis ativos (forca o app a reconectar
//                 pelo novo IP do WARP sem reiniciar o servico)
// GET /health  -> estado do bridge
const CONTROL_PORT = parseInt(process.argv[5] || '8898', 10);
const tunnels = new Set(); // { client, upstream }

const ctl = http.createServer((req, res) => {
  const u = (req.url || '').split('?')[0];
  if (u === '/rotate') {
    let n = 0;
    for (const t of tunnels) {
      try { t.client.destroy(); } catch (_) {}
      try { t.upstream.destroy(); } catch (_) {}
      n++;
    }
    tunnels.clear();
    log(`rotate: ${n} tunel(is) derrubado(s)`);
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`rotated ${n}\n`);
    return;
  }
  if (u === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ up: true, tunnels: tunnels.size, socks: `${SOCKS_HOST}:${SOCKS_PORT}` }) + '\n');
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('use /rotate ou /health\n');
});

ctl.on('error', (e) => log('erro no controle: ' + e.message));
ctl.listen(CONTROL_PORT, '127.0.0.1', () => {
  log(`zen_bridge controle: 127.0.0.1:${CONTROL_PORT} (/rotate, /health)`);
});

// Rota por destino: so os dominios do opencode (modelos free) saem pelo WARP.
// Todo o resto (openrouter pago, etc.) sai direto pelo IP da casa.
function rotaWarp(host) {
  const h = String(host || '').toLowerCase();
  // models.opencode.ai = catalogo estatico (11 MB). Nao gasta cota, nao precisa
  // de IP novo, e via WARPIPv6 levava 15s -> sai direto.
  if (h === 'models.opencode.ai') return false;
  return h === 'opencode.ai' || h.endsWith('.opencode.ai');
}

server.on('connect', (req, clientSocket, head) => {
  const [host, portStr] = req.url.split(':');
  const port = parseInt(portStr || '443', 10);
  // cliente (opencode/Bun) que aborta no meio do handshake gera ECONNRESET aqui.
  // Sem este handler o bridge inteiro morria e o opencode passava a dar
  // ECONNREFUSED em todas as requisicoes (HTTPS_PROXY=127.0.0.1:8899).
  clientSocket.on('error', () => { try { clientSocket.destroy(); } catch (_) {} });
  const viaWarp = rotaWarp(host);
  log(`CONNECT ${host}:${port} ${viaWarp ? 'via WARP' : 'direto'}`);

  const onUpstream = (err, upstream, leftover) => {
    if (err) {
      log(`  falhou: ${err.message}`);
      try { clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (_) {}
      return;
    }
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (leftover && leftover.length) upstream.write(leftover);
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
    upstream.on('error', () => { try { clientSocket.destroy(); } catch (_) {} });
    clientSocket.on('error', () => { try { upstream.destroy(); } catch (_) {} });
    upstream.on('close', () => { try { clientSocket.destroy(); } catch (_) {} });
    clientSocket.on('close', () => { try { upstream.destroy(); } catch (_) {} });

    const pair = { client: clientSocket, upstream };
    tunnels.add(pair);
    const drop = () => tunnels.delete(pair);
    upstream.on('close', drop);
    clientSocket.on('close', drop);
  };

  if (!viaWarp) {
    directConnect(host, port, onUpstream);
    return;
  }

  // modelos free: sai pelo IPv6 do WARP. O bloco IPv6 muda a cada registro,
  // entao cada registro novo = cota nova. Se nao houver AAAA, cai no nome.
  dns.promises.resolve6(host).then((addrs) => {
    const v6 = addrs && addrs[0];
    if (v6) log(`  ${host} -> [${v6}] (IPv6)`);
    socksConnect(host, port, onUpstream, v6);
  }).catch(() => {
    log(`  ${host} sem AAAA, usando nome`);
    socksConnect(host, port, onUpstream);
  });
});

server.on('error', (e) => {
  log('erro no servidor: ' + e.message);
  process.exit(1);
});

// rede de seguranca final: erro solto nunca mata o processo (o opencode depende
// desta porta; morrer = ECONNREFUSED em tudo).
process.on('uncaughtException', (e) => log(`uncaughtException ignorada: ${e && e.message}`));
process.on('unhandledRejection', (e) => log(`unhandledRejection ignorada: ${e && e.message}`));

server.listen(PORT, '127.0.0.1', () => {
  log(`zen_bridge up: 127.0.0.1:${PORT} -> socks ${SOCKS_HOST}:${SOCKS_PORT}`);
});

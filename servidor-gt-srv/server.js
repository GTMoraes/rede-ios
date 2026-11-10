// rede-srv: servidor do app Rede no GT-SRV (porta 9092, LAN + Tailscale).
//   /id                 identidade (o app confere se achou o servidor certo)
//   /dl?bytes=N         download do teste de velocidade (bytes aleatórios, sem disco)
//   /up                 upload do teste: lê tudo e responde quantos bytes chegaram
//   /wantest?secs=8     teste de internet pelo cabo (GT-SRV → Cloudflare), sem Wi-Fi no caminho
//   /router/...         ponte para a API do roteador (http://10.0.0.1:8077/...), para usar fora de casa
// Sem segredo aqui: o token do roteador vem do app no cabeçalho X-NM-Token e só é repassado.
'use strict';
const http = require('http');
const https = require('https');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 9092);
const ROUTER = new URL(process.env.ROUTER || 'http://10.0.0.1:8077');
const BLOCO = crypto.randomBytes(1 << 20); // 1 MB repetido no download

function json(res, code, obj) {
  const b = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(b) });
  res.end(b);
}

function download(req, res, u) {
  const pedido = Number(u.searchParams.get('bytes')) || 2e9;
  const total = Math.max(1, Math.min(pedido, 4e9));
  let enviados = 0;
  let fechado = false;
  res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': total,
    'Cache-Control': 'no-store' });
  res.on('close', () => { fechado = true; });
  const bombear = () => {
    while (!fechado && enviados < total) {
      const n = Math.min(BLOCO.length, total - enviados);
      enviados += n;
      if (!res.write(n === BLOCO.length ? BLOCO : BLOCO.subarray(0, n))) {
        res.once('drain', bombear);
        return;
      }
    }
    if (!fechado) res.end();
  };
  bombear();
}

function upload(req, res) {
  let n = 0;
  const t0 = process.hrtime.bigint();
  req.on('data', (c) => { n += c.length; });
  req.on('end', () => {
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    json(res, 200, { bytes: n, ms: Math.round(ms) });
  });
  req.on('error', () => {});
}

// ---- teste de internet pelo cabo ----------------------------------------
const CF = 'speed.cloudflare.com';
const agente = new https.Agent({ keepAlive: true, maxSockets: 16 });

function pingCF() {
  return new Promise((ok) => {
    const t0 = process.hrtime.bigint();
    const r = https.get({ host: CF, path: '/__down?bytes=0', agent: agente }, (res) => {
      res.resume();
      res.on('end', () => ok(Number(process.hrtime.bigint() - t0) / 1e6));
    });
    r.on('error', () => ok(null));
    r.setTimeout(5000, () => r.destroy());
  });
}

function baixarPor(ms, fluxos) {
  return new Promise((fim) => {
    let bytes = 0;
    const abertos = new Set();
    const t0 = Date.now();
    const limite = t0 + ms;
    let acabou = false;
    const abrir = () => {
      if (acabou || Date.now() >= limite) return;
      const r = https.get({ host: CF, path: '/__down?bytes=99999999', agent: agente }, (res) => {
        res.on('data', (c) => { bytes += c.length; });
        res.on('end', () => { abertos.delete(r); abrir(); });
        res.on('error', () => {});
      });
      r.on('error', () => { abertos.delete(r); });
      abertos.add(r);
    };
    for (let i = 0; i < fluxos; i++) abrir();
    setTimeout(() => {
      acabou = true;
      for (const r of abertos) r.destroy();
      fim({ bytes, secs: (Date.now() - t0) / 1000 });
    }, ms);
  });
}

function enviarPor(ms, fluxos) {
  return new Promise((fim) => {
    let bytes = 0;
    const abertos = new Set();
    const t0 = Date.now();
    let acabou = false;
    const abrir = () => {
      const r = https.request({ host: CF, path: '/__up', method: 'POST', agent: agente,
        headers: { 'Content-Type': 'application/octet-stream' } });
      r.on('response', (res) => res.resume());
      r.on('error', () => {});
      abertos.add(r);
      const escrever = () => {
        while (!acabou) {
          const ok = r.write(BLOCO, () => { if (!acabou) bytes += BLOCO.length; });
          if (!ok) { r.once('drain', escrever); return; }
        }
      };
      escrever();
    };
    for (let i = 0; i < fluxos; i++) abrir();
    setTimeout(() => {
      acabou = true;
      for (const r of abertos) r.destroy();
      fim({ bytes, secs: (Date.now() - t0) / 1000 });
    }, ms);
  });
}

let testando = false;
async function wantest(req, res, u) {
  if (testando) return json(res, 409, { error: 'busy' });
  testando = true;
  try {
    const secs = Math.min(15, Math.max(3, Number(u.searchParams.get('secs')) || 8));
    await pingCF();
    const pings = [];
    for (let i = 0; i < 5; i++) pings.push(await pingCF());
    const validos = pings.filter((x) => x != null).sort((a, b) => a - b);
    const d = await baixarPor(secs * 1000, 6);
    const s = await enviarPor(secs * 1000, 4);
    json(res, 200, {
      down_mbps: +(d.bytes * 8 / d.secs / 1e6).toFixed(1),
      up_mbps: +(s.bytes * 8 / s.secs / 1e6).toFixed(1),
      down_bytes: d.bytes, up_bytes: s.bytes,
      ping_ms: validos.length ? +validos[Math.floor(validos.length / 2)].toFixed(1) : null,
      streams: 6,
    });
  } catch (e) {
    json(res, 500, { error: String(e && e.message || e) });
  } finally {
    testando = false;
  }
}

// ---- ponte para o roteador ------------------------------------------------
function ponte(req, res, u) {
  const caminho = u.pathname.slice('/router'.length) + u.search;
  const cab = {};
  for (const k of ['x-nm-token', 'content-type', 'content-length', 'expect']) {
    if (req.headers[k] !== undefined) cab[k] = req.headers[k];
  }
  const r = http.request({ host: ROUTER.hostname, port: ROUTER.port || 80, path: caminho,
    method: req.method, headers: cab, timeout: 100000 }, (rr) => {
    const h = {};
    for (const k of ['content-type', 'content-length', 'cache-control']) {
      if (rr.headers[k] !== undefined) h[k] = rr.headers[k];
    }
    res.writeHead(rr.statusCode || 502, h);
    rr.pipe(res);
  });
  r.on('timeout', () => r.destroy(new Error('timeout')));
  r.on('error', (e) => {
    if (!res.headersSent) json(res, 502, { error: 'roteador: ' + e.message });
    else res.destroy();
  });
  res.on('close', () => { if (!res.writableFinished) r.destroy(); });
  req.pipe(r);
}

const srv = http.createServer((req, res) => {
  let u;
  try { u = new URL(req.url, 'http://x'); } catch { return json(res, 400, { error: 'url' }); }
  const p = u.pathname;
  if (p === '/id') return json(res, 200, { app: 'rede-srv', v: 1 });
  if (p === '/dl') return download(req, res, u);
  if (p === '/up' && req.method === 'POST') return upload(req, res);
  if (p === '/wantest') return wantest(req, res, u);
  if (p.startsWith('/router/')) return ponte(req, res, u);
  json(res, 404, { error: 'nada aqui' });
});
srv.requestTimeout = 0;
srv.headersTimeout = 30000;
srv.keepAliveTimeout = 30000;
srv.listen(PORT, '0.0.0.0', () => console.log(`rede-srv na porta ${PORT}, roteador ${ROUTER.href}`));

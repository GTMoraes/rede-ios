// rede-srv: servidor do app Rede no GT-SRV (porta 9092, LAN + Tailscale).
//   /id                 identidade (o app confere se achou o servidor certo)
//   /dl?bytes=N         download do teste de velocidade (bytes aleatórios, sem disco)
//   /up                 upload do teste: lê tudo e responde quantos bytes chegaram
//   /wantest?secs=10    teste de internet pelo cabo (GT-SRV → Cloudflare), sem Wi-Fi no caminho; no container,
//                       repassado ao serviço rede-teste do WSL (WANTEST_URL), fora do limite de rede do Docker
//   /router/...         ponte para a API do roteador (http://10.0.0.1:8077/...), para usar fora de casa
//   /push/registrar     o app manda o token de push dele (POST {token}); exige X-NM-Token
//   /evento             o roteador avisa de aparelho novo no modo aprovação (POST); exige X-NM-Token
// Segredos só no ~/rede-srv/.env (fora do repositório): NM_TOKEN (o mesmo token do roteador) e a chave de push
// da Apple (APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8_B64, APNS_TOPIC). Os tokens de push ficam em /dados.
'use strict';
const http = require('http');
const https = require('https');
const http2 = require('http2');
const crypto = require('crypto');
const fs = require('fs');

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
const CF = process.env.CF_HOST || 'speed.cloudflare.com';
const agente = new https.Agent({ keepAlive: true, maxSockets: 32 });

function pingCF() {
  return new Promise((ok) => {
    const t0 = process.hrtime.bigint();
    const r = https.get({ host: CF, port: CF_PORT, path: '/__down?bytes=0', agent: agente }, (res) => {
      res.resume();
      res.on('end', () => ok(Number(process.hrtime.bigint() - t0) / 1e6));
    });
    r.on('error', () => ok(null));
    r.setTimeout(5000, () => r.destroy());
  });
}

// O caminho até a Cloudflare é longo (~60 ms pela TIM, contra 2 ms do fast.com, que mede dentro da rede da
// operadora). Num caminho longo cada conexão demora a acelerar; por isso: muitas conexões em paralelo e os
// primeiros segundos descartados (a taxa é medida só depois do aquecimento).
const CF_PORT = Number(process.env.CF_PORT || 443);
const AQUECIMENTO_MS = 2000;

function medirTaxa(ms, contar) {
  // contar() devolve o total de bytes até agora; mede do fim do aquecimento até o fim do teste
  return new Promise((fim) => {
    const t0 = Date.now();
    let base = null;
    setTimeout(() => { base = { bytes: contar(), t: Date.now() }; }, Math.min(AQUECIMENTO_MS, ms / 2));
    setTimeout(() => {
      const agora = Date.now();
      const total = contar();
      const b = base || { bytes: 0, t: t0 };
      fim({ bytes: total, util: total - b.bytes, secs: (agora - b.t) / 1000 });
    }, ms);
  });
}

function baixarPor(ms, fluxos) {
  let bytes = 0;
  const abertos = new Set();
  const limite = Date.now() + ms;
  let acabou = false;
  const abrir = () => {
    if (acabou || Date.now() >= limite) return;
    const r = https.get({ host: CF, port: CF_PORT, path: '/__down?bytes=99999999', agent: agente }, (res) => {
      res.on('data', (c) => { bytes += c.length; });
      res.on('end', () => { abertos.delete(r); abrir(); });
      res.on('error', () => {});
    });
    r.on('error', () => { abertos.delete(r); });
    abertos.add(r);
  };
  for (let i = 0; i < fluxos; i++) abrir();
  return medirTaxa(ms, () => bytes).then((m) => {
    acabou = true;
    for (const r of abertos) r.destroy();
    return m;
  });
}

function enviarPor(ms, fluxos) {
  let bytes = 0;
  const abertos = new Set();
  let acabou = false;
  const abrir = () => {
    const r = https.request({ host: CF, port: CF_PORT, path: '/__up', method: 'POST', agent: agente,
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
  return medirTaxa(ms, () => bytes).then((m) => {
    acabou = true;
    for (const r of abertos) r.destroy();
    return m;
  });
}

// repasse do container para o ajudante no WSL
function repassarWantest(req, res, u) {
  const alvo = new URL(process.env.WANTEST_URL);
  alvo.search = u.search;
  const r = http.get(alvo, { timeout: 90000 }, (rr) => {
    res.writeHead(rr.statusCode || 502, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    rr.pipe(res);
  });
  r.on('timeout', () => r.destroy(new Error('timeout')));
  r.on('error', (e) => {
    if (!res.headersSent) json(res, 502, { error: 'teste no WSL indisponível: ' + e.message });
  });
}

let testando = false;
async function wantest(req, res, u) {
  if (process.env.WANTEST_URL) return repassarWantest(req, res, u);
  if (testando) return json(res, 409, { error: 'busy' });
  testando = true;
  try {
    const secs = Math.min(15, Math.max(8, Number(u.searchParams.get('secs')) || 10));
    await pingCF();
    const pings = [];
    for (let i = 0; i < 5; i++) pings.push(await pingCF());
    const validos = pings.filter((x) => x != null).sort((a, b) => a - b);
    const d = await baixarPor(secs * 1000, 12);
    const s = await enviarPor(secs * 1000, 6);
    json(res, 200, {
      down_mbps: +(d.util * 8 / d.secs / 1e6).toFixed(1),
      up_mbps: +(s.util * 8 / s.secs / 1e6).toFixed(1),
      down_bytes: d.bytes, up_bytes: s.bytes,
      ping_ms: validos.length ? +validos[Math.floor(validos.length / 2)].toFixed(1) : null,
      streams: 12,
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

// ---- push pela Apple (APNs), sem bibliotecas: JWT ES256 com o crypto do Node e HTTP/2 -----------------
const NM_TOKEN = (process.env.NM_TOKEN || '').trim();
const APNS = {
  keyId: process.env.APNS_KEY_ID || '',
  teamId: process.env.APNS_TEAM_ID || '',
  topic: process.env.APNS_TOPIC || 'com.gtm.rede',
  host: process.env.APNS_HOST || 'https://api.push.apple.com',
  p8: process.env.APNS_KEY_P8_B64 ? Buffer.from(process.env.APNS_KEY_P8_B64, 'base64').toString('utf8') : '',
};
const DADOS = process.env.DADOS || '/dados';
const ARQ_TOKENS = DADOS + '/tokens.json';

function lerTokens() {
  try { return JSON.parse(fs.readFileSync(ARQ_TOKENS, 'utf8')); } catch { return []; }
}
function gravarTokens(t) {
  try { fs.mkdirSync(DADOS, { recursive: true }); fs.writeFileSync(ARQ_TOKENS, JSON.stringify(t)); } catch (e) {
    console.error('tokens:', e.message);
  }
}

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
let jwtCache = { valor: '', em: 0 };
function jwtApns() {
  const agora = Math.floor(Date.now() / 1000);
  if (jwtCache.valor && agora - jwtCache.em < 50 * 60) return jwtCache.valor;
  const cab = b64url(JSON.stringify({ alg: 'ES256', kid: APNS.keyId }));
  const corpo = b64url(JSON.stringify({ iss: APNS.teamId, iat: agora }));
  const ass = crypto.sign('sha256', Buffer.from(cab + '.' + corpo), { key: APNS.p8, dsaEncoding: 'ieee-p1363' });
  jwtCache = { valor: cab + '.' + corpo + '.' + b64url(ass), em: agora };
  return jwtCache.valor;
}

function enviarPush(token, payload) {
  return new Promise((ok) => {
    let sessao;
    try { sessao = http2.connect(APNS.host); } catch (e) { return ok({ status: 0, corpo: e.message }); }
    sessao.on('error', (e) => ok({ status: 0, corpo: e.message }));
    const r = sessao.request({
      ':method': 'POST', ':path': '/3/device/' + token,
      authorization: 'bearer ' + jwtApns(),
      'apns-topic': APNS.topic, 'apns-push-type': 'alert', 'apns-priority': '10',
      'content-type': 'application/json',
    });
    let status = 0;
    let corpo = '';
    r.on('response', (h) => { status = h[':status']; });
    r.on('data', (c) => { corpo += c; });
    r.on('end', () => { sessao.close(); ok({ status, corpo }); });
    r.on('error', (e) => { sessao.close(); ok({ status: 0, corpo: e.message }); });
    r.setTimeout(10000, () => r.close());
    r.end(JSON.stringify(payload));
  });
}

async function avisarTodos(payload) {
  const tokens = lerTokens();
  if (!APNS.p8 || !APNS.keyId || !APNS.teamId) return { enviados: 0, erro: 'APNs não configurado no .env' };
  let enviados = 0;
  const validos = [];
  for (const t of tokens) {
    const r = await enviarPush(t, payload);
    if (r.status === 200) enviados++;
    // 410 / BadDeviceToken: o app foi apagado ou o token mudou
    if (r.status === 410 || /BadDeviceToken|Unregistered/.test(r.corpo)) continue;
    if (r.status !== 200) console.error('apns', r.status, r.corpo);
    validos.push(t);
  }
  if (validos.length !== tokens.length) gravarTokens(validos);
  return { enviados };
}

function lerCorpo(req, limite = 64 * 1024) {
  return new Promise((ok, falha) => {
    let b = '';
    req.on('data', (c) => { b += c; if (b.length > limite) { req.destroy(); falha(new Error('grande demais')); } });
    req.on('end', () => ok(b));
    req.on('error', falha);
  });
}

function autorizado(req) {
  return NM_TOKEN !== '' && req.headers['x-nm-token'] === NM_TOKEN;
}

async function registrar(req, res) {
  if (!autorizado(req)) return json(res, 403, { error: 'token' });
  try {
    const { token } = JSON.parse(await lerCorpo(req));
    if (!/^[0-9a-f]{32,200}$/i.test(token || '')) return json(res, 400, { error: 'token de push inválido' });
    const t = lerTokens();
    if (!t.includes(token)) { t.push(token); gravarTokens(t.slice(-10)); }
    json(res, 200, { ok: true, push: Boolean(APNS.p8) });
  } catch (e) {
    json(res, 400, { error: e.message });
  }
}

async function evento(req, res) {
  if (!autorizado(req)) return json(res, 403, { error: 'token' });
  try {
    const ev = JSON.parse(await lerCorpo(req));
    if (ev.tipo !== 'pedido') return json(res, 400, { error: 'tipo' });
    const quem = ev.nome ? `${ev.nome} (${ev.banda})` : `Um aparelho sem nome (${ev.banda}, ${ev.mac})`;
    const r = await avisarTodos({
      aps: {
        alert: { title: 'Aparelho novo no Wi-Fi', body: `${quem} quer usar a rede. Segure para aprovar ou recusar.` },
        sound: 'default', category: 'PEDIDO', 'thread-id': 'pedidos',
      },
      mac: ev.mac, nome: ev.nome || '',
    });
    json(res, 200, r);
  } catch (e) {
    json(res, 400, { error: e.message });
  }
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
  if (p === '/push/registrar' && req.method === 'POST') return registrar(req, res);
  if (p === '/evento' && req.method === 'POST') return evento(req, res);
  json(res, 404, { error: 'nada aqui' });
});
srv.requestTimeout = 0;
srv.headersTimeout = 30000;
srv.keepAliveTimeout = 30000;
srv.listen(PORT, '0.0.0.0', () => console.log(`rede-srv na porta ${PORT}, roteador ${ROUTER.href}`));

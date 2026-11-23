'use strict';
// Grant review web app. Runs inside one reviewer's container, as "reviewer", with no network.
// It listens only on /run/web/web.sock, which nginx on the host reaches after signing the
// reviewer in. No npm dependencies: Node built-ins only.
//
// It drives pi in RPC mode, one pi process per application. The browser never talks to pi
// directly: this server builds every RPC command itself from a fixed set (prompt, abort,
// new_session, set_model, get_messages). pi's RPC "bash" command is never sent.

const http = require('http');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const { spawn, execFile } = require('child_process');

const HOME = '/home/reviewer';
const ORIG = path.join(HOME, 'originals');
const WORK = path.join(HOME, 'work');
const SOCK_DIR = '/run/web';
const SOCK = path.join(SOCK_DIR, 'web.sock');
const STATIC_DIR = path.join(__dirname, 'static');
const PROMPT_FILE = path.join(__dirname, 'system-prompt.md');
const IDLE_MS = 20 * 60 * 1000;
const MAX_AGENTS = 3;
const MAX_BODY = 1024 * 1024;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/;
const TOOLS = 'read,grep,find,ls,write,edit';

const providers = JSON.parse(fs.readFileSync(path.join(HOME, '.pi/agent/models.json'), 'utf8')).providers;
const PROVIDER = Object.keys(providers)[0];
const MODELS = providers[PROVIDER].models.map((m) => ({ id: m.id, name: m.name || m.id }));

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
};

const CSP = [
  "default-src 'none'", "script-src 'self'", "style-src 'self'", "img-src 'self'",
  "connect-src 'self'", "frame-src 'self'", "object-src 'none'", "base-uri 'none'",
  "form-action 'none'", "frame-ancestors 'self'",
].join('; ');

function baseHeaders(extra) {
  return Object.assign({
    'Content-Security-Policy': CSP,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Cache-Control': 'no-store',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), clipboard-read=()',
  }, extra || {});
}

function send(res, status, body, type) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(status, baseHeaders({ 'Content-Type': type || 'application/json; charset=utf-8', 'Content-Length': buf.length }));
  res.end(buf);
}
const fail = (res, status, msg) => send(res, status, { error: msg });

// ---------- applications and files ----------

function typeOf(name) {
  const ext = path.extname(name).toLowerCase();
  if (ext === '.pdf') return 'pdf';
  if (['.txt', '.md', '.csv'].includes(ext)) return 'text';
  return 'other';
}

async function originalPath(name) {
  if (!NAME_RE.test(name)) return null;
  const p = path.join(ORIG, name);
  try {
    const st = await fsp.lstat(p);
    return st.isFile() ? p : null;      // lstat: never follow a link
  } catch { return null; }
}

function workDir(name) { return path.join(WORK, name); }

async function ensureWorkDir(name) {
  const d = workDir(name);
  await fsp.mkdir(d, { recursive: true, mode: 0o700 });
  const st = await fsp.lstat(d);
  if (!st.isDirectory()) throw new Error('work folder is not a directory');
  return d;
}

async function listApps() {
  let names = [];
  try { names = await fsp.readdir(ORIG); } catch { /* none loaded */ }
  const apps = [];
  for (const name of names.sort()) {
    const p = await originalPath(name);
    if (!p) continue;
    const st = await fsp.stat(p);
    let hasNotes = false;
    try { hasNotes = (await fsp.lstat(path.join(workDir(name), 'notes.md'))).isFile(); } catch { /* none */ }
    apps.push({ name, size: st.size, type: typeOf(name), hasNotes });
  }
  return apps;
}

// Extracted text sits next to the notes so pi can read it quickly. pdftotext runs here, inside
// the reviewer's own container, never on the host.
function extractText(name, src, dir) {
  const out = path.join(dir, name + '.txt');
  return new Promise((resolve) => {
    fs.lstat(out, (err, st) => {
      if (!err && st.isFile()) return resolve(out);
      if (typeOf(name) === 'text') {
        fs.copyFile(src, out, (e) => resolve(e ? null : out));
        return;
      }
      if (typeOf(name) !== 'pdf') return resolve(null);
      execFile('pdftotext', ['-layout', '-enc', 'UTF-8', src, out], { timeout: 120000 }, (e) => resolve(e ? null : out));
    });
  });
}

// ---------- pi agents, one per application ----------

const agents = new Map(); // name -> agent

function systemPrompt(name, textPath) {
  const base = fs.readFileSync(PROMPT_FILE, 'utf8');
  return base
    .replaceAll('{{APPLICATION}}', name)
    .replaceAll('{{ORIGINAL}}', path.join(ORIG, name))
    .replaceAll('{{TEXT}}', textPath || '(no text extract: read the original directly)')
    .replaceAll('{{WORK}}', workDir(name));
}

class Agent {
  constructor(name, dir, textPath, model) {
    this.name = name;
    this.listeners = new Set();
    this.pending = new Map();
    this.seq = 0;
    this.streaming = false;
    this.lastUsed = Date.now();
    this.model = model;
    this.buf = '';
    const args = [
      '--mode', 'rpc', '--offline',
      '--provider', PROVIDER, '--model', model,
      '--session-dir', path.join(dir, '.sessions'), '--continue',
      '--tools', TOOLS,
      '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-context-files', '--no-themes',
      '--append-system-prompt', systemPrompt(name, textPath),
    ];
    this.proc = spawn('pi', args, {
      cwd: dir,
      env: { HOME, PATH: process.env.PATH, PI_OFFLINE: '1', LANG: 'C.UTF-8' },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.proc.stdout.on('data', (d) => this.onData(d));
    this.proc.stderr.on('data', (d) => { this.lastErr = String(d).slice(-500); });
    this.proc.on('exit', (code) => {
      agents.delete(this.name);
      for (const [, p] of this.pending) p.reject(new Error('assistant stopped'));
      this.pending.clear();
      if (this.streaming) this.emit({ t: 'error', text: 'The assistant stopped unexpectedly.' });
      this.emit({ t: 'end' });
      if (code) console.error(`pi for ${this.name} exited ${code}: ${this.lastErr || ''}`);
    });
  }

  onData(d) {
    this.buf += d;
    let i;
    while ((i = this.buf.indexOf('\n')) >= 0) {   // JSONL on LF only (not readline: see rpc.md)
      let line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      this.onMessage(msg);
    }
  }

  onMessage(m) {
    if (m.type === 'response') {
      const p = m.id && this.pending.get(m.id);
      if (p) { this.pending.delete(m.id); m.success ? p.resolve(m.data) : p.reject(new Error(m.error || 'refused')); }
      return;
    }
    switch (m.type) {
      case 'agent_start': this.streaming = true; this.emit({ t: 'start' }); break;
      case 'agent_end': this.streaming = false; this.emit({ t: 'end' }); break;
      case 'message_update': {
        const e = m.assistantMessageEvent || {};
        if (e.type === 'text_delta') this.emit({ t: 'delta', text: e.delta });
        else if (e.type === 'thinking_start') this.emit({ t: 'thinking' });
        break;
      }
      case 'message_end': {
        const msg = m.message || {};
        if (msg.role === 'assistant' && (msg.stopReason === 'error' || msg.errorMessage)) {
          this.emit({ t: 'error', text: 'The model returned an error. Try again, or pick another model.' });
        }
        break;
      }
      case 'tool_execution_start': this.emit({ t: 'tool', name: m.toolName, detail: toolDetail(m.args) }); break;
      case 'tool_execution_end': this.emit({ t: 'tool_end', name: m.toolName, error: !!m.isError }); break;
      case 'auto_retry_start': this.emit({ t: 'status', text: 'Retrying after a temporary error…' }); break;
      case 'compaction_start': this.emit({ t: 'status', text: 'Summarising earlier conversation to make room…' }); break;
      default: break;
    }
  }

  emit(ev) {
    const data = `data: ${JSON.stringify(ev)}\n\n`;
    for (const res of this.listeners) res.write(data);
  }

  // Only these command types are ever sent. "bash" is deliberately absent.
  command(type, fields) {
    const allowed = ['prompt', 'abort', 'new_session', 'set_model', 'get_messages', 'get_state'];
    if (!allowed.includes(type)) return Promise.reject(new Error('command not allowed'));
    const id = 'r' + (++this.seq);
    this.lastUsed = Date.now();
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.proc.stdin.write(JSON.stringify(Object.assign({ id, type }, fields || {})) + '\n');
      setTimeout(() => {
        if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('assistant did not answer')); }
      }, 30000);
    });
  }

  stop() { try { this.proc.kill('SIGTERM'); } catch { /* gone */ } }
}

function toolDetail(args) {
  if (!args || typeof args !== 'object') return '';
  const v = args.path || args.file_path || args.pattern || args.query || '';
  return String(v).replace(/^\/home\/reviewer\//, '~/').slice(0, 120);
}

async function getAgent(name, model) {
  let a = agents.get(name);
  if (a) { a.lastUsed = Date.now(); return a; }
  const src = await originalPath(name);
  if (!src) throw new Error('no such application');
  if (agents.size >= MAX_AGENTS) {
    const idle = [...agents.values()].filter((x) => !x.streaming).sort((x, y) => x.lastUsed - y.lastUsed)[0];
    if (!idle) throw new Error('too many conversations running; wait for one to finish');
    idle.stop();
    agents.delete(idle.name);
  }
  const dir = await ensureWorkDir(name);
  const textPath = await extractText(name, src, dir);
  const m = MODELS.some((x) => x.id === model) ? model : MODELS[0].id;
  a = new Agent(name, dir, textPath, m);
  agents.set(name, a);
  return a;
}

setInterval(() => {
  for (const a of agents.values()) {
    if (!a.streaming && a.listeners.size === 0 && Date.now() - a.lastUsed > IDLE_MS) a.stop();
  }
}, 60000).unref();

// A transcript for the browser: user text, assistant text, and which files tools touched.
function simplify(messages) {
  const out = [];
  for (const m of messages || []) {
    if (m.role === 'user') {
      const text = typeof m.content === 'string' ? m.content
        : (m.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
      out.push({ role: 'user', text });
    } else if (m.role === 'assistant') {
      const text = (m.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('');
      const tools = (m.content || []).filter((c) => c.type === 'toolCall').map((c) => ({ name: c.name, detail: toolDetail(c.arguments) }));
      if (!text && !tools.length) continue;
      const prev = out[out.length - 1];
      if (prev && prev.role === 'assistant') {
        prev.tools.push(...tools);
        prev.text = [prev.text, text].filter(Boolean).join('\n\n');
        prev.error = prev.error || m.stopReason === 'error';
      } else {
        out.push({ role: 'assistant', text, tools, error: m.stopReason === 'error' });
      }
    }
  }
  return out;
}

// ---------- HTTP ----------

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); } catch { reject(new Error('bad JSON')); } });
    req.on('error', reject);
  });
}

// Requests that change anything must come from this page: a custom header (which a
// cross-site form or image can't send) and, where the browser says, same-origin.
function sameOrigin(req) {
  const site = req.headers['sec-fetch-site'];
  return !site || site === 'same-origin' || site === 'none';
}
function isWrite(req) { return req.method === 'POST' || req.method === 'PUT'; }

async function serveFile(res, file, type, disposition, frameable) {
  const st = await fsp.stat(file);
  const headers = baseHeaders({
    'Content-Type': type, 'Content-Length': st.size,
    'Content-Disposition': `${disposition}; filename="${path.basename(file).replace(/"/g, '')}"`,
  });
  if (frameable) {
    // The browser's PDF viewer can't run under our page CSP; this response is the bytes only.
    delete headers['Content-Security-Policy'];
    headers['X-Frame-Options'] = 'SAMEORIGIN';
  }
  res.writeHead(200, headers);
  fs.createReadStream(file).pipe(res);
}

function transcriptMarkdown(name, messages) {
  const lines = [`# Conversation about ${name}`, '', `Exported ${new Date().toISOString()}`, ''];
  for (const m of simplify(messages)) {
    lines.push(m.role === 'user' ? '## You' : '## Assistant', '', m.text || '', '');
  }
  return lines.join('\n');
}

const routes = [];
const route = (method, re, fn) => routes.push({ method, re, fn });

route('GET', /^\/api\/session$/, async (req, res) => send(res, 200, { models: MODELS }));
route('GET', /^\/api\/apps$/, async (req, res) => send(res, 200, { apps: await listApps() }));

route('GET', /^\/api\/apps\/([^/]+)\/original$/, async (req, res, name) => {
  const p = await originalPath(name);
  if (!p) return fail(res, 404, 'not found');
  const t = typeOf(name);
  if (t === 'pdf') return serveFile(res, p, 'application/pdf', 'inline', true);
  if (t === 'text') return serveFile(res, p, 'text/plain; charset=utf-8', 'inline', true);
  return serveFile(res, p, 'application/octet-stream', 'attachment', false);
});

route('GET', /^\/api\/apps\/([^/]+)\/text$/, async (req, res, name) => {
  const p = await originalPath(name);
  if (!p) return fail(res, 404, 'not found');
  const out = await extractText(name, p, await ensureWorkDir(name));
  if (!out) return send(res, 200, { text: null });
  const st = await fsp.lstat(out);
  if (!st.isFile()) return fail(res, 500, 'text extract is not a file');
  send(res, 200, { text: (await fsp.readFile(out, 'utf8')).slice(0, 2000000) });
});

route('GET', /^\/api\/apps\/([^/]+)\/download$/, async (req, res, name) => {
  const p = await originalPath(name);
  if (!p) return fail(res, 404, 'not found');
  return serveFile(res, p, 'application/octet-stream', 'attachment', false);
});

route('GET', /^\/api\/apps\/([^/]+)\/notes$/, async (req, res, name) => {
  if (!(await originalPath(name))) return fail(res, 404, 'not found');
  let text = '';
  try {
    const p = path.join(workDir(name), 'notes.md');
    if ((await fsp.lstat(p)).isFile()) text = await fsp.readFile(p, 'utf8');
  } catch { /* none yet */ }
  send(res, 200, { text });
});

route('PUT', /^\/api\/apps\/([^/]+)\/notes$/, async (req, res, name) => {
  if (!(await originalPath(name))) return fail(res, 404, 'not found');
  const body = await readJson(req);
  if (typeof body.text !== 'string') return fail(res, 400, 'text required');
  const dir = await ensureWorkDir(name);
  const p = path.join(dir, 'notes.md');
  try { if ((await fsp.lstat(p)).isSymbolicLink()) return fail(res, 400, 'notes file is a link'); } catch { /* new */ }
  const tmp = path.join(dir, '.notes.tmp');
  await fsp.writeFile(tmp, body.text, { mode: 0o600 });
  await fsp.rename(tmp, p);
  send(res, 200, { saved: true });
});

route('GET', /^\/api\/apps\/([^/]+)\/notes\/download$/, async (req, res, name) => {
  if (!(await originalPath(name))) return fail(res, 404, 'not found');
  const p = path.join(workDir(name), 'notes.md');
  try { if (!(await fsp.lstat(p)).isFile()) throw new Error(); } catch { return fail(res, 404, 'no notes yet'); }
  res.writeHead(200, baseHeaders({
    'Content-Type': 'text/markdown; charset=utf-8',
    'Content-Disposition': `attachment; filename="notes-${name.replace(/"/g, '')}.md"`,
  }));
  fs.createReadStream(p).pipe(res);
});

route('GET', /^\/api\/apps\/([^/]+)\/chat\/history$/, async (req, res, name) => {
  const a = await getAgent(name);
  const data = await a.command('get_messages');
  send(res, 200, { messages: simplify(data && data.messages), model: a.model, streaming: a.streaming });
});

route('GET', /^\/api\/apps\/([^/]+)\/chat\/events$/, async (req, res, name) => {
  const a = await getAgent(name);
  res.writeHead(200, baseHeaders({ 'Content-Type': 'text/event-stream; charset=utf-8', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no' }));
  res.write('retry: 3000\n\n');
  a.listeners.add(res);
  const ping = setInterval(() => res.write(': ping\n\n'), 25000);
  req.on('close', () => { clearInterval(ping); a.listeners.delete(res); });
});

route('POST', /^\/api\/apps\/([^/]+)\/chat\/prompt$/, async (req, res, name) => {
  const body = await readJson(req);
  const message = typeof body.message === 'string' ? body.message.trim() : '';
  if (!message || message.length > 20000) return fail(res, 400, 'message required (max 20,000 characters)');
  const a = await getAgent(name, body.model);
  if (a.streaming) return fail(res, 409, 'the assistant is still answering');
  if (body.model && body.model !== a.model && MODELS.some((x) => x.id === body.model)) {
    await a.command('set_model', { provider: PROVIDER, modelId: body.model });
    a.model = body.model;
  }
  await a.command('prompt', { message });
  send(res, 202, { accepted: true });
});

route('POST', /^\/api\/apps\/([^/]+)\/chat\/abort$/, async (req, res, name) => {
  const a = agents.get(name);
  if (a) await a.command('abort').catch(() => {});
  send(res, 200, { aborted: true });
});

route('POST', /^\/api\/apps\/([^/]+)\/chat\/new$/, async (req, res, name) => {
  const a = await getAgent(name);
  if (a.streaming) return fail(res, 409, 'stop the current answer first');
  await a.command('new_session');
  send(res, 200, { started: true });
});

route('GET', /^\/api\/apps\/([^/]+)\/chat\/export$/, async (req, res, name) => {
  const a = await getAgent(name);
  const data = await a.command('get_messages');
  const md = transcriptMarkdown(name, data && data.messages);
  res.writeHead(200, baseHeaders({
    'Content-Type': 'text/markdown; charset=utf-8',
    'Content-Disposition': `attachment; filename="conversation-${name.replace(/"/g, '')}.md"`,
  }));
  res.end(md);
});

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://review.invalid');
    const p = url.pathname;
    if (req.method === 'GET' && STATIC[p]) {
      const [file, type] = STATIC[p];
      return send(res, 200, await fsp.readFile(path.join(STATIC_DIR, file)), type);
    }
    if (!p.startsWith('/api/')) return fail(res, 404, 'not found');
    if (!sameOrigin(req)) return fail(res, 403, 'cross-site request refused');
    if (isWrite(req) && (req.headers['x-review'] !== '1' || !String(req.headers['content-type'] || '').startsWith('application/json'))) {
      return fail(res, 403, 'missing request header');
    }
    for (const r of routes) {
      if (r.method !== req.method) continue;
      const m = p.match(r.re);
      if (!m) continue;
      const name = m[1] !== undefined ? decodeURIComponent(m[1]) : undefined;
      if (name !== undefined && !NAME_RE.test(name)) return fail(res, 400, 'bad application name');
      return await r.fn(req, res, name);
    }
    fail(res, 404, 'not found');
  } catch (e) {
    if (!res.headersSent) fail(res, 500, e.message === 'no such application' ? e.message : 'something went wrong');
    else res.end();
    console.error(e && e.stack || e);
  }
});

// Clean start: one server per container, socket readable by nginx on the host.
fs.mkdirSync(SOCK_DIR, { recursive: true });
try { fs.unlinkSync(SOCK); } catch { /* none */ }
try { fs.unlinkSync(path.join(SOCK_DIR, 'server.pid')); } catch { /* none */ }
try { fs.writeFileSync(path.join(SOCK_DIR, 'server.pid'), String(process.pid)); } catch (e) { console.error('no pid file:', e.code); }
fs.mkdirSync(WORK, { recursive: true, mode: 0o700 });
server.listen(SOCK, () => {
  fs.chmodSync(SOCK, 0o666);
  console.log(`review web listening on ${SOCK}`);
});
const shutdown = () => { for (const a of agents.values()) a.stop(); server.close(); process.exit(0); };
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

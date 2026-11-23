'use strict';
// Grant review page. Everything is built with textContent: no HTML from the server or the
// model is ever inserted as markup. Links in answers stay plain text, and images never load
// (the page's CSP also blocks any request to another site).

const $ = (id) => document.getElementById(id);
const state = { app: null, models: [], events: null, streaming: false, notesTimer: null, notesDirty: false };

async function api(path, opts) {
  const o = Object.assign({ headers: {} }, opts || {});
  if (o.body !== undefined) {
    o.headers['Content-Type'] = 'application/json';
    o.headers['X-Review'] = '1';
    o.body = JSON.stringify(o.body);
  }
  const r = await fetch(path, o);
  // Signed out (session expired or ended): reload, so the sign-in page takes over.
  if (r.status === 401) { location.reload(); return new Promise(() => {}); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || `request failed (${r.status})`);
  return data;
}

const enc = encodeURIComponent;
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function fmtSize(n) {
  return n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`;
}

// ---------- safe Markdown subset ----------

function inline(parent, text) {
  // **bold**, *italic*, `code`. Everything else (links, images, HTML) stays literal text.
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*)/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    const t = m[0];
    if (t.startsWith('**')) parent.appendChild(el('strong', null, t.slice(2, -2)));
    else if (t.startsWith('`')) parent.appendChild(el('code', null, t.slice(1, -1)));
    else parent.appendChild(el('em', null, t.slice(1, -1)));
    last = m.index + t.length;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
}

function renderMarkdown(container, src) {
  container.textContent = '';
  const lines = String(src || '').replace(/\r/g, '').split('\n');
  let i = 0, list = null, para = [];
  const flushPara = () => {
    if (para.length) { const p = el('p'); inline(p, para.join(' ')); container.appendChild(p); para = []; }
  };
  const endList = () => { list = null; };
  while (i < lines.length) {
    const line = lines[i];
    if (/^```/.test(line)) {
      flushPara(); endList();
      const code = []; i++;
      while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++]);
      i++;
      const pre = el('pre'); pre.appendChild(el('code', null, code.join('\n'))); container.appendChild(pre);
      continue;
    }
    let m;
    if ((m = line.match(/^(#{1,4})\s+(.*)$/))) {
      flushPara(); endList();
      const h = el(m[1].length <= 2 ? 'h3' : 'h4'); inline(h, m[2]); container.appendChild(h);
    } else if ((m = line.match(/^\s*(?:[-*•]|\d+[.)])\s+(.*)$/))) {
      flushPara();
      const ordered = /^\s*\d/.test(line);
      if (!list || list.ordered !== ordered) {
        list = el(ordered ? 'ol' : 'ul'); list.ordered = ordered; container.appendChild(list);
      }
      const li = el('li'); inline(li, m[1]); list.appendChild(li);
    } else if (/^\s*$/.test(line)) {
      flushPara(); endList();
    } else if (/^\s*>/.test(line)) {
      flushPara(); endList();
      const q = el('blockquote'); inline(q, line.replace(/^\s*>\s?/, '')); container.appendChild(q);
    } else {
      endList(); para.push(line.trim());
    }
    i++;
  }
  flushPara();
}

// ---------- applications ----------

async function loadApps() {
  const { apps } = await api('/api/apps');
  const ul = $('apps');
  ul.textContent = '';
  $('no-apps').hidden = apps.length > 0;
  for (const a of apps) {
    const li = el('li');
    const b = el('button', 'app');
    b.dataset.name = a.name;
    b.appendChild(el('span', 'app-name', a.name));
    const meta = el('span', 'app-meta', `${a.type.toUpperCase()} · ${fmtSize(a.size)}${a.hasNotes ? ' · notes' : ''}`);
    b.appendChild(meta);
    b.addEventListener('click', () => openApp(a));
    li.appendChild(b);
    ul.appendChild(li);
  }
  if (!state.app && apps.length) openApp(apps[0]);
}

async function openApp(a) {
  if (state.app && state.app.name === a.name) return;
  await flushNotes();
  if (state.events) { state.events.close(); state.events = null; }
  state.app = a;
  document.querySelectorAll('.app').forEach((b) => b.classList.toggle('active', b.dataset.name === a.name));

  $('doc-title').textContent = a.name;
  const dl = $('doc-download');
  dl.href = `/api/apps/${enc(a.name)}/download`; dl.hidden = false;
  $('doc-mode').hidden = !(a.type === 'pdf' || a.type === 'text');
  showDoc('original');

  $('export-chat').href = `/api/apps/${enc(a.name)}/chat/export`;
  $('export-chat').hidden = false;
  $('notes-download').href = `/api/apps/${enc(a.name)}/notes/download`;
  await Promise.all([loadNotes(), loadChat()]);
}

function showDoc(mode) {
  const a = state.app;
  if (!a) return;
  $('mode-original').classList.toggle('active', mode === 'original');
  $('mode-text').classList.toggle('active', mode === 'text');
  const view = $('doc-view');
  view.textContent = '';
  if (mode === 'text') {
    const pre = el('pre', 'doc-text', 'Extracting text…');
    view.appendChild(pre);
    api(`/api/apps/${enc(a.name)}/text`)
      .then((r) => { if (state.app === a) pre.textContent = r.text === null ? 'No text could be extracted from this file.' : r.text; })
      .catch((e) => { pre.textContent = `Couldn’t extract text: ${e.message}`; });
  } else if (a.type === 'pdf' || a.type === 'text') {
    const f = el('iframe');
    f.title = a.name;
    f.src = `/api/apps/${enc(a.name)}/original`;
    view.appendChild(f);
  } else {
    const ph = el('div', 'placeholder');
    ph.appendChild(el('p', null, 'This file type can’t be shown here. Download it to read it.'));
    view.appendChild(ph);
  }
}

// ---------- assistant ----------

function setBusy(busy) {
  state.streaming = busy;
  $('send').disabled = busy || !state.app;
  $('prompt').disabled = !state.app;
  $('stop').hidden = !busy;
  $('new-chat').disabled = busy || !state.app;
  if (!busy) setStatus('');
}
function setStatus(text) { $('status').textContent = text; $('status').hidden = !text; }

function addMessage(role, text, tools, error) {
  const box = $('messages');
  const m = el('div', `msg ${role}${error ? ' error' : ''}`);
  m.appendChild(el('div', 'who', role === 'user' ? 'You' : 'Assistant'));
  if (tools && tools.length) {
    const t = el('div', 'tools');
    for (const x of tools) t.appendChild(el('div', 'tool', `${toolVerb(x.name)} ${x.detail || ''}`.trim()));
    m.appendChild(t);
  }
  const body = el('div', 'body');
  if (role === 'user') body.textContent = text; else renderMarkdown(body, text);
  m.appendChild(body);
  box.appendChild(m);
  box.scrollTop = box.scrollHeight;
  return { m, body };
}
function toolVerb(name) {
  return ({ read: 'Read', grep: 'Searched', find: 'Looked for files in', ls: 'Listed', write: 'Wrote', edit: 'Edited' })[name] || name;
}

async function loadChat() {
  const box = $('messages');
  box.textContent = '';
  box.appendChild(el('p', 'muted center', 'Starting the assistant…'));
  $('send').disabled = true; $('prompt').disabled = true; $('new-chat').disabled = true;
  try {
    const h = await api(`/api/apps/${enc(state.app.name)}/chat/history`);
    box.textContent = '';
    if (!h.messages.length) {
      box.appendChild(el('p', 'muted center', `Ask anything about ${state.app.name}: its aims, methods, budget, risks, or how it meets the criteria.`));
    }
    for (const m of h.messages) addMessage(m.role, m.text, m.tools, m.error);
    if (h.model) $('model').value = h.model;
    connectEvents();
    setBusy(!!h.streaming);
  } catch (e) {
    box.textContent = '';
    box.appendChild(el('p', 'error-text', `The assistant couldn’t start: ${e.message}`));
    setBusy(false);
  }
}

let current = null; // the assistant message being streamed
function connectEvents() {
  const es = new EventSource(`/api/apps/${enc(state.app.name)}/chat/events`);
  state.events = es;
  es.onmessage = (ev) => {
    let d; try { d = JSON.parse(ev.data); } catch { return; }
    if (d.t === 'start') {
      setBusy(true);
      current = addMessage('assistant', '', []);
      current.text = '';
      current.toolsBox = null;
      setStatus('Thinking…');
    } else if (d.t === 'delta' && current) {
      current.text += d.text;
      renderMarkdown(current.body, current.text);
      $('messages').scrollTop = $('messages').scrollHeight;
      setStatus('');
    } else if (d.t === 'tool' && current) {
      if (!current.toolsBox) { current.toolsBox = el('div', 'tools'); current.m.insertBefore(current.toolsBox, current.body); }
      current.toolsBox.appendChild(el('div', 'tool', `${toolVerb(d.name)} ${d.detail || ''}`.trim()));
      setStatus(`${toolVerb(d.name)} ${d.detail || ''}…`);
    } else if (d.t === 'thinking') {
      setStatus('Thinking…');
    } else if (d.t === 'status') {
      setStatus(d.text);
    } else if (d.t === 'error') {
      addMessage('assistant', d.text, [], true);
    } else if (d.t === 'end') {
      if (current && !current.text && !current.toolsBox) current.m.remove();
      current = null;
      setBusy(false);
    }
  };
}

async function ask(e) {
  e.preventDefault();
  const text = $('prompt').value.trim();
  if (!text || !state.app || state.streaming) return;
  const placeholder = $('messages').querySelector('.muted.center');
  if (placeholder) placeholder.remove();
  addMessage('user', text);
  $('prompt').value = '';
  setBusy(true);
  setStatus('Sending…');
  try {
    await api(`/api/apps/${enc(state.app.name)}/chat/prompt`, { method: 'POST', body: { message: text, model: $('model').value } });
  } catch (err) {
    addMessage('assistant', `Couldn’t send: ${err.message}`, [], true);
    setBusy(false);
  }
}

// ---------- notes ----------

async function loadNotes() {
  const n = $('notes');
  n.disabled = true;
  const { text } = await api(`/api/apps/${enc(state.app.name)}/notes`);
  n.value = text;
  n.disabled = false;
  state.notesDirty = false;
  $('notes-download').hidden = !text;
  $('notes-state').textContent = 'Notes save automatically.';
}
async function flushNotes() {
  if (!state.notesDirty || !state.app) return;
  clearTimeout(state.notesTimer);
  state.notesDirty = false;
  try {
    await api(`/api/apps/${enc(state.app.name)}/notes`, { method: 'PUT', body: { text: $('notes').value } });
    $('notes-state').textContent = `Saved ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    $('notes-download').hidden = !$('notes').value;
  } catch (e) {
    state.notesDirty = true;
    $('notes-state').textContent = `Not saved: ${e.message}`;
  }
}

// ---------- wiring ----------

function showTab(which) {
  const chat = which === 'chat';
  $('tab-chat').classList.toggle('active', chat); $('tab-chat').setAttribute('aria-selected', chat);
  $('tab-notes').classList.toggle('active', !chat); $('tab-notes').setAttribute('aria-selected', !chat);
  $('panel-chat').hidden = !chat; $('panel-notes').hidden = chat;
}

document.addEventListener('DOMContentLoaded', async () => {
  $('ask').addEventListener('submit', ask);
  $('prompt').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); $('ask').requestSubmit(); }
  });
  $('stop').addEventListener('click', () => state.app && api(`/api/apps/${enc(state.app.name)}/chat/abort`, { method: 'POST', body: {} }).catch(() => {}));
  $('new-chat').addEventListener('click', async () => {
    if (!state.app) return;
    try {
      await api(`/api/apps/${enc(state.app.name)}/chat/new`, { method: 'POST', body: {} });
      $('messages').textContent = '';
      $('messages').appendChild(el('p', 'muted center', 'New conversation started.'));
    } catch (e) { setStatus(e.message); }
  });
  $('mode-original').addEventListener('click', () => showDoc('original'));
  $('mode-text').addEventListener('click', () => showDoc('text'));
  $('tab-chat').addEventListener('click', () => showTab('chat'));
  $('tab-notes').addEventListener('click', () => showTab('notes'));
  $('notes').addEventListener('input', () => {
    state.notesDirty = true;
    $('notes-state').textContent = 'Saving…';
    clearTimeout(state.notesTimer);
    state.notesTimer = setTimeout(flushNotes, 800);
  });
  window.addEventListener('beforeunload', () => { if (state.notesDirty) flushNotes(); });

  try {
    const s = await api('/api/session');
    state.models = s.models;
    for (const m of s.models) { const o = el('option', null, m.name); o.value = m.id; $('model').appendChild(o); }
    await loadApps();
  } catch (e) {
    $('apps').appendChild(el('li', 'error-text', `Couldn’t load your applications: ${e.message}`));
  }
});

// Shared AI route with layered backups: several Gemini models, retries, then an optional Anthropic key.
// Env: GEMINI_KEY (required unless ANTHROPIC_KEY set), ANTHROPIC_KEY (optional backup provider).
// Static fallbacks, used only if the live model list cannot be fetched.
const FALLBACK_MODELS = ['gemini-3.8-flash', 'gemini-3-flash', 'gemini-flash-latest', 'gemini-2.5-flash'];
let _cache = { t: 0, list: null };
const _bad = {}; let _good = null;
async function modelList(key) {
  if (_cache.list && Date.now() - _cache.t < 10 * 60 * 1000) return _cache.list;
  try {
    const r = await withTimeout('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200&key=' + key, {}, 3500);
    const d = await r.json();
    const names = (d.models || [])
      .filter((m) => (m.supportedGenerationMethods || []).includes('generateContent'))
      .map((m) => String(m.name || '').replace('models/', ''))
      .filter((n) => /^gemini-[\d.]+-flash(-lite)?$/.test(n));
    const ver = (n) => parseFloat((n.match(/gemini-([\d.]+)/) || [0, 0])[1]);
    names.sort((x, y) => ver(y) - ver(x) || (x.includes('lite') ? 1 : 0) - (y.includes('lite') ? 1 : 0));
    if (names.length) { _cache = { t: Date.now(), list: names.slice(0, 3).concat(FALLBACK_MODELS.filter((f) => !names.includes(f))) }; return _cache.list; }
  } catch (e) {}
  return FALLBACK_MODELS;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function withTimeout(url, opts, ms) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ms);
  try { return await fetch(url, { ...opts, signal: c.signal }); } finally { clearTimeout(t); }
}
async function gemini(model, key, prompt, maxTokens, budgetMs) {
  const is25 = /2\.5/.test(model);
  const call = async (think) => {
    const gen = { maxOutputTokens: is25 ? maxTokens : Math.max(maxTokens, 800), temperature: 0.7 };
    if (think) gen.thinkingConfig = { thinkingBudget: 0 };
    const r = await withTimeout(
      'https://generativelanguage.googleapis.com/v1beta/models/' + model + ':generateContent?key=' + key,
      { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: gen }) },
      budgetMs
    );
    const d = await r.json();
    if (d.error) throw new Error(d.error.message || 'gemini error');
    const text = (d.candidates && d.candidates[0] && d.candidates[0].content && d.candidates[0].content.parts || [])
      .map((p) => p.text || '').join('');
    if (!text.trim()) throw new Error('empty reply');
    return text;
  };
  try { return await call(true); }
  catch (e) { if (/think/i.test((e && e.message) || '')) return await call(false); throw e; }
}
async function anthropic(key, prompt, maxTokens) {
  const r = await withTimeout('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: maxTokens, messages: [{ role: 'user', content: prompt }] })
  }, 25000);
  const d = await r.json();
  if (d.error) throw new Error(d.error.message || 'anthropic error');
  const text = (d.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('');
  if (!text.trim()) throw new Error('empty reply');
  return text;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.status(200).end(); return; }
  const gk = process.env.GEMINI_KEY, ak = process.env.ANTHROPIC_KEY;
  if (req.method === 'GET') { res.status(200).json({ ok: !!(gk || ak), providers: [gk ? 'gemini' : null, ak ? 'anthropic' : null].filter(Boolean) }); return; }
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  if (!gk && !ak) { res.status(500).json({ error: 'Server has no AI key configured' }); return; }

  let body = {};
  try { body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {}); } catch (e) {}
  const prompt = body.prompt;
  const maxTokens = Math.min(Math.max(parseInt(body.maxTokens) || 1000, 300), 4096);
  if (!prompt || typeof prompt !== 'string') { res.status(400).json({ error: 'Missing prompt' }); return; }

  const errors = [];
  const t0 = Date.now(), DEADLINE = 24000;
  if (gk) {
    let models = await modelList(gk);
    const fresh = models.filter((m) => !(_bad[m] && Date.now() - _bad[m] < 300000));
    models = (fresh.length ? fresh : models).slice().sort((a, b) => (b === _good) - (a === _good));
    for (const m of models) {
      const left = DEADLINE - (Date.now() - t0);
      if (left < 2500) { errors.push('out of time'); break; }
      try { const text = await gemini(m, gk, prompt, maxTokens, Math.min(9000, left)); _good = m; res.status(200).json({ text, via: m }); return; }
      catch (e) {
        _bad[m] = Date.now();
        const msg = (e && e.name === 'AbortError') ? 'timeout' : ((e && e.message) || 'failed');
        errors.push(m + ': ' + msg);
        if (/no longer available|not found|not supported|invalid argument/i.test(msg)) { _cache = { t: 0, list: null }; }
      }
    }
  }
  if (ak && Date.now() - t0 < DEADLINE) {
    try { const text = await anthropic(ak, prompt, maxTokens); res.status(200).json({ text, via: 'anthropic' }); return; }
    catch (e) { errors.push('anthropic: ' + ((e && e.message) || 'failed')); }
  }
  res.status(502).json({ error: errors.slice(-2).join(' | ').slice(0, 300) || 'AI request failed' });
}

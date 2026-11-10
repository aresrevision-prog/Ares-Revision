// Shared AI route with layered backups: several Gemini models, retries, then an optional Anthropic key.
// Env: GEMINI_KEY (required unless ANTHROPIC_KEY set), ANTHROPIC_KEY (optional backup provider).
const GEMINI_MODELS = [
  { id: 'gemini-2.5-flash', think: true },
  { id: 'gemini-2.5-flash-lite', think: true },
  { id: 'gemini-2.0-flash', think: false }
];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function withTimeout(url, opts, ms) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ms);
  try { return await fetch(url, { ...opts, signal: c.signal }); } finally { clearTimeout(t); }
}
async function gemini(model, key, prompt, maxTokens) {
  const gen = { maxOutputTokens: maxTokens, temperature: 0.7 };
  if (model.think) gen.thinkingConfig = { thinkingBudget: 0 };
  const r = await withTimeout(
    'https://generativelanguage.googleapis.com/v1beta/models/' + model.id + ':generateContent?key=' + key,
    { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }] }], generationConfig: gen }) },
    20000
  );
  const d = await r.json();
  if (d.error) throw new Error(d.error.message || 'gemini error');
  const text = (d.candidates && d.candidates[0] && d.candidates[0].content && d.candidates[0].content.parts || [])
    .map((p) => p.text || '').join('');
  if (!text.trim()) throw new Error('empty reply');
  return text;
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
  if (gk) {
    for (const m of GEMINI_MODELS) {
      for (let a = 0; a < 2; a++) {
        try { const text = await gemini(m, gk, prompt, maxTokens); res.status(200).json({ text, via: m.id }); return; }
        catch (e) { errors.push(m.id + ': ' + ((e && e.message) || 'failed')); await sleep(300); }
      }
    }
  }
  if (ak) {
    try { const text = await anthropic(ak, prompt, maxTokens); res.status(200).json({ text, via: 'anthropic' }); return; }
    catch (e) { errors.push('anthropic: ' + ((e && e.message) || 'failed')); }
  }
  res.status(502).json({ error: errors.slice(-2).join(' | ').slice(0, 300) || 'AI request failed' });
}

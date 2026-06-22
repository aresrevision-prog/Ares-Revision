export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.status(200).end(); return; }
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }

  const key = process.env.GEMINI_KEY;
  if (!key) { res.status(500).json({ error: 'Server is missing GEMINI_KEY' }); return; }

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const prompt = body.prompt;
    const maxTokens = Math.min(Math.max(parseInt(body.maxTokens) || 1000, 1), 4096);
    if (!prompt || typeof prompt !== 'string') { res.status(400).json({ error: 'Missing prompt' }); return; }

    const r = await fetch(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=' + key,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: prompt }] }],
          generationConfig: { maxOutputTokens: maxTokens, temperature: 0.7 }
        })
      }
    );
    const data = await r.json();
    if (data.error) { res.status(502).json({ error: data.error.message || 'AI request failed' }); return; }

    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
    res.status(200).json({ text });
  } catch (e) {
    res.status(500).json({ error: (e && e.message) || 'Unexpected error' });
  }
}

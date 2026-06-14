// Vercel serverless function: POST /api/ai
// Proxy ke Google Gemini. Key dibaca dari Environment Variable GEMINI_KEY (aman, tidak di repo).

const MODELS = ['gemini-2.5-flash', 'gemini-flash-latest'];

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const key = process.env.GEMINI_KEY;
  if (!key) {
    res.status(403).json({ error: 'GEMINI_KEY belum diset. Tambahkan di Vercel: Settings > Environment Variables.' });
    return;
  }

  // Ambil body (Vercel biasanya sudah parse JSON, tapi jaga-jaga kalau string)
  let body = req.body;
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { body = {}; }
  }
  const messages = (body && body.messages) || [];
  const userText = messages.map((m) => m.content).join('\n');

  const payload = JSON.stringify({
    contents: [{ parts: [{ text: userText }] }],
    generationConfig: { maxOutputTokens: 1500, temperature: 0.4 },
  });

  let lastErr = 'unknown';

  // Coba tiap model, dengan retry untuk error sementara (429/500/503)
  for (const model of MODELS) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const r = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: payload,
        });

        if (r.ok) {
          const data = await r.json();
          const text = data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
          res.status(200).json({ content: [{ text }] });
          return;
        }

        const errText = await r.text();
        lastErr = errText;

        if ([429, 500, 503].includes(r.status)) {
          await sleep(500 * attempt); // retry
          continue;
        }

        // Error permanen (mis. key salah) -> langsung kembalikan
        let parsed;
        try { parsed = JSON.parse(errText); } catch { parsed = { message: errText }; }
        res.status(r.status).json({ error: parsed.error || parsed.message || errText });
        return;
      } catch (e) {
        lastErr = e.message;
        await sleep(500 * attempt);
      }
    }
  }

  res.status(503).json({ error: 'Gemini sedang sibuk, coba lagi sebentar. (' + lastErr + ')' });
};

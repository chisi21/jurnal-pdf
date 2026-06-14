// Vercel serverless: POST /api/search
// Mencari jurnal dari Semantic Scholar, CORE, arXiv di sisi server (hindari CORS + rate limit browser).

const SEM_FIELDS = 'title,year,abstract,openAccessPdf,authors,citationCount,externalIds';
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function fetchSemantic(q, limit) {
  const url = `https://api.semanticscholar.org/graph/v1/paper/search?query=${encodeURIComponent(q)}&fields=${SEM_FIELDS}&limit=${limit}`;
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const r = await fetch(url);
      if (r.status === 429) { await sleep(1200 * attempt); continue; }
      if (!r.ok) return [];
      const d = await r.json();
      return (d.data || []).map((p) => ({
        source: 'Semantic Scholar',
        title: p.title || '(tanpa judul)',
        year: p.year || '—',
        authors: (p.authors || []).slice(0, 3).map((a) => a.name).join(', '),
        abstract: p.abstract || '',
        pdfUrl: (p.openAccessPdf && p.openAccessPdf.url) || null,
        pageUrl: p.externalIds && p.externalIds.DOI
          ? `https://doi.org/${p.externalIds.DOI}`
          : `https://www.semanticscholar.org/paper/${p.paperId}`,
        citations: p.citationCount != null ? p.citationCount : null,
      }));
    } catch (e) { await sleep(800 * attempt); }
  }
  return [];
}

async function fetchCORE(q, limit, mode) {
  try {
    const query = mode === 'indonesia' ? `${q} language:Indonesian` : q;
    const r = await fetch(`https://api.core.ac.uk/v3/search/works?q=${encodeURIComponent(query)}&limit=${limit}`);
    if (!r.ok) return [];
    const d = await r.json();
    return (d.results || []).map((p) => ({
      source: 'CORE',
      title: p.title || '(tanpa judul)',
      year: p.yearPublished || '—',
      authors: (p.authors || []).slice(0, 3).map((a) => a.name).join(', '),
      abstract: p.abstract || '',
      pdfUrl: p.downloadUrl || ((p.links || []).find((l) => l.type === 'download') || {}).url || null,
      pageUrl: (p.sourceFulltextUrls && p.sourceFulltextUrls[0]) || `https://core.ac.uk/works/${p.id}`,
      citations: null,
    }));
  } catch (e) { return []; }
}

async function fetchArxiv(q, limit) {
  try {
    const r = await fetch(`https://export.arxiv.org/api/query?search_query=all:${encodeURIComponent(q)}&start=0&max_results=${limit}`);
    if (!r.ok) return [];
    const xml = await r.text();
    const blocks = xml.split('<entry>').slice(1);
    return blocks.map((block) => {
      const get = (tag) => {
        const m = block.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`));
        return m ? m[1].replace(/\s+/g, ' ').trim() : '';
      };
      const id = get('id').replace(/https?:\/\/arxiv\.org\/abs\//, '');
      const pub = get('published');
      const names = [...block.matchAll(/<name>([\s\S]*?)<\/name>/g)].map((m) => m[1].trim()).slice(0, 3);
      return {
        source: 'arXiv',
        title: get('title') || '(tanpa judul)',
        year: pub ? new Date(pub).getFullYear() : '—',
        authors: names.join(', '),
        abstract: get('summary'),
        pdfUrl: `https://arxiv.org/pdf/${id}`,
        pageUrl: `https://arxiv.org/abs/${id}`,
        citations: null,
      };
    });
  } catch (e) { return []; }
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'Method not allowed' }); return; }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
  body = body || {};

  const topics = (body.topics || []).slice(0, 2);
  const category = body.category || 'mixed';
  const sources = new Set(body.sources || ['semantic', 'core', 'arxiv']);
  const limit = Math.min(Math.max(parseInt(body.limit) || 20, 5), 30);
  const perTopic = Math.max(6, Math.floor(limit / Math.max(1, topics.length)));

  const semQueries = [];
  const parallelTasks = [];
  topics.forEach((t) => {
    const q = t.query;            // query Bahasa Inggris
    const qId = t.queryId || q;   // query Bahasa Indonesia
    if (!q && !qId) return;
    if (category === 'indonesia') {
      if (sources.has('semantic')) semQueries.push([qId, perTopic]);
      if (sources.has('core')) parallelTasks.push(fetchCORE(qId, perTopic, 'international'));
    } else if (category === 'international') {
      if (sources.has('semantic')) semQueries.push([q, perTopic]);
      if (sources.has('core')) parallelTasks.push(fetchCORE(q, perTopic, 'international'));
      if (sources.has('arxiv')) parallelTasks.push(fetchArxiv(q, perTopic));
    } else {
      // campuran: Inggris + Indonesia
      if (sources.has('semantic')) semQueries.push([q, perTopic]);
      if (sources.has('core')) {
        parallelTasks.push(fetchCORE(q, perTopic, 'international'));
        if (qId !== q) parallelTasks.push(fetchCORE(qId, perTopic, 'international'));
      }
      if (sources.has('arxiv')) parallelTasks.push(fetchArxiv(q, perTopic));
    }
  });

  // CORE + arXiv jalan paralel; Semantic Scholar berurutan (hindari 429)
  const parallelPromise = Promise.all(parallelTasks);
  const semResults = [];
  for (const [q, n] of semQueries) {
    const r = await fetchSemantic(q, n);
    semResults.push(...r);
    await sleep(300);
  }
  const groups = await parallelPromise;
  let all = semResults.concat(...groups);

  // Deduplikasi berdasarkan judul
  const seen = new Set();
  all = all.filter((r) => {
    const k = (r.title || '').toLowerCase().replace(/\s+/g, ' ').trim();
    if (!k || seen.has(k)) return false;
    seen.add(k);
    return true;
  });

  // Urutkan: yang ada PDF dulu, lalu tahun terbaru
  all.sort((a, b) => {
    if (!!a.pdfUrl !== !!b.pdfUrl) return a.pdfUrl ? -1 : 1;
    return (b.year || 0) - (a.year || 0);
  });

  res.status(200).json({ results: all });
};

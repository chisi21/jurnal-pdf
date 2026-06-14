// Vercel serverless function: GET /api/status
// Memberi tahu frontend apakah GEMINI_KEY sudah diset (tanpa membocorkan keynya)
module.exports = (req, res) => {
  res.status(200).json({ aiReady: !!process.env.GEMINI_KEY });
};

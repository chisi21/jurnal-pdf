# 📚 Jurnal PDF Finder

Tools pencari jurnal & paper ilmiah sederhana. Cukup ketik prompt natural (Bahasa Indonesia santai pun bisa), lalu hasilnya langsung berupa link **PDF** siap unduh — lengkap dengan judul, tahun, penulis, dan abstrak.

Ditenagai **Google Gemini** untuk memahami maksud pencarianmu, dan mencari dari 3 sumber open access: **Semantic Scholar**, **CORE**, dan **arXiv**.

## ✨ Fitur

- 💭 **Prompt natural** — gak perlu kata kunci spesifik, cerita biasa juga dimengerti
- 🤖 **AI (Gemini)** — memahami maksud, mengoptimalkan query, dan menganalisis hasil
- 📄 **Link PDF langsung** — tombol unduh PDF di tiap hasil
- 🗂️ **3 kategori** — Campuran / Indonesia / International
- 🔎 **Filter** — pilih sumber, jumlah hasil, dan "PDF saja"

## 🚀 Cara Pakai

Butuh **Windows** (pakai PowerShell bawaan, tanpa instalasi apa pun).

1. **Dapatkan API key Gemini gratis** di [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
2. Salin `config.example.json` menjadi `config.json`, lalu isi key-mu:
   ```json
   {
     "geminiKey": "API_KEY_KAMU"
   }
   ```
3. Jalankan server: klik kanan `server.ps1` → **Run with PowerShell**
   (atau lewat terminal: `powershell -ExecutionPolicy Bypass -File server.ps1`)
4. Browser akan otomatis terbuka di `http://localhost:8080`

> Tanpa API key pun tetap bisa dipakai — hanya saja pemahaman prompt jadi lebih sederhana (ekstraksi kata kunci biasa).

## 🔒 Keamanan

API key disimpan **hanya** di `config.json` lokal kamu. File itu sudah masuk `.gitignore` agar **tidak pernah ter-upload** ke repository.

## 🧩 Teknologi

- Frontend: HTML + CSS + JavaScript (tanpa framework)
- Server: PowerShell `HttpListener` (proxy ke Gemini agar key aman)
- Data: Semantic Scholar API, CORE API, arXiv API

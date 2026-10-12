// GemmaFind homepage — interactive demo driven by real EmbeddingGemma 2 results (data/demo.json).

const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ---------- Nav shadow + clock ---------- */
const nav = $("#nav");
addEventListener("scroll", () => nav.classList.toggle("is-scrolled", scrollY > 8), { passive: true });
const clock = $("#menubar-clock");
const tick = () => {
  clock.textContent = new Date().toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" });
};
tick(); setInterval(tick, 30_000);

/* ---------- Reveal on scroll ---------- */
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
}, { rootMargin: "0px 0px -8% 0px" });
document.querySelectorAll(".reveal").forEach((el) => io.observe(el));

/* ---------- Copy install command ---------- */
$("#copy-install")?.addEventListener("click", async (e) => {
  const text = [...$("#install-cmd").childNodes].map((n) => (n.classList?.contains("p") || n.classList?.contains("c") ? "" : n.textContent)).join("")
    .split("\n").map((l) => l.trim()).filter(Boolean).join("\n");
  try { await navigator.clipboard.writeText(text); e.target.textContent = "Copied ✓"; } catch { e.target.textContent = "Select & copy"; }
  setTimeout(() => (e.target.textContent = "Copy"), 1800);
});

/* ---------- Demo ---------- */
const IMAGES = { "IMG_0420.jpg": "/img/IMG_0420.webp", "IMG_0431.jpg": "/img/IMG_0431.webp", "IMG_0413.jpg": "/img/IMG_0413.webp", "IMG_0412.jpg": "/img/IMG_0412.webp" };
const VIDEO_THUMBS = { "weekend.mp4": "/img/weekend-0.webp" };
const AUDIO_TRANSCRIPTS = {
  "voice-memo-1.m4a": "“Reminder for tomorrow. Pick up the dry cleaning, buy birthday candles and a chocolate cake for Emma's party…”",
  "voice-memo-2.m4a": "“Quarterly earnings update. Revenue grew twelve percent year over year…”",
  "weekend.mp4": "“Here is our dog playing in the garden. And later we made pizza margherita for dinner.”",
};
const KIND_LABEL = { text: "Text & Code", pdf: "PDF", richText: "Documents", image: "Images", video: "Videos", audio: "Audio" };
const EXT = (name) => name.split(".").pop().toUpperCase().slice(0, 4);
const ts = (t) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`;
const CODE_EXT = new Set(["swift", "py", "js", "ts", "go", "rs", "c", "cpp", "java", "kt", "rb"]);

const els = { query: $("#demo-query"), timing: $("#demo-timing"), results: $("#demo-results"), preview: $("#demo-preview"), tries: $("#demo-tries") };
let data = [];
let current = null;
let selected = 0;
let typingTimer = null;
let autoplay = true;
let autoplayTimer = null;

function setQueryText(text, caret = true) {
  els.query.innerHTML = text ? esc(text) + (caret ? '<span class="caret"></span>' : "") : '<span class="placeholder">Search anything — files, photos, videos, voice memos…</span>';
}

function dots(score) {
  const n = Math.max(1, Math.min(5, Math.floor((score - 1) / 1.2) + 1));
  return `<span class="dots" aria-label="${n} of 5 relevance">${[0, 1, 2, 3, 4].map((i) => `<i class="${i < n ? "on" : ""}"></i>`).join("")}</span>`;
}

function snippet(r) {
  if (r.modality === "text") {
    const s = (r.text || "").slice(r.passage?.[0] ?? 0, (r.passage?.[0] ?? 0) + 180).replace(/\s+/g, " ").trim();
    return (r.page ? `p.${r.page} · ` : "") + s;
  }
  if (r.modality === "image") return "Image match";
  const more = (r.times || []).slice(1, 4).map(ts);
  const label = r.modality === "audio" ? "Sound" : "Scene";
  return `${label} at ${ts(r.time || 0)}` + (more.length ? ` · also ${more.join(", ")}` : "");
}

function icon(r) {
  const img = IMAGES[r.name] || VIDEO_THUMBS[r.name];
  return img ? `<img src="${img}" alt="">` : EXT(r.name);
}

function renderResults() {
  const rs = current.results;
  els.results.innerHTML = rs.map((r, i) => `
    <button class="result ${i === selected ? "is-selected" : ""}" role="option" aria-selected="${i === selected}" data-i="${i}" id="demo-result-${i}" style="--i:${i}">
      <span class="result__icon">${icon(r)}</span>
      <span style="min-width:0">
        <div class="result__name">${esc(r.name)}${r.keyword ? ' <small style="opacity:.6;font-weight:500">Abc</small>' : ""}</div>
        <div class="result__snippet">${esc(snippet(r))}</div>
        <div class="result__path">${esc(r.folder)}</div>
      </span>
      ${dots(r.score)}
    </button>`).join("");
  els.results.querySelectorAll(".result").forEach((b) => b.addEventListener("click", () => { stopAutoplay(); select(+b.dataset.i); }));
}

/** Builds highlighted HTML: passage (soft), best sentences (<mark>), query terms (underline). */
function highlight(text, passage, sentences, terms) {
  const len = text.length;
  const marks = new Array(len + 1).fill(0); // bit 1 passage, 2 sentence, 4 term
  const paint = ([s, l], bit) => { for (let i = Math.max(0, s); i < Math.min(len, s + l); i++) marks[i] |= bit; };
  if (passage) paint(passage, 1);
  (sentences || []).forEach((r) => paint(r, 2));
  (terms || []).forEach((r) => paint(r, 4));
  let out = "", i = 0;
  while (i < len) {
    const m = marks[i];
    let j = i;
    while (j < len && marks[j] === m) j++;
    let chunk = esc(text.slice(i, j));
    if (m & 4) chunk = `<span class="term">${chunk}</span>`;
    if (m & 2) chunk = `<mark>${chunk}</mark>`;
    if (m & 1 && !(m & 2)) chunk = `<span class="passage">${chunk}</span>`;
    out += chunk;
    i = j;
  }
  return out;
}

function renderPreview() {
  const r = current.results[selected];
  if (!r) { els.preview.innerHTML = ""; return; }
  const meta = KIND_LABEL[r.kind] || r.kind;
  let body = "";
  if (r.modality === "text") {
    const isCode = CODE_EXT.has(r.name.split(".").pop());
    const html = highlight(r.text, r.passage, r.sentences, r.terms);
    body = r.kind === "pdf"
      ? `<div class="pdfpage"><div class="doc">${html}</div></div>`
      : `<div class="doc ${isCode ? "doc--code" : ""}">${html}</div>`;
  } else if (r.modality === "image") {
    body = `<div class="preview__media"><img src="${IMAGES[r.name]}" alt="${esc(r.name)}"></div>`;
  } else if (r.kind === "video") {
    const times = r.times?.length ? r.times : [r.time || 0];
    body = `<div class="preview__media">
      <video id="demo-video" src="/img/weekend.mp4#t=${r.time || 0}" controls muted playsinline preload="metadata" poster="${r.time > 15 ? "/img/weekend-21.webp" : "/img/weekend-0.webp"}"></video>
      <div class="moments">Matching moments: ${times.map((t, k) => `<button class="moment ${k === 0 ? "is-best" : ""}" data-t="${t}">${r.modality === "audio" && k === 0 ? "🔊 " : "🎞 "}${ts(t)}${r.modality === "audio" && k === 0 ? " narration" : " scene"}</button>`).join("")}</div>
      ${r.modality === "audio" ? `<p class="audio-quote">${esc(AUDIO_TRANSCRIPTS[r.name] || "")}</p>` : ""}
    </div>`;
  } else {
    body = `<div class="preview__media">
      <div class="wave" aria-hidden="true">${Array.from({ length: 28 }, (_, k) => `<i style="--d:${((k * 37) % 100) / 100}"></i>`).join("")}</div>
      <div class="moments"><button class="moment is-best">🔊 ${ts(r.time || 0)}–${ts((r.time || 0) + (r.duration || 0))} sound</button></div>
      <p class="audio-quote">${esc(AUDIO_TRANSCRIPTS[r.name] || "")}</p>
    </div>`;
  }
  els.preview.innerHTML = `
    <div class="preview__head">
      <span class="result__icon" style="width:30px;height:30px">${icon(r)}</span>
      <div><strong>${esc(r.name)}</strong><span>${meta}${r.page ? ` · page ${r.page}` : ""} · similarity ${r.similarity.toFixed(3)}</span></div>
    </div>
    <div class="preview__content" id="demo-preview-content">${body}</div>`;

  const video = $("#demo-video", els.preview);
  els.preview.querySelectorAll(".moment[data-t]").forEach((b) => b.addEventListener("click", () => {
    stopAutoplay();
    if (video) { video.currentTime = +b.dataset.t; video.play().catch(() => {}); }
  }));
  // Scroll the strongest highlight into view.
  const target = els.preview.querySelector("mark") || els.preview.querySelector(".passage");
  const box = $("#demo-preview-content", els.preview);
  if (target && box) {
    requestAnimationFrame(() => {
      const off = target.offsetTop - box.clientHeight / 2 + target.offsetHeight / 2;
      box.scrollTop = Math.max(0, off);
    });
  }
}

function select(i) {
  selected = Math.max(0, Math.min(current.results.length - 1, i));
  els.results.querySelectorAll(".result").forEach((b, k) => { b.classList.toggle("is-selected", k === selected); b.setAttribute("aria-selected", k === selected); });
  renderPreview();
}

function run(entry, { type = true } = {}) {
  clearTimeout(typingTimer);
  els.tries.querySelectorAll(".try").forEach((b) => b.classList.toggle("is-active", b.dataset.q === entry.query));
  const show = () => {
    current = entry; selected = 0;
    els.results.classList.remove("is-stale"); els.preview.classList.remove("is-stale");
    els.timing.textContent = `${entry.results.length} result${entry.results.length === 1 ? "" : "s"} · ${Math.max(entry.ms, 12)} ms`;
    renderResults(); renderPreview();
  };
  if (!type || reduceMotion) { setQueryText(entry.query); show(); return; }
  els.timing.textContent = "";
  if (current) { els.results.classList.add("is-stale"); els.preview.classList.add("is-stale"); }
  let k = 0;
  const step = () => {
    setQueryText(entry.query.slice(0, ++k));
    if (k < entry.query.length) typingTimer = setTimeout(step, 38 + Math.random() * 45);
    else typingTimer = setTimeout(show, 260);
  };
  step();
}

function stopAutoplay() { autoplay = false; clearTimeout(autoplayTimer); }

function scheduleAutoplay(index) {
  if (!autoplay) return;
  autoplayTimer = setTimeout(() => {
    if (!autoplay) return;
    const next = (index + 1) % data.length;
    run(data[next]);
    scheduleAutoplay(next);
  }, 6200);
}

async function initDemo() {
  try {
    data = await (await fetch("/data/demo.json")).json();
  } catch { return; }
  for (const entry of data) {
    const b = document.createElement("button");
    b.className = "try"; b.type = "button"; b.dataset.q = entry.query; b.textContent = entry.query;
    b.id = "try-" + entry.query.replace(/\W+/g, "-");
    b.addEventListener("click", () => { stopAutoplay(); run(entry); });
    els.tries.appendChild(b);
  }
  // Start once the demo is on screen.
  const start = new IntersectionObserver((es) => {
    if (es.some((e) => e.isIntersecting)) { start.disconnect(); run(data[0]); scheduleAutoplay(0); }
  }, { threshold: 0.25 });
  start.observe($("#panel"));

  // Keyboard: ↑/↓ inside the demo once the user interacts.
  $("#panel").addEventListener("keydown", (e) => {
    if (!current) return;
    if (e.key === "ArrowDown") { e.preventDefault(); stopAutoplay(); select(selected + 1); $(`#demo-result-${selected}`)?.focus(); }
    if (e.key === "ArrowUp") { e.preventDefault(); stopAutoplay(); select(selected - 1); $(`#demo-result-${selected}`)?.focus(); }
  });
  // Pause autoplay while hovering the panel.
  $("#panel").addEventListener("mouseenter", () => clearTimeout(autoplayTimer));
  $("#panel").addEventListener("mouseleave", () => { if (autoplay) scheduleAutoplay(data.findIndex((d) => d === current)); });
}
initDemo();

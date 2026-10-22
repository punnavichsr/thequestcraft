// =====================================================================
//  JARVIS ANYWHERE: the orange AI button on every page of TheQuestCraft
//  It opens your REAL Jarvis from the Planner (planner.html?jarvis):
//  same name, key, memory, timetable powers and settings (⚙️).
//
//  How to add him to a page: put this line at the very end of <body>
//      <script src="jarvis.js"></script>
//  A page can give him "hands" by setting window.JarvisPage BEFORE that line:
//      window.JarvisPage = { name, context(), actions, names:[...], run(action) }
//  Other code can talk to him: await JarvisAnywhere.ask("hi")  ->  {reply} / {error} / {needsSetup}
// =====================================================================
(() => {
  const AI_KEY = "punn-levelup-ai";              // where the Planner saves your AI

  // ---------- look ----------
  const css = document.createElement("style");
  css.textContent = `
  #jvDot{position:fixed;right:16px;bottom:16px;z-index:70;display:flex;align-items:center;gap:8px;cursor:pointer;
    padding:9px 15px;border-radius:999px;font:800 14px system-ui,"Segoe UI",sans-serif;color:#fff;
    background:#140e1ee6;border:2px solid #f97316;box-shadow:0 0 16px #f9731666}
  #jvDot:hover{box-shadow:0 0 24px #f97316aa}
  body.in-game #jvDot{bottom:72px}                                   /* above the game's XP bar */
  body:has(#planner-screen.active) #jvDot{display:none}               /* the Planner has its own Jarvis */
  .jv-dot{width:10px;height:10px;border-radius:50%;background:#f97316;box-shadow:0 0 10px #f97316;animation:jvPulse 1.6s ease-in-out infinite}
  @keyframes jvPulse{50%{transform:scale(1.4);opacity:.7}}
  #jvPanel{position:fixed;top:0;right:0;bottom:0;width:380px;max-width:100vw;z-index:75;
    transform:translateX(105%);transition:transform .25s ease;box-shadow:0 0 40px #0009;border-left:2px solid #3a3f5c;background:#1b1d2b}
  #jvPanel.open{transform:none}
  #jvPanel iframe{width:100%;height:100%;border:0;display:block}`;
  document.head.appendChild(css);

  const dot = document.createElement("button");
  dot.id = "jvDot"; dot.type = "button";
  dot.innerHTML = `<span class="jv-dot"></span><span id="jvDotName">AI</span>`;
  const panel = document.createElement("aside");
  panel.id = "jvPanel";
  document.body.appendChild(dot); document.body.appendChild(panel);

  function showName() {
    let ai = {}; try { ai = JSON.parse(localStorage.getItem(AI_KEY) || "{}"); } catch (e) {}
    dot.querySelector("#jvDotName").textContent = ai.name || "AI";
  }

  // ---------- the real Jarvis lives in a small Planner window (made the first time it's needed) ----------
  let frame = null, ready = null;
  function load() {
    if (ready) return ready;
    frame = document.createElement("iframe");
    frame.title = "Jarvis";
    frame.src = "planner.html?jarvis";
    panel.appendChild(frame);
    ready = new Promise(res => frame.addEventListener("load", () => res(frame.contentWindow), { once: true }));
    return ready;
  }
  async function open() {
    await load();
    panel.classList.add("open");
    try { frame.contentDocument.getElementById("aiMsg").focus(); } catch (e) {}
  }
  function close() { panel.classList.remove("open"); }

  dot.onclick = () => panel.classList.contains("open") ? close() : open();
  window.addEventListener("storage", e => { if (e.key === AI_KEY) showName(); });

  // ask Jarvis something from code (the office Team chat uses this). The chat also shows in his panel.
  async function ask(text) {
    const w = await load();
    if (typeof w.askAI !== "function") return { error: "Jarvis didn't load" };
    return (await w.askAI(String(text))) || { error: "no answer" };
  }

  window.JarvisAnywhere = { open, close, ask, load };
  showName();
})();

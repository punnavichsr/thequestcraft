// =====================================================================
//  JARVIS ANYWHERE: the orange AI button on every page of TheQuestCraft
//  Uses the same AI you created in the Planner (name, Groq key, model).
//  How to add him to a page: put this line at the very end of <body>
//      <script src="jarvis.js"></script>
//  A page can give him "hands" by setting window.JarvisPage BEFORE that line:
//      window.JarvisPage = { name, context(), actions, run(action) }
// =====================================================================
(() => {
  const AI_KEY = "punn-levelup-ai";              // where the Planner saves your AI
  const CHAT_KEY = "jarvis-anywhere-chat";       // this chat, shared by every page
  const page = window.JarvisPage || { name: "TheQuestCraft" };

  const loadAI = () => {
    try { return { name: "", key: "", model: "openai/gpt-oss-120b", ...JSON.parse(localStorage.getItem(AI_KEY) || "{}") }; }
    catch (e) { return { name: "", key: "", model: "openai/gpt-oss-120b" }; }
  };
  let history = [];
  try { history = JSON.parse(localStorage.getItem(CHAT_KEY) || "[]"); } catch (e) {}
  const saveHistory = () => { history = history.slice(-20); try { localStorage.setItem(CHAT_KEY, JSON.stringify(history)); } catch (e) {} };

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
  #jvPanel{position:fixed;top:0;right:0;bottom:0;width:380px;max-width:100vw;z-index:75;display:flex;flex-direction:column;gap:8px;
    padding:14px;background:#1b1d2b;color:#eee;border-left:2px solid #3a3f5c;box-shadow:0 0 40px #0009;
    transform:translateX(105%);transition:transform .25s ease;font:14px system-ui,"Segoe UI",sans-serif}
  #jvPanel.open{transform:none}
  .jv-head{display:flex;justify-content:space-between;align-items:center;font-weight:800;letter-spacing:2px}
  .jv-head small{display:block;font-weight:500;letter-spacing:0;color:#9aa0b8;font-size:11.5px;margin-top:2px}
  .jv-x{background:none;border:none;color:#9aa0b8;font-size:18px;cursor:pointer}
  #jvChat{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:8px;padding:2px}
  .jv-b{max-width:88%;padding:9px 12px;border-radius:12px;line-height:1.45;white-space:pre-wrap;overflow-wrap:anywhere}
  .jv-b.me{align-self:flex-end;background:#f97316;color:#1a0f05;border-bottom-right-radius:4px}
  .jv-b.ai{align-self:flex-start;background:#2a2e45;border-bottom-left-radius:4px}
  .jv-b.note{align-self:center;background:#4ade8022;color:#4ade80;font-size:12px}
  .jv-b.err{align-self:center;background:#f8717122;color:#f87171;font-size:12px}
  .jv-b pre{white-space:pre;overflow-x:auto;background:#12131c;border:1px solid #3a3f5c;border-radius:8px;padding:8px;margin:6px 0;font-size:12.5px}
  .jv-b code{font-family:Consolas,"Courier New",monospace;color:#a5f3a5}
  #jvForm{display:grid;grid-template-columns:1fr auto;gap:6px}
  #jvForm input{padding:10px;border-radius:8px;background:#0006;color:#eee;border:2px solid #3a3f5c;font-size:14px;min-width:0}
  #jvForm button{padding:10px 14px;border-radius:8px;border:none;background:#f97316;color:#1a0f05;font-weight:800;cursor:pointer}
  .jv-clear{background:none;border:1px solid #3a3f5c;color:#9aa0b8;border-radius:8px;padding:4px 8px;font-size:11px;cursor:pointer;margin-right:6px}`;
  document.head.appendChild(css);

  const dot = document.createElement("button");
  dot.id = "jvDot"; dot.type = "button";
  dot.innerHTML = `<span class="jv-dot"></span><span id="jvDotName">AI</span>`;
  const panel = document.createElement("aside");
  panel.id = "jvPanel";
  panel.innerHTML = `
    <div class="jv-head"><div><span class="jv-dot" style="display:inline-block;margin-right:6px"></span><span id="jvTitle">AI</span>
      <small>Here with you on: ${esc(page.name)}</small></div>
      <div><button class="jv-clear" id="jvClear" type="button">🧹 New chat</button><button class="jv-x" id="jvClose" aria-label="Close">✕</button></div></div>
    <div id="jvChat"></div>
    <form id="jvForm"><input id="jvMsg" autocomplete="off"><button>Send</button></form>`;
  document.body.appendChild(dot); document.body.appendChild(panel);
  const chatEl = panel.querySelector("#jvChat"), input = panel.querySelector("#jvMsg");

  function esc(t) { return String(t).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
  function fmt(t) {
    return esc(t).replace(/\n?```[a-zA-Z]*\n?([\s\S]*?)```\n?/g, (m, code) => `<pre><code>${code.replace(/\n$/, "")}</code></pre>`)
                 .replace(/`([^`\n]+)`/g, "<code>$1</code>");
  }
  function bubble(text, who) {
    const b = document.createElement("div");
    b.className = "jv-b " + who; b.innerHTML = fmt(text);
    chatEl.appendChild(b); chatEl.scrollTop = chatEl.scrollHeight; return b;
  }
  function showName() {
    const ai = loadAI(), ready = !!(ai.name && ai.key);
    panel.querySelector("#jvTitle").textContent = ready ? ai.name.toUpperCase() : "YOUR AI";
    dot.querySelector("#jvDotName").textContent = ready ? ai.name : "AI";
    input.placeholder = ready ? `Ask ${ai.name} anything...` : "Create your AI in the Planner first";
    input.disabled = !ready;
  }

  // ---------- open / close ----------
  dot.onclick = () => {
    panel.classList.toggle("open"); showName();
    if (!panel.classList.contains("open")) return;
    const ai = loadAI();
    if (!chatEl.children.length) {
      if (!(ai.name && ai.key)) bubble("You haven't created your AI yet! Go to the game → PLANNER → press the orange button → ⚙️ and give your AI a name and a Groq key. Then I'll follow you everywhere 🧡", "note");
      else {
        history.forEach(m => bubble(m.content, m.role === "user" ? "me" : "ai"));
        if (!history.length) bubble(`Hi! I'm ${ai.name} 👋 I'm with you on every page now.${page.actions ? " On this page I can also press buttons for you, just ask!" : ""}`, "ai");
      }
    }
    input.focus();
  };
  panel.querySelector("#jvClose").onclick = () => panel.classList.remove("open");
  panel.querySelector("#jvClear").onclick = () => { history = []; saveHistory(); chatEl.innerHTML = ""; bubble("New chat started 🧹", "note"); };
  window.addEventListener("storage", e => { if (e.key === AI_KEY) showName(); });

  // ---------- the brain ----------
  async function systemPrompt(ai) {
    let ctx = "";
    try { ctx = page.context ? await page.context() : ""; } catch (e) {}
    return `You are ${ai.name}, Punn's own friendly, upbeat personal AI. Punn is a student and the CEO of TheQuestCraft (thequestcraft.com),
a browser RPG he built where students earn XP by doing real tasks (homework, studying, hobbies, reading).
You normally live in his Level-Up Planner, but now you float on every page as an orange button, so he can talk to you anywhere.
Keep replies short and fun (unless he asks for an explanation). For schoolwork, help him understand and plan, but don't just do his homework: ask him to try first.
Right now: ${new Date().toLocaleString("en-GB")}. He is on this page: ${page.name}.
${ctx}
${page.actions ? `You can press things on THIS page for him. When he asks, add this at the very END of your reply (a JSON array):
\`\`\`actions
[ ...one or more of the actions below... ]
\`\`\`
Actions on this page:
${page.actions}
Only include actions he asked for. Never say you did something without adding its action.` : "You can't press buttons on this page, only chat."}`;
  }

  async function ask(text) {
    const ai = loadAI();
    if (!(ai.name && ai.key)) { showName(); return; }
    bubble(text, "me");
    history.push({ role: "user", content: text }); saveHistory();
    const thinking = bubble("…thinking", "ai");
    try {
      const body = { model: ai.model, temperature: 0.6, messages: [{ role: "system", content: await systemPrompt(ai) }, ...history] };
      if (/gpt-oss/.test(ai.model)) body.reasoning_effort = "low";
      const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
        method: "POST", headers: { "Content-Type": "application/json", "Authorization": "Bearer " + ai.key }, body: JSON.stringify(body) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error?.message || res.status);
      let reply = data.choices[0].message.content || "";
      const m = reply.match(/```(?:actions|json)\s*([\s\S]*?)```/);
      reply = reply.replace(/```(?:actions|json)[\s\S]*?```/, "").trim();
      thinking.innerHTML = fmt(reply || "Done! ✅");
      history.push({ role: "assistant", content: reply || "Done! ✅" }); saveHistory();
      if (m && page.run) {
        let list = []; try { list = JSON.parse(m[1]); } catch (e) { bubble("I tried to press something but got confused 😅 Try again?", "err"); }
        for (const a of (Array.isArray(list) ? list : [list]).slice(0, 6)) {
          try { const note = await page.run(a, { name: ai.name, color: "#f97316" }); if (note) bubble(note, "note"); }
          catch (e) { console.error(e); bubble("Something went wrong: " + e.message, "err"); }
        }
      }
    } catch (err) {
      thinking.remove();
      bubble("Error: " + err.message + " (check your key in the Planner ⚙️)", "err");
    }
  }
  panel.querySelector("#jvForm").onsubmit = e => {
    e.preventDefault();
    const t = input.value.trim(); if (t) { input.value = ""; ask(t); }
  };

  // other code on the page can open him: JarvisAnywhere.open()
  window.JarvisAnywhere = { open: () => { if (!panel.classList.contains("open")) dot.click(); }, ask };
  showName();
})();

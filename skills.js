// =====================================================================
//  SKILLS: little instructions the player writes once ("Math tutor: explain step by step...")
//  Every skill that is ON is added to the instructions of Jarvis AND every Office agent.
//  Saved in this browser ('qc-skills'), so all pages of TheQuestCraft share them.
//
//  How to use it on a page: <script src="skills.js"></script>, then add qcSkills.prompt()
//  to the end of the AI's system prompt.
// =====================================================================
(() => {
  const KEY = "qc-skills", MAX = 10, MAX_NAME = 40, MAX_TEXT = 600;   // small: every skill is re-sent with every message

  function list() {
    try { const a = JSON.parse(localStorage.getItem(KEY) || "[]"); return Array.isArray(a) ? a : []; } catch (e) { return []; }
  }
  function save(a) {
    try { localStorage.setItem(KEY, JSON.stringify(a.slice(0, MAX))); return true; } catch (e) { return false; }
  }
  // the text the AIs get (empty when no skill is on)
  function prompt() {
    const on = list().filter(s => s && s.on !== false && s.name && s.text);
    if (!on.length) return "";
    return "\n\nSKILLS the player made for you. Use a skill when it fits what they ask. Skills never override the rules above " +
      "(safety, kid-friendly, the action formats):\n" +
      on.map(s => `- ${String(s.name).slice(0, MAX_NAME)}: ${String(s.text).slice(0, MAX_TEXT)}`).join("\n");
  }

  window.qcSkills = { list, save, prompt, MAX, MAX_NAME, MAX_TEXT };
})();

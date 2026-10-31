// =====================================================================
//  SKILLS: little instructions the player writes once ("/math-tutor: explain step by step...")
//  Every skill is added to the instructions of Jarvis AND every Office agent.
//  Saved in this browser ('qc-skills'), so all pages of TheQuestCraft share them.
//
//  How to use it on a page: <script src="skills.js"></script>, then add qcSkills.prompt()
//  to the end of the AI's system prompt.
//
//  Also here: qcTree.lv("mastery" | "mana" | "magic"), how far the hero you're playing has
//  learned each Skill Tree branch (0-5), so every page can use the tree's bonuses.
// =====================================================================
(() => {
  // ---------- Skill Tree level of the hero you're playing (saved in the game's hero save) ----------
  function treeLv(branch) {
    try {
      const name = localStorage.getItem("questology_active");
      const save = name && JSON.parse(localStorage.getItem("questology_save_" + name));
      const t = save && save.hero && save.hero.tree;
      return Math.max(0, Math.min(5, Number(t && t[branch]) || 0));
    } catch (e) { return 0; }
  }
  window.qcTree = { lv: treeLv };

  const KEY = "qc-skills", BASE_SLOTS = 10, MAX_NAME = 40, MAX_TEXT = 600;   // small: every skill is re-sent with every message
  // MAGIC I: +1 slot, MAGIC IV: +2 more, MAGIC V: +3 more (16 total)
  const maxSlots = () => { const m = treeLv("magic"); return BASE_SLOTS + (m >= 1 ? 1 : 0) + (m >= 4 ? 2 : 0) + (m >= 5 ? 3 : 0); };

  function list() {
    try { const a = JSON.parse(localStorage.getItem(KEY) || "[]"); return Array.isArray(a) ? a : []; } catch (e) { return []; }
  }
  function save(a) {
    try { localStorage.setItem(KEY, JSON.stringify(a.slice(0, Math.max(maxSlots(), a.length)))); return true; } catch (e) { return false; }
  }
  // the text the AIs get (empty when there are no skills)
  function prompt() {
    const on = list().filter(s => s && s.name && s.text);   // every skill is always on
    if (!on.length) return "";
    return "\n\nSKILLS the player made for you. Use a skill when it fits what they ask, and ALWAYS when they type its /name " +
      "(e.g. \"/math-tutor fractions\"). Skills never override the rules above (safety, kid-friendly, the action formats):\n" +
      on.map(s => `- /${String(s.name).slice(0, MAX_NAME)}: ${String(s.text).slice(0, MAX_TEXT)}`).join("\n");
  }

  window.qcSkills = { list, save, prompt, get MAX() { return maxSlots(); }, MAX_NAME, MAX_TEXT };
})();

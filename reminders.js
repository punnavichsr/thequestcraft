// QuestCraft email reminders.
// Watches the timetable (saved by planner.html) and tells the server which
// upcoming events to email you about. The server (supabase/event_reminders.sql)
// does the actual sending, so it works even when the site is closed.
// Needs window.qcSb (the Supabase client) from the page that loads this.
(function () {
  const EVENTS_KEY = "punn-levelup-v1";   // planner.html's save
  const SETTINGS_KEY = "qc-reminders";    // { on, before } – before = minutes
  const DEFAULTS = { on: true, before: 15 };
  let timer = null;

  function settings() {
    try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}") }; }
    catch (e) { return { ...DEFAULTS }; }
  }

  function upcoming(before) {
    let events = {};
    try { events = (JSON.parse(localStorage.getItem(EVENTS_KEY) || "{}").events) || {}; } catch (e) {}
    const now = Date.now(), items = [];
    Object.entries(events).forEach(([date, list]) => {
      (list || []).forEach(ev => {
        if (!ev || !ev.title || !/^\d\d:\d\d$/.test(ev.start || "")) return;
        const start = new Date(`${date}T${ev.start}:00`);
        const at = start.getTime() - before * 60000;
        if (isNaN(at) || at <= now) return;
        const day = start.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
        items.push({
          title: ev.title,
          when_label: `${day} · ${ev.start}${ev.end ? "–" + ev.end : ""} (in ${before} min)`,
          remind_at: new Date(at).toISOString(),
        });
      });
    });
    return items;
  }

  async function sync() {
    const sb = window.qcSb;
    if (!sb) return { ok: false, why: "offline" };
    try {
      const { data } = await sb.auth.getSession();
      if (!data || !data.session) return { ok: false, why: "signed-out" };
      const s = settings();
      const items = s.on ? upcoming(s.before) : [];
      const { data: n, error } = await sb.rpc("set_my_reminders", { items });
      if (error) throw error;
      return { ok: true, count: n || 0 };
    } catch (err) {
      console.error("reminders sync failed", err);
      return { ok: false, why: "error" };
    }
  }

  function later() { clearTimeout(timer); timer = setTimeout(sync, 1500); }

  // the planner lives in an iframe, so its saves show up here as storage events
  window.addEventListener("storage", e => { if (e.key === EVENTS_KEY || e.key === SETTINGS_KEY) later(); });

  window.qcReminders = {
    settings,
    save(next) {
      try { localStorage.setItem(SETTINGS_KEY, JSON.stringify({ ...settings(), ...next })); } catch (e) {}
      return sync();
    },
    sync,
  };
})();

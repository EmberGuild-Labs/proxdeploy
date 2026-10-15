/* ProxDeploy UI helpers — shared by the dashboard and the worker node page.
   Every URL passed to api() is relative on purpose: pages are mounted under
   a path prefix (e.g. /deploy/) behind nginx, so an absolute /api/... would escape the mount. */
(function () {
  "use strict";

  const $  = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // ── Icons (SF Symbols-style strokes, 24px grid) ───────────────────────────
  const P = {
    plus:     '<path d="M12 5v14M5 12h14"/>',
    update:   '<path d="M12 16V8m-4 4 4-4 4 4"/><circle cx="12" cy="12" r="9"/>',
    restart:  '<path d="M20 11a8 8 0 1 0-2.34 5.66"/><path d="M20 4v7h-7"/>',
    pause:    '<rect x="7" y="5" width="3.5" height="14" rx="1"/><rect x="13.5" y="5" width="3.5" height="14" rx="1"/>',
    play:     '<path d="M8 5.5v13a.8.8 0 0 0 1.2.7l10.4-6.5a.8.8 0 0 0 0-1.4L9.2 4.8A.8.8 0 0 0 8 5.5Z"/>',
    logs:     '<path d="M8 6h12M8 12h12M8 18h8M4 6h.01M4 12h.01M4 18h.01"/>',
    gear:     '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z"/>',
    trash:    '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
    more:     '<circle cx="5" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="19" cy="12" r="1.3" fill="currentColor"/>',
    external: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
    search:   '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    chevron:  '<path d="m6 9 6 6 6-6"/>',
    chevronR: '<path d="m9 6 6 6-6 6"/>',
    check:    '<circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.5 2.5L16 9.5"/>',
    x:        '<path d="M6 6l12 12M18 6 6 18"/>',
    alert:    '<path d="M12 3 2 20h20L12 3Z"/><path d="M12 10v4M12 17h.01"/>',
    info:     '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
    globe:    '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    arrow:    '<path d="M5 12h14m-5-5 5 5-5 5"/>',
    redirect: '<path d="M4 17V11a4 4 0 0 1 4-4h12m-4-4 4 4-4 4"/>',
    server:   '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    copy:     '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
    signout:  '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3M10 17l5-5-5-5M15 12H3"/>',
    rocket:   '<path d="M5 15c-1.5 1.3-2 5-2 5s3.7-.5 5-2c.7-.8.7-2 0-2.8a2 2 0 0 0-3 0Z"/><path d="m12 15-3-3a22 22 0 0 1 2-4A13 13 0 0 1 22 2c0 2.7-.8 7.5-6 11a22 22 0 0 1-4 2Z"/><path d="M9 12H4s.6-3 2-4c1.6-1 5 0 5 0M12 15v5s3-.6 4-2c1-1.6 0-5 0-5"/>',
    moon:     '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5Z"/>',
  };
  const icon = (name, extra = "") =>
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${P[name] || ""}</svg>`;

  // ── API ───────────────────────────────────────────────────────────────────
  // Always resolves to an object with ok/error so callers never need try/catch.
  async function api(path, body, opts = {}) {
    const init = body === undefined ? { method: "GET" }
      : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
    let r;
    try {
      r = await fetch(path, { credentials: "same-origin", ...init, ...opts });
    } catch (e) {
      return { ok: false, error: "Can't reach the server — is the Pi online?" };
    }
    if (r.status === 401 && !opts.noRedirect) {
      location.href = (window.LOGIN_URL || "login") + "?next=" + encodeURIComponent(location.pathname);
      return { ok: false, error: "Signed out." };
    }
    let data;
    try { data = await r.json(); }
    catch { return { ok: false, error: `Unexpected response (HTTP ${r.status}).` }; }
    if (data && typeof data === "object" && !Array.isArray(data) && !("ok" in data)) data.ok = r.ok;
    return data;
  }

  // ── Toasts ────────────────────────────────────────────────────────────────
  function toast(msg, kind = "inf") {
    let host = $(".toasts");
    if (!host) {
      host = document.createElement("div");
      host.className = "toasts";
      host.setAttribute("role", "status");
      host.setAttribute("aria-live", "polite");
      document.body.appendChild(host);
    }
    const el = document.createElement("div");
    el.className = `toast ${kind}`;
    el.innerHTML = icon(kind === "ok" ? "check" : kind === "err" ? "alert" : "info") + `<span>${esc(msg)}</span>`;
    host.appendChild(el);
    while (host.children.length > 3) host.firstElementChild.remove();
    const ttl = kind === "err" ? 7000 : 3800;
    setTimeout(() => { el.classList.add("out"); setTimeout(() => el.remove(), 200); }, ttl);
  }
  const report = (res, okMsg) => toast(res.ok ? (okMsg || res.message || "Done.") : (res.error || "Something went wrong."), res.ok ? "ok" : "err");

  // ── Anchored menu ─────────────────────────────────────────────────────────
  // One menu element for the whole page, positioned at its trigger and scaled
  // from the corner nearest it. It lives outside re-rendered lists, so a poll
  // refresh can't destroy it mid-use.
  let menuEl, menuTrigger;
  function openMenu(trigger, items) {
    closeMenu();
    menuEl = menuEl || Object.assign(document.createElement("div"), { className: "menu" });
    menuEl.setAttribute("role", "menu");
    menuEl.innerHTML = items.map((it, i) => it === "-" ? "<hr>" :
      `<button role="menuitem" data-i="${i}" class="${it.danger ? "danger" : ""}" ${it.disabled ? "disabled" : ""}>${icon(it.icon)}<span>${esc(it.label)}</span></button>`
    ).join("");
    document.body.appendChild(menuEl);
    const r = trigger.getBoundingClientRect();
    const w = Math.max(menuEl.offsetWidth, 200), h = menuEl.offsetHeight;
    const below = r.bottom + 6 + h < innerHeight;
    const left = Math.min(Math.max(8, r.right - w), innerWidth - w - 8);
    menuEl.style.left = left + "px";
    menuEl.style.top = (below ? r.bottom + 6 : Math.max(8, r.top - 6 - h)) + "px";
    menuEl.style.transformOrigin = `${r.right - left - r.width / 2}px ${below ? "0" : "100%"}`;
    menuEl.onclick = e => {
      const b = e.target.closest("button[data-i]");
      if (!b) return;
      const it = items[+b.dataset.i];
      closeMenu(true);
      it.run && it.run();
    };
    menuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    requestAnimationFrame(() => { menuEl.classList.add("open"); menuEl.querySelector("button:not(:disabled)")?.focus({ preventScroll: true }); });
  }
  function closeMenu(keepFocus) {
    if (!menuEl || !menuEl.classList.contains("open")) return;
    menuEl.classList.remove("open");
    if (menuTrigger) {
      menuTrigger.setAttribute("aria-expanded", "false");
      if (!keepFocus && document.contains(menuTrigger)) menuTrigger.focus({ preventScroll: true });
    }
    menuTrigger = null;
  }
  document.addEventListener("pointerdown", e => { if (menuEl && !menuEl.contains(e.target) && !e.target.closest("[aria-haspopup]")) closeMenu(true); });
  document.addEventListener("keydown", e => {
    if (!menuEl || !menuEl.classList.contains("open")) return;
    const btns = $$("button:not(:disabled)", menuEl);
    const i = btns.indexOf(document.activeElement);
    if (e.key === "Escape") { e.preventDefault(); closeMenu(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); btns[(i + 1) % btns.length]?.focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); btns[(i - 1 + btns.length) % btns.length]?.focus(); }
    else if (e.key === "Tab") closeMenu(true);
  });
  addEventListener("scroll", () => closeMenu(true), { passive: true, capture: true });
  addEventListener("resize", () => closeMenu(true));

  // ── Dialog helpers ────────────────────────────────────────────────────────
  // Native <dialog>: focus trapping, Escape and the top layer come for free.
  function openDialog(d) {
    if (!d.open) {
      d.showModal();
      // Focus the sheet itself rather than its first link, so nothing wears a
      // focus ring until the user actually tabs. Forms focus their own field.
      d.setAttribute("tabindex", "-1");
      d.focus({ preventScroll: true });
    }
    // Click on the backdrop (the dialog element itself, outside its content) closes
    if (!d._wired) {
      d._wired = true;
      d.addEventListener("click", e => { if (e.target === d) d.close("cancel"); });
    }
  }

  /** confirmDialog({title, body, confirm, destructive}) → Promise<boolean> */
  function confirmDialog({ title, body = "", confirm = "OK", destructive = false, input = null }) {
    return new Promise(resolve => {
      const d = document.createElement("dialog");
      d.className = "sheet small";
      d.setAttribute("aria-labelledby", "cd-title");
      d.innerHTML = `
        <div class="sheet-head"><div class="titles"><h2 class="sheet-title" id="cd-title">${esc(title)}</h2>
          ${body ? `<p class="sheet-sub">${body}</p>` : ""}</div></div>
        ${input ? `<div class="sheet-body"><div class="field"><label for="cd-in">${esc(input.label)}</label>
          <input class="input" id="cd-in" value="${esc(input.value || "")}" placeholder="${esc(input.placeholder || "")}" autocomplete="off" spellcheck="false"></div></div>` : ""}
        <div class="sheet-foot">
          <button class="btn" value="cancel" type="button" data-act="cancel">Cancel</button>
          <button class="btn ${destructive ? "danger filled" : "primary"}" type="button" data-act="ok">${esc(confirm)}</button>
        </div>`;
      document.body.appendChild(d);
      const inp = d.querySelector("#cd-in");
      let result = false;
      d.addEventListener("click", e => {
        const a = e.target.closest("[data-act]")?.dataset.act;
        if (a === "ok") { result = inp ? inp.value.trim() : true; d.close(); }
        else if (a === "cancel" || e.target === d) d.close();
      });
      inp && inp.addEventListener("keydown", e => { if (e.key === "Enter") { result = inp.value.trim(); d.close(); } });
      d.addEventListener("close", () => { resolve(result); setTimeout(() => d.remove(), 400); });
      d.showModal();
      (inp || d.querySelector(destructive ? "[data-act=cancel]" : "[data-act=ok]")).focus();
      if (inp) inp.select();
    });
  }

  // Busy state for a button: spinner + disabled, restored after the promise
  async function busy(btn, fn) {
    if (!btn) return fn();
    const html = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = `<span class="spin" aria-hidden="true"></span><span>${esc(btn.dataset.busy || btn.textContent.trim())}</span>`;
    try { return await fn(); }
    finally { btn.disabled = false; btn.innerHTML = html; }
  }

  // ── Formatting ────────────────────────────────────────────────────────────
  function fmtUptime(s) {
    if (s == null) return null;
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
  }
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  function fmtAgo(iso) {
    if (!iso) return null;
    const t = new Date(iso).getTime();
    if (isNaN(t)) return null;
    const s = (t - Date.now()) / 1000, a = Math.abs(s);
    if (a < 60) return "just now";
    if (a < 3600) return rtf.format(Math.round(s / 60), "minute");
    if (a < 86400) return rtf.format(Math.round(s / 3600), "hour");
    if (a < 86400 * 30) return rtf.format(Math.round(s / 86400), "day");
    return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  }
  function fmtMB(mb) {
    if (mb == null) return null;
    return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
  }
  function meter(pct) {
    const p = Math.max(0, Math.min(100, pct || 0));
    return `<div class="track"><i class="${p >= 90 ? "crit" : p >= 75 ? "warn" : ""}" style="width:${p}%"></i></div>`;
  }
  const STATUS = { online: "Online", paused: "Paused", error: "Error", deploying: "Deploying", updating: "Updating" };
  const statusLabel = s => STATUS[s] || (s ? s[0].toUpperCase() + s.slice(1) : "Unknown");
  const badge = s => `<span class="badge s-${esc(s)}"><span class="dot"></span>${esc(statusLabel(s))}</span>`;
  const repoShort = url => String(url || "").replace(/^https?:\/\/(www\.)?github\.com\//, "").replace(/\.git$/, "");

  // Render into `el` only when the markup actually changed, and put focus back
  // on the equivalent control afterwards — polling must never steal focus.
  function patch(el, html) {
    if (el._html === html) return;
    const active = document.activeElement;
    const fid = el.contains(active) ? active?.dataset?.fid : null;
    el._html = html;
    el.innerHTML = html;
    if (fid) el.querySelector(`[data-fid="${CSS.escape(fid)}"]`)?.focus({ preventScroll: true });
  }

  // ── Log rendering (shared by both dashboards) ─────────────────────────────
  function renderLogLines(lines, emptyText) {
    if (!lines || !lines.length) return `<div class="none">${esc(emptyText)}</div>`;
    return lines.map(l => {
      const t = l.replace(/\n$/, "");
      const cls = t.includes("[ERROR]") ? "err" : t.includes("[WARN]") ? "warn" : "";
      const m = t.match(/^(\[[\d\-: ]{19}\])(.*)$/);
      return `<span class="l ${cls}">${m ? `<span class="ts">${esc(m[1])}</span>${esc(m[2])}` : esc(t)}</span>`;
    }).join("");
  }

  window.UI = { $, $$, esc, icon, api, toast, report, openMenu, closeMenu, openDialog, confirmDialog, busy,
                fmtUptime, fmtAgo, fmtMB, meter, statusLabel, badge, repoShort, patch, renderLogLines };
})();

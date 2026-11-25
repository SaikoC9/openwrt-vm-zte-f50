// @matchi-name OpenWrt VM
// @matchi-version 1.0.0
// @matchi-author saiko
// @matchi-description Real OpenWrt in a KVM virtual machine on the F50. This version only reads: it shows the state of the VM and its logs.
// @matchi-requires root
/*
 * OpenWrt VM for MatchiTOOL (Phase 6, step 3: read-only skeleton).
 * Copyright (c) 2026 saiko (GitHub: SaikoC9). MIT License.
 *
 * Nothing on this page changes the device. It runs `owrt-vm.sh state` and a few reads in the install
 * folder and shows what they print. Install, start, stop and settings come in the next steps.
 *
 * The install folder name is the file name of this plugin (OpenWrt_VM), so the host erases it on Delete.
 * Do not rename this file without moving the folder.
 */
// MatchiTOOL: what to run when this plugin is deleted with "Stop". The boot entry goes first, then the VM is stopped,
// then the check says whether anything is left (VM process, taps, firewall chains, ip rules, joined LAN).
// @matchi-uninstall rm -f /data/local/matchitool/boot.d/30-owrt-vm.sh
// @matchi-uninstall [ ! -f /data/local/matchitool/plugin_data/OpenWrt_VM/owrt-vm.sh ] || OWRT_DIR=/data/local/matchitool/plugin_data/OpenWrt_VM sh /data/local/matchitool/plugin_data/OpenWrt_VM/owrt-vm.sh stop
// @matchi-check [ ! -f /data/local/matchitool/plugin_data/OpenWrt_VM/owrt-vm.sh ] || OWRT_DIR=/data/local/matchitool/plugin_data/OpenWrt_VM sh /data/local/matchitool/plugin_data/OpenWrt_VM/owrt-vm.sh gone
// @matchi-boot /data/local/matchitool/boot.d/30-owrt-vm.sh
(() => {
  'use strict';

  const TITLE = 'OpenWrt VM';
  const NAME = 'matchi_owrt_vm_modal';
  const BTN_ID = 'matchi_owrt_vm_btn';
  const STYLE_ID = 'matchi_owrt_vm_style';
  const D = '/data/local/matchitool/plugin_data/OpenWrt_VM';
  const FILES = ['cloud-hypervisor', 'Image', 'rootfs.img', 'owrt-vm.sh', 'owrt-kvmprobe'];
  const LOGS = [['console.log', 'Console'], ['console.log.1', 'Console (previous)'], ['vmm.log', 'VMM']];
  const REFRESH_MS = 30000;      // while the window is open and the tab is visible
  const MAX_OUT = 65536;         // characters kept from one shell answer
  const LOG_LINES = 200;
  const LOG_CHARS = 20000;
  const KV_LINE = /^([a-z_0-9]+)=([A-Za-z0-9._:/-]*)$/;
  const STATE_KEYS = ['installed', 'version', 'running', 'pid', 'cpus', 'mem', 'lan', 'joined', 'dhcp_block',
    'dhcp_block_secs', 'expose', 'guest_dhcp4', 'leftovers', 'ip_forward', 'mem_avail_kb'];

  // ---------------------------------------------------------------- pure parts (tested in node, no DOM)

  // key=value lines only; anything else is counted and ignored
  function parseKv(text) {
    const kv = {};
    let other = 0;
    for (const raw of String(text == null ? '' : text).split('\n')) {
      const line = raw.replace(/\r$/, '');
      if (!line) continue;
      const m = KV_LINE.exec(line);
      if (m) kv[m[1]] = m[2]; else other++;
    }
    return { kv, other };
  }

  // One root call answers everything the page shows: file sizes, `state`, free RAM, free storage.
  // The sections start with a line "@@name".
  function probeCommand() {
    return [
      'D=' + D,
      'echo @@files',
      'for f in ' + FILES.join(' ') + '; do s=$(stat -c %s "$D/$f" 2>/dev/null) && echo "$f=$s" || echo "$f=-"; done',
      'echo @@state',
      '[ -f "$D/owrt-vm.sh" ] && OWRT_DIR="$D" timeout 25 sh "$D/owrt-vm.sh" state 2>&1',
      'echo @@mem',
      "sed -n 's/^MemAvailable:[[:space:]]*\\([0-9]*\\).*/\\1/p' /proc/meminfo | head -n 1",
      'echo @@df',
      'df -k /data 2>/dev/null | tail -n 1',
      'echo @@end',
    ].join('\n');
  }

  function logCommand(file) {
    const known = LOGS.some((l) => l[0] === file);
    if (!known) return 'echo "unknown log file"';
    const f = D + '/' + file;
    return '[ -f "' + f + '" ] && tail -n ' + LOG_LINES + ' "' + f + '" 2>&1 | tail -c ' + LOG_CHARS + ' || echo "(no ' + file + ' yet)"';
  }

  function sections(text) {
    const out = {};
    let cur = null;
    for (const raw of String(text == null ? '' : text).split('\n')) {
      const line = raw.replace(/\r$/, '');
      const m = /^@@([a-z]+)$/.exec(line);
      if (m) { cur = m[1]; out[cur] = []; continue; }
      if (cur) out[cur].push(line);
    }
    return out;
  }

  // The model the window is drawn from. `ok` is false when the root call itself failed.
  function parseProbe(text, ok) {
    const sec = sections(text);
    const files = {};
    for (const line of sec.files || []) {
      const m = /^([A-Za-z0-9._-]+)=(\d+|-)$/.exec(line);
      if (m) files[m[1]] = m[2] === '-' ? null : Number(m[2]);
    }
    const st = parseKv((sec.state || []).join('\n'));
    const haveState = STATE_KEYS.every((k) => k in st.kv);
    const memLine = (sec.mem || []).find((l) => /^\d+$/.test(l));
    let diskFreeKb = null;
    const dfLine = (sec.df || []).filter((l) => l.trim()).pop();
    if (dfLine) {
      const f = dfLine.trim().split(/\s+/);
      if (f.length >= 4 && /^\d+$/.test(f[3])) diskFreeKb = Number(f[3]);
    }
    return {
      ok: !!ok && !!sec.end,
      files,
      scriptThere: files['owrt-vm.sh'] != null,
      state: haveState ? st.kv : null,
      stateRaw: (sec.state || []).join('\n').trim(),
      memAvailKb: memLine ? Number(memLine) : null,
      diskFreeKb,
    };
  }

  // What to show for a model: a headline and rows. cls is good, warn, bad or '' (plain).
  function describe(m) {
    const kb = (v) => (v == null ? 'unknown' : fmtBytes(v * 1024));
    const rows = [];
    const filesText = FILES.map((f) => f + ' ' + (m.files[f] == null ? 'missing' : fmtBytes(m.files[f]))).join(', ');
    let hero;
    if (!m.ok) {
      hero = { cls: 'bad', text: 'Cannot read the device' };
    } else if (!m.scriptThere) {
      hero = { cls: '', text: 'Not installed' };
    } else if (!m.state) {
      hero = { cls: 'bad', text: 'owrt-vm.sh state gave no usable answer' };
    } else if (m.state.running === '1') {
      hero = { cls: 'good', text: 'Running, pid ' + m.state.pid };
    } else if (Number(m.state.leftovers) > 0) {
      hero = { cls: 'warn', text: 'Stopped, ' + m.state.leftovers + ' leftover' + (m.state.leftovers === '1' ? '' : 's') };
    } else if (m.state.installed !== '1') {
      hero = { cls: 'warn', text: 'Stopped, files missing' };
    } else {
      hero = { cls: '', text: 'Stopped' };
    }
    rows.push(['Files', filesText, m.scriptThere && m.state && m.state.installed !== '1' ? 'warn' : '']);
    const s = m.state;
    if (s) {
      const yn = (v) => (v === '1' ? 'yes' : 'no');
      rows.push(['Version', s.version || 'none', '']);
      rows.push(['VM settings', s.cpus + ' CPU, ' + s.mem + ' RAM', '']);
      rows.push(['Guest LAN', s.lan === '1' ? 'on' : 'off', '']);
      rows.push(['Joined to hotspot', yn(s.joined), '']);
      rows.push(['Android DHCP block', s.dhcp_block === '1'
        ? 'on' + (Number(s.dhcp_block_secs) > 0 ? ', ' + s.dhcp_block_secs + ' s left' : ', no timer') : 'off', '']);
      rows.push(['Port forwards', s.expose === '1' ? 'on' : 'off', s.expose === '1' ? 'warn' : '']);
      rows.push(['Guest DHCPv4', s.guest_dhcp4 === '1' ? 'on' : 'off', '']);
      rows.push(['ip_forward', s.ip_forward === '1' ? 'on' : (s.ip_forward === '0' ? 'off' : s.ip_forward), '']);
      rows.push(['Leftovers', s.running === '1' ? 'not counted while running' : s.leftovers,
        s.running !== '1' && Number(s.leftovers) > 0 ? 'warn' : '']);
    }
    rows.push(['Free RAM', kb(m.memAvailKb != null ? m.memAvailKb : (s && s.mem_avail_kb ? Number(s.mem_avail_kb) : null)), '']);
    rows.push(['Free storage (/data)', kb(m.diskFreeKb), '']);
    return { hero, rows };
  }

  function fmtBytes(n) {
    const u = ['B', 'KB', 'MB', 'GB'];
    let v = Number(n), i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? String(v) : v.toFixed(v >= 100 ? 0 : 1)) + ' ' + u[i];
  }

  // console output may carry escape sequences and control characters
  function cleanLog(text) {
    return String(text == null ? '' : text)
      // eslint-disable-next-line no-control-regex
      .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')
      // eslint-disable-next-line no-control-regex
      .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '')
      .replace(/\r\n?/g, '\n');
  }

  if (typeof module === 'object' && module && module.exports) {
    module.exports = { parseKv, probeCommand, logCommand, parseProbe, describe, cleanLog, fmtBytes, sections, D, FILES, LOGS, STATE_KEYS };
    return;
  }

  // ---------------------------------------------------------------- page part
  const m = window.matchi;
  if (!m || !m.root || !m.modal || !m.menu) { console.error('OpenWrt VM: this MatchiTOOL version has no plugin API'); return; }
  const esc = m.escapeHtml;

  try { window.__matchi_owrt_vm_cleanup?.(); } catch (_) { /* old copy already gone */ }
  document.getElementById(BTN_ID)?.remove();
  document.getElementById(NAME)?.remove();

  // One helper runs every shell call: one at a time, a timeout, the answer cut to MAX_OUT.
  let chain = Promise.resolve();
  function sh(cmd, ms) {
    const job = chain.then(async () => {
      try {
        const r = await m.root(cmd, ms || 25000);
        let text = String((r && r.content) == null ? '' : r.content);
        if (text.length > MAX_OUT) text = text.slice(-MAX_OUT);
        return { ok: !!(r && r.success), text };
      } catch (e) {
        return { ok: false, text: String((e && e.message) || e) };
      }
    });
    chain = job.then(() => undefined, () => undefined);
    return job;
  }

  const css = `
    #${NAME} .ow-wrap{display:flex;flex-direction:column;gap:10px;max-height:76vh;overflow-y:auto;overflow-x:hidden;line-height:1.35}
    #${NAME} .ow-hero{padding:9px 12px;border-radius:10px;font-weight:800;border:1px solid var(--bd,rgba(255,255,255,.12));background:rgba(255,255,255,.04);overflow-wrap:anywhere}
    #${NAME} .ow-hero.good{color:var(--good,#64e6a4);border-color:rgba(100,230,164,.35);background:rgba(100,230,164,.08)}
    #${NAME} .ow-hero.warn{color:var(--warn,#ffd76a);border-color:rgba(255,215,106,.35);background:rgba(255,215,106,.08)}
    #${NAME} .ow-hero.bad{color:var(--bad,#ff8a8a);border-color:rgba(255,138,138,.35);background:rgba(255,138,138,.08)}
    #${NAME} .ow-table{display:grid;grid-template-columns:minmax(0,38%) minmax(0,1fr);gap:4px 10px;font-size:.8rem}
    #${NAME} .ow-k{opacity:.62}
    #${NAME} .ow-v{font-weight:650;overflow-wrap:anywhere}
    #${NAME} .ow-v.good{color:var(--good,#64e6a4)} #${NAME} .ow-v.warn{color:var(--warn,#ffd76a)} #${NAME} .ow-v.bad{color:var(--bad,#ff8a8a)}
    #${NAME} .ow-bar{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
    #${NAME} .ow-bar button{padding:4px 10px;border-radius:8px;font-size:.78rem}
    #${NAME} .ow-bar button.on{outline:1px solid var(--acc,#6ea8ff)}
    #${NAME} .ow-h{font-weight:800;font-size:.85rem;margin-top:2px}
    #${NAME} .ow-note{opacity:.7;font-size:.72rem}
    #${NAME} pre{margin:0;padding:8px 10px;border-radius:9px;background:rgba(0,0,0,.3);font:.62rem/1.45 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;max-height:220px;overflow:auto;user-select:text}
    #${NAME} details summary{cursor:pointer;font-size:.75rem;opacity:.8}`;
  function addStyle() {
    document.getElementById(STYLE_ID)?.remove();
    const el = document.createElement('style');
    el.id = STYLE_ID;
    el.textContent = css;
    document.head.appendChild(el);
  }

  let timer = null;
  let modalEl = null;
  let model = null;
  let logFile = LOGS[0][0];
  let logText = '';
  let busy = false;

  const q = (sel) => (modalEl ? modalEl.querySelector(sel) : null);

  function paint() {
    if (!modalEl || !model) return;
    const d = describe(model);
    const hero = q('.ow-hero');
    hero.className = 'ow-hero ' + d.hero.cls;
    hero.textContent = d.hero.text;
    q('.ow-table').innerHTML = d.rows.map((r) => `<div class="ow-k">${esc(r[0])}</div><div class="ow-v ${esc(r[2])}">${esc(r[1])}</div>`).join('');
    q('.ow-raw').textContent = model.stateRaw || '(no output)';
    q('.ow-log').textContent = logText || '(press a log button)';
    modalEl.querySelectorAll('[data-log]').forEach((b) => b.classList.toggle('on', b.dataset.log === logFile));
    const btn = document.getElementById(BTN_ID);
    if (btn) m.status(btn, model.state ? model.state.running === '1' : null);
  }

  async function refresh() {
    if (busy) return;
    busy = true;
    const b = q('[data-act="refresh"]');
    if (b) b.disabled = true;
    try {
      const r = await sh(probeCommand(), 40000);
      model = parseProbe(r.text, r.ok);
      if (!model.ok && !model.stateRaw) model.stateRaw = r.text.slice(0, 2000);
    } finally {
      busy = false;
      if (b) b.disabled = false;
    }
    paint();
  }

  async function loadLog(file) {
    logFile = file;
    logText = 'Reading…';
    paint();
    const r = await sh(logCommand(file), 20000);
    logText = cleanLog(r.text) || '(empty)';
    paint();
  }

  function stopTimer() { if (timer) { clearInterval(timer); timer = null; } }

  async function open() {
    if (document.getElementById(NAME)) return;
    addStyle();
    model = null; logText = ''; logFile = LOGS[0][0];
    const created = m.modal.create({
      name: NAME,
      title: TITLE,
      maxWidth: '560px',
      showConfirm: false,
      onClose: () => { stopTimer(); modalEl = null; return true; },
      content: `
        <div class="ow-wrap">
          <div class="ow-hero">Reading…</div>
          <div class="ow-table"></div>
          <div class="ow-bar"><button type="button" data-act="refresh">Refresh</button><span class="ow-note">This page only reads. It changes nothing on the device.</span></div>
          <div class="ow-h">Logs</div>
          <div class="ow-bar">${LOGS.map((l) => `<button type="button" data-log="${esc(l[0])}">${esc(l[1])}</button>`).join('')}<button type="button" data-act="copy">Copy</button></div>
          <pre class="ow-log"></pre>
          <details><summary>Raw answer of owrt-vm.sh state</summary><pre class="ow-raw"></pre></details>
        </div>`,
    });
    if (!created || !created.id) { m.toast('OpenWrt VM: the window could not be created', 'red', 6000); return; }
    modalEl = created.el;
    q('[data-act="refresh"]').onclick = () => { refresh(); };
    q('[data-act="copy"]').onclick = async () => { m.toast((await m.copy(logText)) ? 'Log copied' : 'Could not copy', 'blue', 2500); };
    modalEl.querySelectorAll('[data-log]').forEach((b) => { b.onclick = () => { loadLog(b.dataset.log); }; });
    m.modal.show(created.id);
    timer = setInterval(() => { if (!document.hidden && modalEl) refresh(); }, REFRESH_MS);   // lint-ok: one state read, 30 s, skipped while the tab is hidden
    if (!(await m.hasRoot())) {
      stopTimer();
      q('.ow-hero').className = 'ow-hero bad';
      q('.ow-hero').textContent = 'No root shell. This plugin needs root.';
      return;
    }
    await refresh();
  }

  const button = document.createElement('button');
  button.id = BTN_ID;
  button.type = 'button';
  button.textContent = TITLE;
  button.onclick = () => { open().catch((e) => m.toast('OpenWrt VM: ' + ((e && e.message) || e), 'red', 6000)); };

  let gone = false;
  window.__matchi_owrt_vm_cleanup = () => {
    gone = true;
    stopTimer();
    button.remove();
    document.getElementById(NAME)?.remove();
    document.getElementById(STYLE_ID)?.remove();
    delete window.__matchi_owrt_vm_cleanup;
  };

  (async () => {
    for (let i = 0; i < 60 && !gone; i++) {
      const box = m.menu();
      if (box) { box.appendChild(button); return; }
      await m.wait(500);
    }
    if (!gone) console.error('OpenWrt VM: no plugin menu found, button not added');
  })();
})();

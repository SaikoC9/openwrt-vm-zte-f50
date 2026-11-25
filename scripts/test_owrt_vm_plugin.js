#!/usr/bin/env node
// Tests plugin/OpenWrt_VM.js without a browser: the parsing and the wording of the window, that the commands the page
// sends are reads only, and that the real `owrt-vm.sh state` answer is what the page expects (page and script cannot drift).
// Run by hand: node scripts/test_owrt_vm_plugin.js
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), assert = require('assert');
const { spawnSync } = require('child_process');
const root = path.join(__dirname, '..');
const plug = require(path.join(root, 'plugin/OpenWrt_VM.js'));
const src = fs.readFileSync(path.join(root, 'plugin/OpenWrt_VM.js'), 'utf8');
let n = 0;
const t = (name, f) => { try { f(); n++; } catch (e) { console.error('FAIL', name, '\n', e.message); process.exitCode = 1; } };

const STATE = `installed=1
version=0.1.0
running=1
pid=4242
cpus=2
mem=256M
lan=1
joined=1
dhcp_block=1
dhcp_block_secs=0
expose=0
guest_dhcp4=1
leftovers=-1
ip_forward=1
mem_avail_kb=500000`;
const probe = (state, over = {}) => [
  '@@files', 'cloud-hypervisor=9000000', 'Image=15000000', 'rootfs.img=52000000', 'owrt-vm.sh=30000', 'owrt-kvmprobe=-',
  '@@state', state, '@@mem', String(over.mem ?? 500000), '@@df', over.df ?? '/dev/block/dm-9 25000000 5000000 19699876 21% /data', '@@end'].join('\n');

t('parseKv keeps only key=value lines and counts the rest', () => {
  const r = plug.parseKv('a=1\nB=2\nx_y=ok.v-1\nnoise\n\n k=1\nz=$(id)\nlast=\n');
  assert.deepStrictEqual(r.kv, { a: '1', x_y: 'ok.v-1', last: '' });
  assert.strictEqual(r.other, 4);
});
t('sections split on @@name lines', () => {
  const s = plug.sections('junk\n@@a\n1\n2\n@@b\n@@end');
  assert.deepStrictEqual(s, { a: ['1', '2'], b: [], end: [] });
});
t('probe of a running VM: model fields', () => {
  const m = plug.parseProbe(probe(STATE), true);
  assert.ok(m.ok && m.scriptThere && m.state);
  assert.strictEqual(m.state.pid, '4242');
  assert.strictEqual(m.files['rootfs.img'], 52000000);
  assert.strictEqual(m.files['owrt-kvmprobe'], null);
  assert.strictEqual(m.memAvailKb, 500000);
  assert.strictEqual(m.diskFreeKb, 19699876);
});
t('headline for every state', () => {
  const head = (state, ok = true, extra) => plug.describe(plug.parseProbe(probe(state, extra), ok)).hero;
  assert.deepStrictEqual(head(STATE), { cls: 'good', text: 'Running, pid 4242' });
  const stopped = STATE.replace('running=1', 'running=0').replace('pid=4242', 'pid=').replace('leftovers=-1', 'leftovers=0');
  assert.deepStrictEqual(head(stopped), { cls: '', text: 'Stopped' });
  assert.deepStrictEqual(head(stopped.replace('leftovers=0', 'leftovers=3')), { cls: 'warn', text: 'Stopped, 3 leftovers' });
  assert.deepStrictEqual(head(stopped.replace('leftovers=0', 'leftovers=1')), { cls: 'warn', text: 'Stopped, 1 leftover' });
  assert.deepStrictEqual(head(stopped.replace('installed=1', 'installed=0')), { cls: 'warn', text: 'Stopped, files missing' });
  assert.deepStrictEqual(head('garbage'), { cls: 'bad', text: 'owrt-vm.sh state gave no usable answer' });
  assert.deepStrictEqual(head(STATE, false), { cls: 'bad', text: 'Cannot read the device' });
  const none = plug.parseProbe(probe('').replace('owrt-vm.sh=30000', 'owrt-vm.sh=-'), true);
  assert.deepStrictEqual(plug.describe(none).hero, { cls: '', text: 'Not installed' });
});
t('a missing @@end means the root call was cut: not ok', () => {
  assert.strictEqual(plug.parseProbe('@@files\n@@state\n' + STATE, true).ok, false);
});
t('rows show what the shell said', () => {
  const rows = Object.fromEntries(plug.describe(plug.parseProbe(probe(STATE), true)).rows.map((r) => [r[0], r[1]]));
  assert.strictEqual(rows['Version'], '0.1.0');
  assert.strictEqual(rows['VM settings'], '2 CPU, 256M RAM');
  assert.strictEqual(rows['Joined to hotspot'], 'yes');
  assert.strictEqual(rows['Android DHCP block'], 'on, no timer');
  assert.strictEqual(rows['Port forwards'], 'off');
  assert.strictEqual(rows['Leftovers'], 'not counted while running');
  assert.strictEqual(rows['Free RAM'], '488 MB');
  assert.strictEqual(rows['Free storage (/data)'], '18.8 GB');
  assert.ok(/owrt-kvmprobe missing/.test(rows['Files']));
  const timed = plug.parseProbe(probe(STATE.replace('dhcp_block_secs=0', 'dhcp_block_secs=42')), true);
  assert.strictEqual(Object.fromEntries(plug.describe(timed).rows.map((r) => [r[0], r[1]]))['Android DHCP block'], 'on, 42 s left');
});
t('odd df output and missing mem do not break the model', () => {
  const m = plug.parseProbe(probe(STATE, { df: 'df: error', mem: '' }), true);
  assert.strictEqual(m.diskFreeKb, null);
  const rows = Object.fromEntries(plug.describe(m).rows.map((r) => [r[0], r[1]]));
  assert.strictEqual(rows['Free storage (/data)'], 'unknown');
  assert.strictEqual(rows['Free RAM'], '488 MB');   // falls back to the figure in `state`
});
t('cleanLog drops escape sequences and control characters', () => {
  assert.strictEqual(plug.cleanLog('a\x1b[31mred\x1b[0m\r\nb\x00c\x07d\r'), 'ared\nbcd\n');
});
t('the commands are reads only', () => {
  const cmds = [plug.probeCommand(), ...plug.LOGS.map((l) => plug.logCommand(l[0]))];
  for (const c of cmds) {
    assert.ok(!/(^|[\s;&|])(rm|mv|cp|chmod|kill|mkdir|touch|tee|dd|mount|iptables|ip)\s/.test(c), 'writes or changes something: ' + c);
    assert.ok(!/>\s*[^&\s]/.test(c.replace(/2>\/dev\/null|2>&1/g, '')), 'redirects output to a file: ' + c);
    assert.ok(!/owrt-vm\.sh"? (start|stop|restart|join|unjoin|dhcp-block|dhcp-unblock|loop|test)/.test(c), 'runs a changing command: ' + c);
  }
  assert.ok(/owrt-vm\.sh" state/.test(plug.probeCommand()));
  assert.strictEqual(plug.logCommand('../../etc/passwd'), 'echo "unknown log file"');
});
t('the commands pass MatchiTOOL\'s plugin shell filter patterns', () => {
  // the rules of shellDanger in PluginGuard.kt, applied to the text with quotes and backslashes removed
  const rules = [/\bdd\b[^;|&]{0,200}\bof=\/dev\//, /\bmkfs/, />>? ?\/(?:system|vendor|boot|dev\/block)/, /\bmount\b[^;|&]{0,80}\bremount\b/,
    /\brm (?:-[a-z-]+ )+(?:\/|\/data)(?: |;|&|\||\)|`|$)/, /\b(?:curl|wget)\b[^;|&]{0,300}\| ?(?:sh|bash)\b/];
  for (const c of [plug.probeCommand(), ...plug.LOGS.map((l) => plug.logCommand(l[0]))]) {
    const x = c.replace(/['"\\]/g, '').replace(/\s+/g, ' ').toLowerCase();
    for (const r of rules) assert.ok(!r.test(x), 'filter would refuse: ' + r + ' ' + c);
  }
});
t('stop headers: lengths, order, and the same folder as the plugin reads', () => {
  const lines = src.split('\n');
  const un = lines.filter((l) => /^\/\/ @matchi-uninstall /.test(l));
  const chk = lines.filter((l) => /^\/\/ @matchi-check /.test(l));
  const boot = lines.filter((l) => /^\/\/ @matchi-boot /.test(l));
  assert.strictEqual(un.length, 2); assert.strictEqual(chk.length, 1); assert.strictEqual(boot.length, 1);
  for (const l of [...un, ...chk]) assert.ok(l.replace(/^\/\/ @matchi-[a-z]+ /, '').length <= 300, 'over 300 characters: ' + l);
  assert.ok(/boot\.d\/30-owrt-vm\.sh$/.test(un[0]) && /\bstop$/.test(un[1]) && /\bgone$/.test(chk[0]));
  for (const l of [...un, ...chk]) if (l.includes('OWRT_DIR')) assert.ok(l.includes('OWRT_DIR=' + plug.D + ' '), l);
  assert.ok(lines.slice(0, 40).some((l) => /^\/\/ @matchi-name OpenWrt VM$/.test(l)), 'name in the first 40 lines');
  assert.strictEqual(path.basename(src.includes('OpenWrt_VM') ? plug.D : ''), 'OpenWrt_VM', 'data folder follows the file name OpenWrt_VM.js');
});
t('no timer under 30 s, no du, no /proc/PID/cmdline', () => {
  assert.ok(!/\bdu\b\s+-/.test(src.replace(/\/\/.*$/gm, '')));
  assert.ok(!/cmdline/.test(src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '')));
  const ms = [...src.matchAll(/setInterval\([^;]*?,\s*([A-Z_]+|\d+)\)/g)].map((x) => x[1]);
  for (const v of ms) assert.ok((v === 'REFRESH_MS' ? 30000 : Number(v)) >= 30000, 'timer ' + v);
});

// ---- the real script: its state answer must give a complete model ----
t('owrt-vm.sh state: every key the page needs, and nothing else', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'owrtp-'));
  try {
    const bin = path.join(tmp, 'bin'), dir = path.join(tmp, 'd');
    fs.mkdirSync(bin); fs.mkdirSync(dir);
    for (const c of ['ip', 'iptables']) { fs.writeFileSync(path.join(bin, c), '#!/bin/sh\nexit 1\n', { mode: 0o755 }); }
    for (const f of ['cloud-hypervisor', 'Image', 'rootfs.img']) fs.writeFileSync(path.join(dir, f), 'x');
    fs.writeFileSync(path.join(dir, 'VERSION'), '0.1.0\n');
    fs.writeFileSync(path.join(tmp, 'meminfo'), 'MemAvailable:     123456 kB\n');
    fs.writeFileSync(path.join(dir, 'vm.conf'), `MEMINFO=${tmp}/meminfo\nIPF=${tmp}/ipf\n`);
    fs.writeFileSync(path.join(tmp, 'ipf'), '0\n');
    const r = spawnSync('sh', [path.join(root, 'scripts/owrt-vm.sh'), 'state'], {
      env: { PATH: bin + ':' + process.env.PATH, OWRT_DIR: dir }, encoding: 'utf8' });
    assert.strictEqual(r.status, 0);
    const kv = plug.parseKv(r.stdout);
    assert.strictEqual(kv.other, 0, 'extra text in state: ' + r.stdout);
    assert.deepStrictEqual(Object.keys(kv.kv).sort(), [...plug.STATE_KEYS].sort());
    const m = plug.parseProbe(probe(r.stdout.trim()), true);
    assert.ok(m.state, 'page cannot use the real state answer');
    assert.deepStrictEqual(plug.describe(m).hero, { cls: '', text: 'Stopped' });
    assert.strictEqual(m.state.mem_avail_kb, '123456');
    assert.strictEqual(m.state.version, '0.1.0');
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

// ---- the page part, run against a small fake page and a fake device ----
class El {
  constructor(tag) { this.tag = tag; this._id = ''; this.children = []; this.dataset = {}; this.cls = new Set(); this.textContent = ''; this.innerHTML = ''; this.attrs = {}; this.disabled = false; this.onclick = null; this.style = {}; this.removed = false; }
  set id(v) { this._id = v; reg[v] = this; }
  get id() { return this._id; }
  get classList() { const c = this.cls; return { add: (x) => c.add(x), remove: (x) => c.delete(x), toggle: (x, f) => (f ? c.add(x) : c.delete(x)), contains: (x) => c.has(x) }; }
  set className(v) { this.cls = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get className() { return [...this.cls].join(' '); }
  appendChild(c) { this.children.push(c); return c; }
  remove() { this.removed = true; if (this.id && reg[this.id] === this) delete reg[this.id]; }
  querySelector(sel) { return this.q[sel] || null; }
  querySelectorAll(sel) { return sel === '[data-log]' ? this.logBtns : []; }
}
const reg = {};
function runPage(scenario) {
  const calls = [], toasts = [], cleared = [], intervals = [];
  const menu = new El('div');
  const doc = {
    hidden: false, head: new El('head'),
    createElement: (tag) => new El(tag),
    getElementById: (id) => reg[id] || null,
  };
  const modals = [];
  const matchi = {
    menu: () => menu, wait: () => Promise.resolve(), escapeHtml: (x) => String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    hasRoot: async () => scenario.root !== false, copy: async () => true, toast: (...a) => toasts.push(a),
    status: (el, on) => { el.dataset.status = String(on); },
    root: async (cmd) => { calls.push(cmd); return scenario.reply(cmd); },
    modal: {
      create: (o) => {
        const el = new El('div'); el.id = o.name; reg[o.name] = el;
        const mk = (cls) => { const e = new El('x'); e.className = cls; return e; };
        el.q = { '.ow-hero': mk('ow-hero'), '.ow-table': mk('ow-table'), '.ow-raw': mk('ow-raw'), '.ow-log': mk('ow-log'),
          '[data-act="refresh"]': new El('button'), '[data-act="copy"]': new El('button') };
        el.logBtns = [...o.content.matchAll(/data-log="([^"]+)"/g)].map((x) => { const b = new El('button'); b.dataset.log = x[1]; return b; });
        el.opts = o; modals.push(el);
        return { el, id: '#' + o.name };
      },
      show: () => {},
    },
  };
  const win = { matchi };
  const ctx = { window: win, document: doc, console, Promise, setInterval: (f, ms) => { intervals.push(ms); return intervals.length; }, clearInterval: (h) => cleared.push(h), String, Number, Object, Array, Set, Error };
  require('vm').runInNewContext(src, ctx);
  return { calls, toasts, cleared, intervals, menu, modals, win };
}
const tick = () => new Promise((r) => setImmediate(r));
const okReply = (state) => async (cmd) => ({ success: true, content: cmd.includes('@@files') ? probe(state) : 'line one\n\x1b[31mred\x1b[0m\nline three' });
(async () => {
  try {
    let p = runPage({ reply: okReply(STATE) });
    await tick();
    assert.strictEqual(p.menu.children.length, 1, 'button added to the Plugin actions box');
    const btn = p.menu.children[0];
    assert.strictEqual(btn.textContent, 'OpenWrt VM');
    assert.strictEqual(p.calls.length, 0, 'nothing runs before the window is opened');
    btn.onclick(); await tick(); await tick(); await tick();
    const w = p.modals[0];
    assert.ok(w, 'window created');
    assert.strictEqual(w.q['.ow-hero'].textContent, 'Running, pid 4242');
    assert.ok(w.q['.ow-hero'].cls.has('good'));
    assert.strictEqual(btn.dataset.status, 'true', 'dot follows the state');
    assert.ok(/Version<\/div><div class="ow-v ">0\.1\.0/.test(w.q['.ow-table'].innerHTML));
    assert.strictEqual(p.calls.length, 1, 'one root call for the whole status');
    assert.deepStrictEqual(p.intervals, [30000]);
    w.logBtns[0].onclick(); await tick(); await tick();
    assert.strictEqual(w.q['.ow-log'].textContent, 'line one\nred\nline three');
    assert.strictEqual(p.calls.length, 2);
    const allowed = new Set([plug.probeCommand(), ...plug.LOGS.map((l) => plug.logCommand(l[0]))]);
    assert.ok(p.calls.every((c) => allowed.has(c)), 'a command outside the read-only set was sent');
    w.q['[data-act="refresh"]'].onclick(); await tick(); await tick(); await tick();
    assert.strictEqual(p.calls.length, 3, 'refresh reads again');
    assert.strictEqual(w.opts.onClose(), true);
    assert.deepStrictEqual(p.cleared, [1], 'closing the window stops the timer');
    // a second copy of the plugin removes the first copy's button
    assert.strictEqual(typeof p.win.__matchi_owrt_vm_cleanup, 'function');
    n++;
    // no root: the window says so and runs nothing
    p = runPage({ root: false, reply: okReply(STATE) });
    await tick(); p.menu.children[0].onclick(); await tick(); await tick(); await tick();
    assert.strictEqual(p.modals[0].q['.ow-hero'].textContent, 'No root shell. This plugin needs root.');
    assert.strictEqual(p.calls.length, 0);
    n++;
    // root call fails: the window says it cannot read the device
    p = runPage({ reply: async () => { throw new Error('boom'); } });
    await tick(); p.menu.children[0].onclick(); await tick(); await tick(); await tick();
    assert.strictEqual(p.modals[0].q['.ow-hero'].textContent, 'Cannot read the device');
    assert.ok(/boom/.test(p.modals[0].q['.ow-raw'].textContent));
    n++;
    // an answer longer than the cap is cut to the end (the newest log lines)
    p = runPage({ reply: async (cmd) => ({ success: true, content: cmd.includes('@@files') ? probe(STATE) : 'x'.repeat(100000) + 'END' }) });
    await tick(); p.menu.children[0].onclick(); await tick(); await tick(); await tick();
    p.modals[0].logBtns[0].onclick(); await tick(); await tick();
    const lt = p.modals[0].q['.ow-log'].textContent;
    assert.ok(lt.length <= 65536 && lt.endsWith('END'), 'log text is capped and keeps the end');
    n++;
  } catch (e) { console.error('FAIL page part\n', e.stack || e.message); process.exitCode = 1; }
  console.log(process.exitCode ? 'FAILED' : 'ok: ' + n + ' tests');
})();

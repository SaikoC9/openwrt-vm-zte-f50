#!/usr/bin/env node
// Tests plugin/OpenWrt_VM_v1_0.js: its logic (settings, vm.conf merge, URLs, parsing) and its calls into a real sh
// (root writes, boot entry, state, start polling, release install). The window/dialog code is not run here.
// Run by hand: node tests/test_plugin.js
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { spawn, execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
// The tests build their own fake release, so the real release pin is cleared in memory (the file is not changed).
const pluginSrc = fs.readFileSync(path.join(root, 'plugin', 'OpenWrt_VM_v1_0.js'), 'utf8')
  .replace(/^(\s*const PIN_SUMS_SHA256 = ')[0-9a-f]*(';)/m, '$1$2');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'owrt-plugin-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));
let pass = 0; let fail = 0;
const ok = (name, cond) => { if (cond) { pass += 1; console.log(`ok   ${name}`); } else { fail += 1; console.log(`FAIL ${name}`); } };
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const DIR = path.join(tmp, 'owrt');
const BOOT = path.join(tmp, 'boot.d', '30-openwrt-vm.sh');
const FAKECURL = path.join(tmp, 'curl');

// fake curl: copies from the release folder named in the file:// URL
fs.writeFileSync(FAKECURL, `#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift 2 ;; --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
src=\${url#file://}
if [ -z "$out" ]; then cat "$src"; else cp "$src" "$out"; fi
`, { mode: 0o755 });

// a release built with the real packager
const build = path.join(tmp, 'build');
fs.mkdirSync(build);
fs.writeFileSync(path.join(build, 'cloud-hypervisor'), Buffer.alloc(5000, 7));
fs.writeFileSync(path.join(build, 'Image'), Buffer.alloc(8000, 9));
fs.writeFileSync(path.join(build, 'rootfs.img'), Buffer.concat([Buffer.alloc(3000, 3), Buffer.alloc(60000)]));
execFileSync('sh', ['-c', 'cd "$1" && sha256sum cloud-hypervisor Image rootfs.img > SHA256SUMS', 'x', build]);
const rel = path.join(tmp, 'rel');
execFileSync('bash', [path.join(root, 'scripts', 'owrt-release.sh'), '--build', build, '--version', '1.0.0', '--out', rel], { stdio: 'pipe' });

const T = { dir: DIR, bootFile: BOOT, curl: FAKECURL, base: `file://${rel}` };
const win = {
  __matchi_owrt_test: T,
  matchi: {
    root: (cmd) => new Promise((resolve) => {
      const p = spawn('sh', ['-c', cmd], { env: { ...process.env, OWRT_TEST: '1' } });
      let out = '';
      p.stdout.on('data', (d) => { out += d; });
      p.stderr.on('data', (d) => { out += d; });
      p.on('close', (code) => resolve({ success: code === 0, content: out }));
    }),
  },
};
const ctx = vm.createContext({ window: win, btoa: (s) => Buffer.from(s, 'binary').toString('base64'), TextEncoder, setTimeout, clearTimeout, console, Promise });

(async () => {
  await vm.runInContext(pluginSrc, ctx);
  const A = T.api;
  ok('plugin loads in test mode and exposes its api', A && typeof A.validateSettings === 'function');

  // ---- header the host reads
  ok('header: name, version, requires', /@matchi-name OpenWrt VM/.test(pluginSrc) && /@matchi-version 1\.0/.test(pluginSrc) && /@matchi-requires root, curl/.test(pluginSrc));
  ok('header: boot file and uninstall hooks are declared', /@matchi-boot \/data\/local\/matchitool\/boot\.d\/30-openwrt-vm\.sh/.test(pluginSrc) && (pluginSrc.match(/@matchi-uninstall/g) || []).length === 3 && /@matchi-check /.test(pluginSrc));
  ok('uninstall keeps backup/ and vm.conf is removed with the files', !/rm -rf [^\n]*backup/.test(pluginSrc.split('\n').filter((l) => l.includes('@matchi-uninstall')).join('\n')));

  // ---- installer copy
  ok('embedded installer equals scripts/owrt-install.sh', A.INSTALL_SH === fs.readFileSync(path.join(root, 'scripts', 'owrt-install.sh'), 'utf8'));

  // ---- validateSettings
  const good = { cpus: 2, mem: '256M', hotspot: true, expose: false, sshPort: 2223, webPort: 8081, dnsUp: '8.8.8.8', wanIf: 'sipa_eth0' };
  const v = A.validateSettings(good);
  ok('good settings validate; hotspot sets LAN, LAN_JOIN, GUEST_DHCP4 together', v.ok && v.clean.LAN === '1' && v.clean.LAN_JOIN === '1' && v.clean.GUEST_DHCP4 === '1' && v.clean.EXPOSE === '0');
  ok('hotspot off clears all three', ['LAN', 'LAN_JOIN', 'GUEST_DHCP4'].every((k) => A.validateSettings({ ...good, hotspot: false }).clean[k] === '0'));
  const bad = (o) => !A.validateSettings({ ...good, ...o }).ok;
  ok('rejects CPUs 0, 5, "2;id"', bad({ cpus: 0 }) && bad({ cpus: 5 }) && bad({ cpus: '2;id' }));
  ok('rejects a memory size that is not offered', bad({ mem: '256M;reboot' }) && bad({ mem: '1G' }));
  ok('rejects DNS with shell characters or a bad octet', bad({ dnsUp: '8.8.8.8;rm -rf /' }) && bad({ dnsUp: '8.8.8.256' }) && bad({ dnsUp: '$(id)' }) && bad({ dnsUp: '' }));
  ok('rejects an interface name with spaces, quotes or too long', bad({ wanIf: 'a b' }) && bad({ wanIf: "x'y" }) && bad({ wanIf: 'abcdefghijklmnop' }) && bad({ wanIf: '' }));
  ok('rejects equal ports, low ports and ports in use on the F50', bad({ sshPort: 8081 }) && bad({ sshPort: 22 }) && bad({ webPort: 2334 }) && bad({ sshPort: 5555 }) && bad({ webPort: 99999 }) && bad({ webPort: 'x' }));

  // ---- mergeConf
  const hand = 'START_SLEEP=1\n# my note\nCPUS=1\nHOST_LAN_IP=192.168.88.9\nEXPOSE=1\n';
  const merged = A.mergeConf(hand, v.clean);
  ok('mergeConf keeps hand-written lines and comments', /START_SLEEP=1/.test(merged) && /# my note/.test(merged) && /HOST_LAN_IP=192\.168\.88\.9/.test(merged));
  ok('mergeConf drops older assignments of managed keys outside the block', (merged.match(/^CPUS=/gm) || []).length === 1 && (merged.match(/^EXPOSE=/gm) || []).length === 1 && /^EXPOSE=0$/m.test(merged));
  ok('mergeConf is idempotent', A.mergeConf(merged, v.clean) === merged);
  const v2 = A.validateSettings({ ...good, cpus: 3, hotspot: false });
  const m2 = A.mergeConf(merged, v2.clean);
  ok('mergeConf replaces the plugin block on a second save', /^CPUS=3$/m.test(m2) && !/^CPUS=2$/m.test(m2) && /START_SLEEP=1/.test(m2) && (m2.match(/managed by the OpenWrt VM plugin/g) || []).length === 1);
  ok('mergeConf on an empty file writes just the block', A.mergeConf('', v.clean).startsWith('# --- managed by') && A.mergeConf(null, v.clean).includes('WAN_IF=sipa_eth0'));
  ok('confToSettings reads the block back', eq(A.confToSettings(merged), good));
  ok('confToSettings gives defaults for an empty file', A.confToSettings('').cpus === 2 && A.confToSettings('').hotspot === false && A.confToSettings('').mem === '256M');
  ok('confToSettings: hotspot needs all three keys', A.confToSettings('LAN=1\nLAN_JOIN=1\n').hotspot === false);

  // ---- parsing
  ok('parseKv reads key=value lines and ignores the rest', eq(A.parseKv('a=1\nnoise\nb=x=y\r\n'), { a: '1', b: 'x=y' }));
  const bk = A.parseBackups('20260101-000001 1200 1.0.0\n20260102-000001 1300 1.0.0\njunk\n20260103-000001 900');
  ok('parseBackups: newest first, size, release (may be empty)', bk.length === 3 && bk[0].name === '20260103-000001' && bk[0].release === '' && bk[2].kb === 1200 && bk[1].release === '1.0.0');
  ok('fmtMb and esc', A.fmtMb(2048) === '2.0 MB' && A.fmtMb(51200) === '50 MB' && A.esc('<a href="x">&\'') === '&lt;a href=&quot;x&quot;&gt;&amp;&#39;');

  // ---- luciUrl
  const base = { running: '1', lan: '1', joined: '1', lan_ip: '192.168.88.1', guest_ip: '192.168.66.2', expose: '0', web_port: '8081' };
  ok('luciUrl: page opened over the guest LAN -> LuCI on the guest LAN address', A.luciUrl(base, '192.168.88.2') === 'http://192.168.88.1/');
  ok('luciUrl: page opened over 192.168.0.x with expose on -> forwarded port', A.luciUrl({ ...base, lan: '0', joined: '0', expose: '1' }, '192.168.0.1') === 'http://192.168.0.1:8081/');
  ok('luciUrl: page opened on the phone itself -> guest address', A.luciUrl({ ...base, lan: '0', joined: '0' }, 'localhost') === 'http://192.168.66.2/');
  ok('luciUrl: VM stopped -> no link', A.luciUrl({ ...base, running: '0' }, '192.168.88.2') === null);
  ok('luciUrl: no way to reach it from this page -> no link', A.luciUrl({ ...base, lan: '0', joined: '0', expose: '0' }, '192.168.0.1') === null);

  // ---- boot file text
  const bf = A.bootFileText();
  ok('boot file: detached, backgrounded, calls the manager boot command', bf.startsWith('#!/system/bin/sh') && /setsid sh .*owrt-vm\.sh boot <\/dev\/null >\/dev\/null 2>&1 &\n/.test(bf) && bf.includes(`OWRT_DIR=${DIR}`));
  ok('boot file passes sh -n', (() => { const f = path.join(tmp, 'bf.sh'); fs.writeFileSync(f, bf); try { execFileSync('sh', ['-n', f]); return true; } catch (e) { return false; } })());

  // ---- real sh: root writes
  const odd = "line1\nit's \"quoted\" $HOME `id` \\n é€\n";
  await A.runRoot(A.writeFileCmd(path.join(tmp, 'w', 'odd.txt'), odd, 600));
  ok('writeFile: exact content incl. quotes, $, backticks, UTF-8; mode 600', fs.readFileSync(path.join(tmp, 'w', 'odd.txt'), 'utf8') === odd && (fs.statSync(path.join(tmp, 'w', 'odd.txt')).mode & 0o777) === 0o600);
  const r = await A.runRoot(A.writeFileCmd('/proc/owrt-nope/x', 'a', 600));
  ok('writeFile into an impossible path reports FILE_WRITE_FAILED and leaves no temp', r.text.includes('FILE_WRITE_FAILED') && !r.ok);

  // ---- boot entry
  ok('bootOn is false before', (await A.bootOn()) === false);
  await A.setBoot(true);
  ok('setBoot(true) writes an executable root-only file and bootOn sees it', (await A.bootOn()) === true && (fs.statSync(BOOT).mode & 0o777) === 0o700 && fs.readFileSync(BOOT, 'utf8') === bf);
  await A.setBoot(false);
  ok('setBoot(false) removes it', !fs.existsSync(BOOT) && (await A.bootOn()) === false);

  // ---- state without and with a manager
  let st = await A.getState(false);
  ok('getState before install: installed=0', st.installed === '0');

  // ---- install the release through the plugin (real installer, fake curl, real packager output)
  const seen = [];
  const done = await A.installRelease((s) => seen.push(s.phase));
  ok('installRelease: finishes with phase done and reports progress phases', done.phase === 'done' && seen.length > 0 && seen[seen.length - 1] === 'done');
  ok('installRelease: files in place and the installer was written 755', fs.readFileSync(path.join(DIR, 'VERSION'), 'utf8').trim() === '1.0.0' && fs.existsSync(path.join(DIR, 'Image')) && (fs.statSync(path.join(DIR, 'owrt-install.sh')).mode & 0o777) === 0o755 && fs.existsSync(path.join(DIR, 'owrt-vm.sh')));
  ok('installRelease: reports unpinned while PIN_SUMS_SHA256 is empty', done.unpinned === '1');
  st = await A.getState(false);
  ok('getState after install: installed=1, release 1.0.0, not running, no leftovers', st.installed === '1' && st.running === '0' && st.release === '1.0.0' && st.manager_api === '1' && st.file_rootfs_img === '1' && st.leftovers === '0');

  // ---- settings end to end
  await fs.promises.writeFile(path.join(DIR, 'vm.conf'), 'START_SLEEP=1\nCPUS=1\n');
  await A.saveSettings({ ...good, cpus: 4, hotspot: false });
  const conf = fs.readFileSync(path.join(DIR, 'vm.conf'), 'utf8');
  ok('saveSettings: merged into vm.conf, file is root-only', /START_SLEEP=1/.test(conf) && /^CPUS=4$/m.test(conf) && !/^CPUS=1$/m.test(conf) && (fs.statSync(path.join(DIR, 'vm.conf')).mode & 0o777) === 0o600);
  st = await A.getState(false);
  ok('the real manager reads the saved settings back', st.cpus === '4' && st.lan === '0' && st.mem === '256M');
  let threw = false;
  try { await A.saveSettings({ ...good, dnsUp: '1.1.1.1;reboot' }); } catch (e) { threw = /DNS/.test(e.message); }
  ok('saveSettings with a bad value throws and leaves vm.conf alone', threw && fs.readFileSync(path.join(DIR, 'vm.conf'), 'utf8') === conf);

  // ---- start polling against a stub manager (the real start is covered by test_owrt_vm.sh)
  const real = fs.readFileSync(path.join(DIR, 'owrt-vm.sh'));
  const stub = (rc) => `#!/bin/sh\ncase $1 in start-bg) ( echo "owrt-vm: booting"; sleep 1; echo "owrt-vm: guest answers"; echo "owrt-vm: start finished rc=${rc}" ) > "$OWRT_DIR/start.log" 2>&1 & echo "owrt-vm: start requested" ;; *) exit 0 ;; esac\n`;
  fs.writeFileSync(path.join(DIR, 'owrt-vm.sh'), stub(0), { mode: 0o755 });
  const lines = [];
  let sr = await A.startVm((l) => lines.push(l));
  ok('startVm: waits for "start finished" and returns rc 0 with the log', sr.rc === 0 && /guest answers/.test(sr.log) && lines.length > 0);
  fs.writeFileSync(path.join(DIR, 'owrt-vm.sh'), stub(1), { mode: 0o755 });
  sr = await A.startVm();
  ok('startVm: a failing start returns its rc', sr.rc === 1);
  fs.writeFileSync(path.join(DIR, 'owrt-vm.sh'), real, { mode: 0o755 });

  // ---- install errors surface as exceptions with the installer's message
  fs.rmSync(path.join(rel, 'Image'));
  fs.rmSync(path.join(DIR, 'install'), { recursive: true, force: true });
  let msg = '';
  try { await A.installRelease(); } catch (e) { msg = e.message; }
  ok('installRelease: a missing release file throws with the file name', /download of Image failed/.test(msg));

  console.log(`passed ${pass}, failed ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });

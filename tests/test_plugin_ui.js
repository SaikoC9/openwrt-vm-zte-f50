#!/usr/bin/env node
// Browser test of the plugin window: loads the plugin into a fake MatchiTOOL page (headless Chromium) whose root shell is a
// real sh in a temp folder, then clicks through install, settings, start, LuCI link and backups.
// Skipped when puppeteer-core or Chromium is missing. Run by hand: node tests/test_plugin_ui.js
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

let puppeteer;
try { puppeteer = require('puppeteer-core'); } catch (_) { try { puppeteer = require('puppeteer'); } catch (e) { console.log('skipped: plugin UI test (no puppeteer)'); process.exit(0); } }
const CHROME = process.env.CHROME_PATH || ['/opt/pw-browsers/chromium-1243/chrome-linux64/chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].find((p) => fs.existsSync(p));
if (!CHROME) { console.log('skipped: plugin UI test (no Chromium)'); process.exit(0); }

const root = path.join(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'owrt-ui-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));
let pass = 0; let fail = 0;
const ok = (name, cond) => { if (cond) { pass += 1; console.log(`ok   ${name}`); } else { fail += 1; console.log(`FAIL ${name}`); } };

const DIR = path.join(tmp, 'owrt');
const BOOT = path.join(tmp, 'boot.d', '30-openwrt-vm.sh');
const CURL = path.join(tmp, 'curl');
fs.writeFileSync(CURL, `#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift 2 ;; --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
src=\${url#file://}
if [ -z "$out" ]; then cat "$src"; else cp "$src" "$out"; fi
`, { mode: 0o755 });
const build = path.join(tmp, 'build'); fs.mkdirSync(build);
fs.writeFileSync(path.join(build, 'cloud-hypervisor'), Buffer.alloc(5000, 7));
fs.writeFileSync(path.join(build, 'Image'), Buffer.alloc(8000, 9));
fs.writeFileSync(path.join(build, 'rootfs.img'), Buffer.concat([Buffer.alloc(3000, 3), Buffer.alloc(60000)]));
execFileSync('sh', ['-c', 'cd "$1" && sha256sum cloud-hypervisor Image rootfs.img > SHA256SUMS', 'x', build]);
const rel = path.join(tmp, 'rel');
execFileSync('bash', [path.join(root, 'scripts', 'owrt-release.sh'), '--build', build, '--version', '1.0.0', '--out', rel], { stdio: 'pipe' });

// the plugin with its device paths and release URL pointed at the temp folder
const src = fs.readFileSync(path.join(root, 'plugin', 'OpenWrt_VM_v1_0.js'), 'utf8')
  .replace(/^(\s*const PIN_SUMS_SHA256 = ')[0-9a-f]*(';)/m, '$1$2')
  .split('/data/local/matchi_owrt').join(DIR)
  .split('/data/local/matchitool/boot.d/30-openwrt-vm.sh').join(BOOT)
  .split('/data/data/com.matchi.tool/files/curl').join(CURL)
  .replace('https://github.com/${REPO}/releases/download/${RELEASE_TAG}', `file://${rel}`)
  .replace('https://github.com/${REPO}/releases/latest/download', `file://${rel}`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--no-sandbox', '--disable-gpu'] });
  const page = await browser.newPage({ viewport: { width: 380, height: 820 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.exposeFunction('__root', (cmd) => new Promise((resolve) => {
    const p = spawn('sh', ['-c', cmd], { env: { ...process.env, OWRT_TEST: '1' } });
    let out = '';
    p.stdout.on('data', (d) => { out += d; }); p.stderr.on('data', (d) => { out += d; });
    p.on('close', (code) => resolve({ success: code === 0, content: out }));
  }));
  await page.setContent('<html><body style="background:#0c1626;color:#e8eefc;font-family:sans-serif;margin:0"><div id="home"><div class="actions-buttons"></div></div></body></html>');
  await page.evaluate(() => {
    window.__toasts = []; window.__opened = [];
    window.confirm = () => true;
    window.open = (u) => { window.__opened.push(u); };
    window.matchi = {
      root: (c) => window.__root(c),
      toast: (m) => window.__toasts.push(m),
      modal: {
        create: ({ name, content, onClose }) => { const d = document.createElement('div'); d.id = name; d.innerHTML = content; document.body.appendChild(d); return { id: name, el: d }; },
        show: () => {},
      },
    };
  });
  await page.addScriptTag({ content: src });
  const text = (sel) => page.$eval(sel, (e) => e.textContent).catch(() => null);
  const waitText = async (sel, re, ms = 20000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const t = await text(sel); if (t && re.test(t)) return t; await sleep(200); } return await text(sel); };
  const click = (sel) => page.click(sel);

  await page.waitForSelector('#matchi_owrt_btn', { timeout: 5000 });
  ok('the plugin adds its button to the home button grid', true);
  await click('#matchi_owrt_btn');
  await page.waitForSelector('#matchi_owrt_modal #ow_hero', { timeout: 10000 });
  ok('clicking the button opens the window', true);
  ok('before install: "Not installed" is shown, Start is hidden', /Not installed/.test(await waitText('#ow_hero', /Not installed/)) && await page.$eval('#ow_start', (e) => e.style.display) === 'none');

  // install through the window
  ok('everything is on one screen: settings and maintenance are open, no tabs', await page.$$eval('#matchi_owrt_modal details[open]', (d) => d.length) === 2 && !(await page.$('#matchi_owrt_modal .ow-tab')));
  ok('the pinned/unpinned note is shown', /Unpinned/.test(await text('#ow_pinnote')));
  await click('#ow_install');
  const stopped = await waitText('#ow_hero', /Stopped/, 30000);
  ok('Install: the window ends on "Stopped" and the files are on disk', /Stopped/.test(stopped) && fs.existsSync(path.join(DIR, 'rootfs.img')) && fs.readFileSync(path.join(DIR, 'VERSION'), 'utf8').trim() === '1.0.0');
  ok('Install: a toast said it was installed (unpinned warning)', (await page.evaluate(() => window.__toasts)).some((t) => /Installed v1\.0\.0/.test(t)));
  ok('the Release tile shows the installed release and the button says Reinstall', /^1\.0\.0 · unpinned$/.test(await text('#ow_rel')) && (await text('#ow_install')) === 'Reinstall');
  ok('after install: Start is visible, Stop and Test are hidden', await page.$eval('#ow_start', (e) => e.style.display) === '' && await page.$eval('#ow_stop', (e) => e.style.display) === 'none');

  // settings
  await sleep(1200);
  ok('Settings are filled from the defaults', await page.$eval('#ow_cpus', (e) => e.value) === '2' && await page.$eval('#ow_mem_sel', (e) => e.value) === '256M' && await page.$eval('#ow_ssh', (e) => e.value) === '2223');
  await page.$eval('#ow_cpus', (e) => { e.value = '3'; });
  await page.$eval('#ow_hotspot', (e) => { e.checked = true; });
  await page.$eval('#ow_boot', (e) => { e.checked = true; });
  await click('#ow_save');
  await sleep(2500);
  const conf = fs.existsSync(path.join(DIR, 'vm.conf')) ? fs.readFileSync(path.join(DIR, 'vm.conf'), 'utf8') : '';
  ok('Save: vm.conf has CPUS=3 and the three hotspot keys', /^CPUS=3$/m.test(conf) && /^LAN=1$/m.test(conf) && /^LAN_JOIN=1$/m.test(conf) && /^GUEST_DHCP4=1$/m.test(conf));
  ok('Save with "Start with the phone": the boot entry exists', fs.existsSync(BOOT));
  await page.$eval('#ow_dns', (e) => { e.value = '8.8.8.8;reboot'; });
  const before = fs.readFileSync(path.join(DIR, 'vm.conf'), 'utf8');
  await click('#ow_save');
  await sleep(1500);
  ok('Save with a bad DNS value: refused, toast shown, vm.conf unchanged', (await page.evaluate(() => window.__toasts)).some((t) => /DNS must be/.test(t)) && fs.readFileSync(path.join(DIR, 'vm.conf'), 'utf8') === before);
  await page.$eval('#ow_dns', (e) => { e.value = '8.8.8.8'; });

  // reinstall keeps the previous release, roll back swaps it in
  await click('#ow_install');
  for (let i = 0; i < 150; i += 1) { if ((await page.evaluate(() => window.__toasts)).filter((t) => /Installed v1\.0\.0/.test(t)).length >= 2) break; await sleep(200); }
  await sleep(500);
  ok('Reinstall: the previous release is kept in prev/', fs.existsSync(path.join(DIR, 'prev')));
  await click('#ow_rollback');
  await sleep(2500);
  ok('Roll back: a toast says so and the files are still in place', (await page.evaluate(() => window.__toasts)).some((t) => /Rolled back/.test(t)) && fs.existsSync(path.join(DIR, 'rootfs.img')));
  await click('#ow_checkup');
  ok('Check: it reads the latest release and says the plugin is up to date', /Latest release is 1\.0\.0: this plugin is up to date/.test(await waitText('#ow_prog_txt', /Latest release/, 20000)));

  // start / running view with a stub manager
  fs.writeFileSync(path.join(DIR, 'owrt-vm.sh'), `#!/bin/sh
case $1 in
  state) cat "$OWRT_DIR/stub.state" ;;
  stop) cp "$OWRT_DIR/stub.stopped" "$OWRT_DIR/stub.state"; echo "owrt-vm: stopped" ;;
  unjoin) sed -i 's/^joined=1/joined=0/' "$OWRT_DIR/stub.state"; echo "owrt-vm: unjoined" ;;
  join) sed -i 's/^joined=0/joined=1/' "$OWRT_DIR/stub.state"; echo "owrt-vm: joined" ;;
  logs) echo "stub logs line" ;;
  check) echo "stub check ok" ;;
  backup) echo "20260103-120000 20520 1.0.0" >> "$OWRT_DIR/stub.backups"; echo "owrt-vm: backup done" ;;
  backup-del) sed -i '$d' "$OWRT_DIR/stub.backups"; echo deleted ;;
  restore) echo "restored $2" ;;
  start-bg) ( echo "owrt-vm: guest answers"; echo "owrt-vm: start finished rc=0"; cp "$OWRT_DIR/stub.running" "$OWRT_DIR/stub.state" ) > "$OWRT_DIR/start.log" 2>&1 & echo requested ;;
  backups) cat "$OWRT_DIR/stub.backups" ;;
  *) echo "stub $1" ;;
esac
`, { mode: 0o755 });
  fs.writeFileSync(path.join(DIR, 'stub.backups'), '20260101-120000 20480 1.0.0\n20260102-120000 20500 1.0.0\n');
  fs.writeFileSync(path.join(DIR, 'stub.stopped'), 'manager_api=1\nrelease=1.0.0\nrunning=0\ninstalled=1\nleftovers=0\nlan=1\nlan_ip=192.168.88.1\nguest_ip=192.168.66.2\nexpose=0\nweb_port=8081\nssh_port=2223\n');
  fs.writeFileSync(path.join(DIR, 'stub.state'), 'manager_api=1\nrelease=1.0.0\nrunning=0\ninstalled=1\nleftovers=0\nlan=1\nlan_ip=192.168.88.1\nguest_ip=192.168.66.2\nexpose=0\nweb_port=8081\nssh_port=2223\n');
  fs.writeFileSync(path.join(DIR, 'stub.running'), 'manager_api=1\nrelease=1.0.0\nrunning=1\ncpus=3\nmem=256M\nmem_avail_kb=421888\netime=00:42\njoined=1\ninstalled=1\nleftovers=0\nlan=1\nlan_ip=192.168.88.1\nguest_ip=192.168.66.2\nexpose=0\nweb_port=8081\nssh_port=2223\nguest_ping=1\nluci=1\n');
  await click('#ow_refresh');
  await sleep(1000);
  await click('#ow_start');
  const run = await waitText('#ow_hero', /Running/, 20000);
  ok('Start: the status turns to Running with uptime and "serving the hotspot"', /^Running$/.test(run) && /up 00:42 · LuCI ready · serving the hotspot/.test(await text('#ow_sub')));
  ok('Running: tiles show VM size, phone memory and hotspot mode', await text('#ow_vm') === '3 CPU · 256M' && await text('#ow_mem') === '412 MB' && await text('#ow_hs') === 'OpenWrt serves');
  ok('Running: Stop, Test, Open LuCI visible; Start hidden', await page.$eval('#ow_stop', (e) => e.style.display) === '' && await page.$eval('#ow_luci', (e) => e.style.display) === '' && await page.$eval('#ow_start', (e) => e.style.display) === 'none');
  ok('Running: access card names LuCI on the guest LAN address', /LuCI\s+http:\/\/(192\.168\.88\.1|192\.168\.66\.2)\//.test(await text('#ow_access')) && /root@192\.168\.88\.1/.test(await text('#ow_ssh_txt')));
  await click('#ow_luci');
  ok('Open LuCI opens a URL', (await page.evaluate(() => window.__opened)).length === 1);

  // hotspot join / leave
  ok('Hotspot: running and joined shows Leave hotspot, hides Join', await page.$eval('#ow_unjoin', (e) => e.style.display) === '' && await page.$eval('#ow_join', (e) => e.style.display) === 'none');
  await click('#ow_unjoin');
  await waitText('#ow_hs', /Not joined yet/, 15000);
  ok('Leave hotspot: the tile says Not joined yet and Join hotspot appears', /Not joined yet/.test(await text('#ow_hs')) && await page.$eval('#ow_join', (e) => e.style.display) === '');
  await click('#ow_join');
  await waitText('#ow_hs', /OpenWrt serves/, 15000);
  ok('Join hotspot: asks, runs, and the tile says OpenWrt serves', /OpenWrt serves/.test(await text('#ow_hs')) && /joined/.test(await text('#ow_log')));

  // test, copy, logs, report
  await click('#ow_test');
  await sleep(1500);
  ok('Test: shows the output in the log box and a toast', (await page.$eval('#ow_logbox', (e) => e.style.display)) === '' && /stub test/.test(await text('#ow_log')) && (await page.evaluate(() => window.__toasts)).some((t) => /Test passed/.test(t)));
  await click('#ow_logx');
  ok('Hide closes the log box', (await page.$eval('#ow_logbox', (e) => e.style.display)) === 'none');
  await click('#ow_copy_luci');
  await click('#ow_copy_ssh');
  await sleep(500);
  ok('Copy buttons: a toast confirms or shows the text to copy', (await page.evaluate(() => window.__toasts)).filter((t) => /^Copied$|Could not copy/.test(t)).length >= 2);
  await page.evaluate(() => { document.querySelectorAll('#matchi_owrt_modal details')[2].open = true; });
  await click('#ow_logs');
  ok('Show logs: the manager logs appear', /stub logs line/.test(await waitText('#ow_log', /stub logs line/, 10000)));
  await click('#ow_copy');
  await sleep(1500);
  ok('Copy report: copied, or shown in the log box when the clipboard is blocked', (await page.evaluate(() => window.__toasts)).some((t) => /Report copied|Could not copy; the report is shown above/.test(t)));

  // backups
  await click('#ow_backup');
  await waitText('#ow_backups', /2026-01-03/, 10000);
  let rows = await page.$$eval('#ow_backups .ow-brow', (r) => r.map((e) => ({ t: e.textContent, del: !!e.querySelector('[aria-label="Delete backup"]') })));
  ok('Back up now: the new backup is listed first with Restore and a delete button', rows.length === 3 && /2026-01-03 12:00:00/.test(rows[0].t) && /20 MB/.test(rows[0].t) && rows[0].t.includes('Restore') && rows[0].del);
  ok('Back up now: a toast says it is done', (await page.evaluate(() => window.__toasts)).some((t) => /Backup done/.test(t)));
  await page.click('#ow_backups .ow-brow:first-child [aria-label="Delete backup"]');
  await sleep(2000);
  rows = await page.$$eval('#ow_backups .ow-brow', (r) => r.map((e) => e.textContent));
  ok('Delete: the backup is removed from the list', rows.length === 2 && /2026-01-02/.test(rows[0]));
  await page.evaluate(() => { [...document.querySelectorAll('#ow_backups .ow-brow button')].find((b) => b.textContent === 'Restore').click(); });
  await sleep(2000);
  ok('Restore: asks, runs, and a toast says it is restored', (await page.evaluate(() => window.__toasts)).some((t) => /Backup restored/.test(t)));

  // layout: compact buttons, nothing wider than the phone
  const m = await page.evaluate(() => {
    const wrap = document.querySelector('#matchi_owrt_modal .ow-wrap');
    const heights = [...document.querySelectorAll('#matchi_owrt_modal button')].filter((b) => b.offsetParent).map((b) => b.getBoundingClientRect().height);
    return { over: wrap.scrollWidth - wrap.clientWidth, maxBtn: Math.max(...heights), n: heights.length };
  });
  ok('Layout: no sideways scroll at 380 px and every button is 26 px or shorter', m.over <= 0 && m.maxBtn <= 26);
  if (process.env.OWRT_SHOT) await page.evaluate(() => { document.querySelector('#matchi_owrt_modal .ow-wrap').scrollTop = 0; });
  if (process.env.OWRT_SHOT) await (await page.$('#matchi_owrt_modal')).screenshot({ path: process.env.OWRT_SHOT });

  // stop, then remove
  await click('#ow_stop');
  const stoppedHero = await waitText('#ow_hero', /Stopped/, 15000);
  ok('Stop: the status turns to Stopped, Start shows, Stop and LuCI hide', /Stopped/.test(stoppedHero) && await page.$eval('#ow_start', (e) => e.style.display) === '' && await page.$eval('#ow_stop', (e) => e.style.display) === 'none' && await page.$eval('#ow_accesscard', (e) => e.style.display) === 'none');
  ok('Stop: a toast says the VM stopped', (await page.evaluate(() => window.__toasts)).some((t) => /VM stopped/.test(t)));
  await click('#ow_remove');
  const gone = await waitText('#ow_hero', /Not installed/, 20000);
  ok('Remove: the status turns to Not installed, the VM files and the boot entry are gone', /Not installed/.test(gone) && !fs.existsSync(path.join(DIR, 'rootfs.img')) && !fs.existsSync(path.join(DIR, 'vm.conf')) && !fs.existsSync(BOOT));

  ok('no JavaScript errors in the page', errors.length === 0);
  if (errors.length) console.log(errors.join('\n'));
  await browser.close();
  console.log(`passed ${pass}, failed ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });

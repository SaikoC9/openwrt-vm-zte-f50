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
  .replace('https://github.com/${REPO}/releases/download/${RELEASE_TAG}', `file://${rel}`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--no-sandbox', '--disable-gpu'] });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.exposeFunction('__root', (cmd) => new Promise((resolve) => {
    const p = spawn('sh', ['-c', cmd], { env: { ...process.env, OWRT_TEST: '1' } });
    let out = '';
    p.stdout.on('data', (d) => { out += d; }); p.stderr.on('data', (d) => { out += d; });
    p.on('close', (code) => resolve({ success: code === 0, content: out }));
  }));
  await page.setContent('<html><body><div id="home"><div class="actions-buttons"></div></div></body></html>');
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
  await page.evaluate(() => document.querySelector('[data-tab="mnt"]').click());
  ok('the pinned/unpinned note is shown', /Unpinned/.test(await text('#ow_pinnote')));
  await click('#ow_install');
  const stopped = await waitText('#ow_hero', /Stopped/, 30000);
  ok('Install: the window ends on "Stopped" and the files are on disk', /Stopped/.test(stopped) && fs.existsSync(path.join(DIR, 'rootfs.img')) && fs.readFileSync(path.join(DIR, 'VERSION'), 'utf8').trim() === '1.0.0');
  ok('Install: a toast said it was installed (unpinned warning)', (await page.evaluate(() => window.__toasts)).some((t) => /Installed v1\.0\.0/.test(t)));
  ok('the release line shows the installed release', /Release installed: 1\.0\.0/.test(await text('#ow_rel')));
  ok('after install: Start is visible, Stop and Test are hidden', await page.$eval('#ow_start', (e) => e.style.display) === '' && await page.$eval('#ow_stop', (e) => e.style.display) === 'none');

  // settings
  await page.evaluate(() => document.querySelector('[data-tab="set"]').click());
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

  // start / running view with a stub manager
  fs.writeFileSync(path.join(DIR, 'owrt-vm.sh'), `#!/bin/sh
case $1 in
  state) cat "$OWRT_DIR/stub.state" ;;
  start-bg) ( echo "owrt-vm: guest answers"; echo "owrt-vm: start finished rc=0"; cp "$OWRT_DIR/stub.running" "$OWRT_DIR/stub.state" ) > "$OWRT_DIR/start.log" 2>&1 & echo requested ;;
  backups) echo "20260101-120000 20480 1.0.0"; echo "20260102-120000 20500 1.0.0" ;;
  *) echo "stub $1" ;;
esac
`, { mode: 0o755 });
  fs.writeFileSync(path.join(DIR, 'stub.state'), 'manager_api=1\nrelease=1.0.0\nrunning=0\ninstalled=1\nleftovers=0\nlan=1\nlan_ip=192.168.88.1\nguest_ip=192.168.66.2\nexpose=0\nweb_port=8081\nssh_port=2223\n');
  fs.writeFileSync(path.join(DIR, 'stub.running'), 'manager_api=1\nrelease=1.0.0\nrunning=1\netime=00:42\njoined=1\ninstalled=1\nleftovers=0\nlan=1\nlan_ip=192.168.88.1\nguest_ip=192.168.66.2\nexpose=0\nweb_port=8081\nssh_port=2223\nguest_ping=1\nluci=1\n');
  await page.evaluate(() => document.querySelector('[data-tab="main"]').click());
  await click('#ow_refresh');
  await sleep(1000);
  await click('#ow_start');
  const run = await waitText('#ow_hero', /Running/, 20000);
  ok('Start: the hero turns to Running with uptime and "serving the hotspot"', /Running \(up 00:42, LuCI ready, serving the hotspot\)/.test(run));
  ok('Running: Stop, Test, Open LuCI visible; Start hidden', await page.$eval('#ow_stop', (e) => e.style.display) === '' && await page.$eval('#ow_luci', (e) => e.style.display) === '' && await page.$eval('#ow_start', (e) => e.style.display) === 'none');
  ok('Running: access note names LuCI on the guest LAN address', /LuCI: http:\/\/(192\.168\.88\.1|192\.168\.66\.2)\//.test(await text('#ow_access')));
  await click('#ow_luci');
  ok('Open LuCI opens a URL', (await page.evaluate(() => window.__opened)).length === 1);

  // backups list
  await page.evaluate(() => document.querySelector('[data-tab="mnt"]').click());
  await sleep(1500);
  const rows = await page.$$eval('#ow_backups .ow-brow', (r) => r.map((e) => e.textContent));
  ok('Backups: both listed, newest first, with Restore and Delete buttons', rows.length === 2 && /2026-01-02 12:00:00/.test(rows[0]) && /20 MB/.test(rows[0]) && rows[0].includes('Restore') && rows[0].includes('Delete'));

  ok('no JavaScript errors in the page', errors.length === 0);
  if (errors.length) console.log(errors.join('\n'));
  await browser.close();
  console.log(`passed ${pass}, failed ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });

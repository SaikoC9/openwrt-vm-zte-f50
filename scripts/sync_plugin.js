#!/usr/bin/env node
// Copies scripts/owrt-install.sh into the INSTALL_SH block of plugin/OpenWrt_VM_v1_0.js.
//   node scripts/sync_plugin.js          rewrite the plugin
//   node scripts/sync_plugin.js --check  only report whether they match (exit 1 if not)
'use strict';
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const pluginPath = path.join(root, 'plugin', 'OpenWrt_VM_v1_0.js');
const script = fs.readFileSync(path.join(root, 'scripts', 'owrt-install.sh'), 'utf8');
const literal = '`' + script.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$\{/g, '\\${') + '`';
const src = fs.readFileSync(pluginPath, 'utf8');
const re = /(\/\/ @@INSTALL_SH_BEGIN\n  const INSTALL_SH = )[\s\S]*?(;\n  \/\/ @@INSTALL_SH_END)/;
if (!re.test(src)) { console.error('sync_plugin: INSTALL_SH markers not found'); process.exit(2); }
const out = src.replace(re, (_, a, b) => a + literal + b);
if (process.argv.includes('--check')) {
  if (out !== src) { console.error('plugin INSTALL_SH differs from scripts/owrt-install.sh: run node scripts/sync_plugin.js'); process.exit(1); }
  console.log('plugin INSTALL_SH matches scripts/owrt-install.sh');
} else {
  fs.writeFileSync(pluginPath, out);
  console.log('plugin updated from scripts/owrt-install.sh');
}

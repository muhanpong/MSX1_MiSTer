//  Drives packbuilder.html in headless Chromium for test_packbuilder.sh.
//
//    node test_packbuilder.js <page.html> <ROM dir> <fresh.json> <out.zip>
//
//  1. Loads every file under <ROM dir> through the page's own file input.
//  2. Fails if the page's embedded DATA differs from <fresh.json>
//     (packbuilder_extract.py run on the current XMLs): a stale page offers
//     packs the XMLs retired and lacks packs they added.
//  3. Presses the page's own "download all buildable packs" button and saves the
//     ZIP it offers to <out.zip>, so the folder layout is tested too, not only
//     the pack bytes.
//
//  Needs playwright-core (npm i playwright-core; NODE_PATH or a local node_modules)
//  and a Chromium: $CHROME, else the newest ~/.cache/ms-playwright headless shell.
const fs = require('fs'), path = require('path'), os = require('os');
const { chromium } = require('playwright-core');

const [page_html, rom_dir, fresh_json, out_zip] = process.argv.slice(2);
if (!out_zip) { console.error('usage: node test_packbuilder.js <page.html> <ROM dir> <fresh.json> <out.zip>'); process.exit(2); }

function chrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const base = path.join(os.homedir(), '.cache', 'ms-playwright');
  const dirs = fs.existsSync(base) ? fs.readdirSync(base).filter(d => d.startsWith('chromium_headless_shell-')).sort() : [];
  for (const d of dirs.reverse()) {
    const p = path.join(base, d, 'chrome-headless-shell-linux64', 'chrome-headless-shell');
    if (fs.existsSync(p)) return p;
  }
  throw new Error('no Chromium: set $CHROME');
}
const walk = d => fs.readdirSync(d, { withFileTypes: true })
  .flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);

(async () => {
  const br = await chromium.launch({ executablePath: chrome() });
  const ctx = await br.newContext({ acceptDownloads: true, locale: 'en-US' });
  const p = await ctx.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file://' + path.resolve(page_html));

  const fresh = JSON.parse(fs.readFileSync(fresh_json, 'utf8'));
  const same = await p.evaluate(f => JSON.stringify(DATA) === JSON.stringify(f), fresh);
  const names = await p.evaluate(() => DATA.machines.map(m => m.name));
  const want = fresh.machines.map(m => m.name);
  console.log(`DATA: page ${names.length} machines, XMLs ${want.length}: ${same ? 'same' : 'DIFFERENT'}`);
  if (!same) {
    for (const n of names.filter(n => !want.includes(n))) console.log('  only in page: ' + n);
    for (const n of want.filter(n => !names.includes(n))) console.log('  only in XMLs: ' + n);
  }

  const files = walk(rom_dir);
  await p.setInputFiles('input[type=file]:not([webkitdirectory])', files);
  await p.waitForFunction(n => filesRead >= n, files.length, { timeout: 600000 });
  await p.waitForTimeout(500);
  const st = await p.evaluate(() => ({ store: store.size, synth: [...synthed.values()].map(o => o.name),
    ready: DATA.machines.filter(m => state(m).k !== 'blocked').length }));
  console.log(`page: ${files.length} files read, ${st.store} kept, ${st.ready} packs buildable, synthesized: ${st.synth.join(' ') || '-'}`);

  const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 600000 }), p.click('#buildAll')]);
  await dl.saveAs(out_zip);
  console.log('page ZIP: ' + dl.suggestedFilename());
  if (errs.length) console.log('page errors: ' + errs.join(' | '));
  await br.close();
  process.exit(same && !errs.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });

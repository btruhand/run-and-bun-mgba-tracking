#!/usr/bin/env node
// Interactively creates the two clasp project files, which are gitignored because they hold script IDs:
//   .clasp.json      prod script, rootDir "appsscript"  (used by plain `clasp` commands)
//   .clasp.dev.json  dev script                         (used by `npm run deploy:dev`)
// Pass --dir <path> to write somewhere other than the repo root.
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const dirIdx = process.argv.indexOf('--dir');
const outDir = dirIdx > 0 ? path.resolve(process.argv[dirIdx + 1]) : path.join(__dirname, '..');
const files = {
  prod: path.join(outDir, '.clasp.json'),
  dev: path.join(outDir, '.clasp.dev.json'),
};

function existingId(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')).scriptId || '';
  } catch {
    return '';
  }
}

const looksLikeScriptId = (s) => /^[A-Za-z0-9_-]{20,}$/.test(s);
const mask = (s) => (s.length > 10 ? `${s.slice(0, 4)}…${s.slice(-4)}` : s);

// Line queue so piped input isn't dropped before a prompt is waiting.
const rl = readline.createInterface({ input: process.stdin, terminal: false });
const queue = [];
let waiter = null;
let closed = false;
rl.on('line', (l) => (waiter ? ((w) => { waiter = null; w.resolve(l); })(waiter) : queue.push(l)));
rl.on('close', () => {
  closed = true;
  if (waiter) waiter.reject(new Error('input ended before setup finished'));
});
function question(prompt) {
  process.stdout.write(prompt);
  return new Promise((resolve, reject) => {
    if (queue.length) return resolve(queue.shift());
    if (closed) return reject(new Error('input ended before setup finished'));
    waiter = { resolve, reject };
  });
}

async function ask(label, help, current) {
  console.log(`\n${label}\n  ${help}`);
  for (;;) {
    const suffix = current ? ` [Enter to keep ${mask(current)}]` : '';
    const answer = (await question(`  Script ID${suffix}: `)).trim();
    const value = answer || current;
    if (!value) {
      console.log('  A script ID is required.');
    } else if (!looksLikeScriptId(value)) {
      console.log("  That doesn't look like a script ID (expected 20+ letters, digits, - or _).");
    } else {
      return value;
    }
  }
}

(async () => {
  console.log('clasp setup. Script IDs are in Apps Script → Project Settings → IDs → Script ID.');

  const prod = await ask(
    '1/2  PROD script (bound to your real sheet)',
    'Plain `clasp` commands will target this one.',
    existingId(files.prod),
  );

  let dev = '';
  let currentDev = existingId(files.dev);
  for (;;) {
    dev = await ask(
      '2/2  DEV script (bound to the COPY of your sheet used for testing)',
      'Tests and `npm run deploy:dev` target this one. It must be different from prod.',
      currentDev,
    );
    if (dev !== prod) break;
    console.log("  Dev and prod are the same script. Enter the dev copy's ID.");
    currentDev = ''; // don't re-offer the same value as the default
  }

  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(files.prod, JSON.stringify({ scriptId: prod, rootDir: 'appsscript' }, null, 2) + '\n');
  fs.writeFileSync(files.dev, JSON.stringify({ scriptId: dev }, null, 2) + '\n');
  rl.close();

  console.log(`\nWrote ${path.relative(process.cwd(), files.prod) || '.clasp.json'} and ${path.relative(process.cwd(), files.dev) || '.clasp.dev.json'}`);
})().catch((e) => {
  console.error(`\n${e.message}; nothing was written.`);
  process.exit(1);
});

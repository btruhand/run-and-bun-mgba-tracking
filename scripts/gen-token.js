#!/usr/bin/env node
// Generates a shared secret for the Apps Script web app and stores it in .env as TOKEN.
// Refuses to overwrite an existing TOKEN unless --force is passed.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const envPath = path.join(__dirname, '..', '.env');
const force = process.argv.includes('--force');

const existing = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8') : '';
const hasToken = /^TOKEN=.+$/m.test(existing);

if (hasToken && !force) {
  console.error('.env already has a TOKEN. Re-run with --force to replace it:');
  console.error('  npm run gen-token -- --force');
  process.exit(1);
}

const token = crypto.randomBytes(32).toString('hex');
const line = `TOKEN=${token}`;
const next = hasToken
  ? existing.replace(/^TOKEN=.*$/m, line)
  : existing + (existing && !existing.endsWith('\n') ? '\n' : '') + line + '\n';

fs.writeFileSync(envPath, next, { mode: 0o600 });

console.log(`Wrote TOKEN to ${path.relative(process.cwd(), envPath) || '.env'}`);
console.log('Paste this into Apps Script > Project Settings > Script Properties as TOKEN:\n');
console.log(token);

#!/usr/bin/env node
// Generates a shared secret for the Apps Script web app and stores it as TOKEN in .env, or in the file given with
// --env (e.g. `npm run gen-token -- --env .env.dev`). Refuses to overwrite an existing TOKEN unless --force is passed.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { parseArgs } = require('util');

const USAGE = `Generate a shared secret for the Apps Script web app and store it as TOKEN.

Usage: npm run gen-token -- [--env FILE] [--force]
       node scripts/gen-token.js [--env FILE] [--force]

Options:
  --env FILE   file to write TOKEN to (default: .env in the repo root)
  --force      replace a TOKEN the file already has
  -h, --help   show this help

Examples:
  npm run gen-token -- --env .env.dev    # the dev copy's token
  npm run gen-token -- --force           # replace the token in .env
`;

let args;
try {
  ({ values: args } = parseArgs({
    options: {
      env: { type: 'string', default: path.join(__dirname, '..', '.env') },
      force: { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h' },
    },
  }));
} catch (e) {
  console.error(`gen-token: ${e.message}\n\n${USAGE}`);
  process.exit(1);
}
if (args.help) {
  process.stdout.write(USAGE);
  process.exit(0);
}
const envPath = args.env;
const rel = path.relative(process.cwd(), envPath);
const envName = rel && !rel.startsWith('..') ? rel : path.resolve(envPath);
const force = args.force;

const existing = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8') : '';
const hasToken = /^TOKEN=.+$/m.test(existing);

if (hasToken && !force) {
  console.error(`${envName} already has a TOKEN. Re-run with --force to replace it:`);
  console.error(`  npm run gen-token -- --env ${envName} --force`);
  process.exit(1);
}

const token = crypto.randomBytes(32).toString('hex');
const line = `TOKEN=${token}`;
const next = hasToken
  ? existing.replace(/^TOKEN=.*$/m, line)
  : existing + (existing && !existing.endsWith('\n') ? '\n' : '') + line + '\n';

fs.writeFileSync(envPath, next, { mode: 0o600 });

console.log(`Wrote TOKEN to ${envName}`);
console.log('Paste this into Apps Script > Project Settings > Script Properties as TOKEN:\n');
console.log(token);

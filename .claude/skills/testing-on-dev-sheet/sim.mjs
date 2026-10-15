// Plays a list of steps against the DEV web app, prints what it did with each, then the sheet. See SKILL.md.
//
//   node .claude/skills/testing-on-dev-sheet/sim.mjs steps.json
//   echo '[{"type":"catch","pid":"0xA:1","species":"Piplup"}]' | node .claude/skills/testing-on-dev-sheet/sim.mjs -
//
// Options: --env FILE (default .env.dev), --keep (don't reset the sheet first), --full (print the whole final dump).
// It asks for a dump before sending anything, which only a dev web app (ENV=dev) answers, so it can't touch a real sheet.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { readEnv, scriptError } from '../../../relay/relay.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: { env: { type: 'string', default: ROOT + '.env.dev' }, keep: { type: 'boolean' }, full: { type: 'boolean' } },
});
if (positionals.length !== 1) {
  console.error('usage: sim.mjs [--env FILE] [--keep] [--full] <steps.json | ->');
  process.exit(2);
}
const { WEB_APP_URL: url, TOKEN: token } = readEnv(opts.env);
if (!url || !token) throw new Error(`no WEB_APP_URL / TOKEN in ${opts.env}`);
const steps = JSON.parse(readFileSync(positionals[0] === '-' ? 0 : positionals[0], 'utf8'));

// Posts a body (an object gets the token added; a string is sent as is). Returns the parsed reply, or
// {crash} for Apps Script's HTML error page, or {html} for any other page.
async function post(body) {
  const res = await fetch(url, {
    method: 'POST', redirect: 'follow', headers: { 'content-type': 'text/plain' },
    body: typeof body === 'string' ? body : JSON.stringify({ token, ...body }),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return scriptError(text) ? { crash: scriptError(text) } : { html: `HTTP ${res.status} ${text.slice(0, 100)}` };
  }
}

const describe = (r) => r.crash ? `SCRIPT CRASHED: ${r.crash}` : r.html ? `NOT JSON: ${r.html}` : `error ${JSON.stringify(r.error)}`;

const first = await post({ action: 'dump' });
if (!first.ok) {
  console.error(`refusing to run: the web app in ${opts.env} did not answer a dump (${describe(first)}); is it the dev sheet?`);
  process.exit(1);
}
if (!opts.keep) {
  const r = await post({ action: 'reset' });
  if (!r.ok) throw new Error(`reset failed: ${describe(r)}`);
}

// Fills in what a step leaves out: run "sim", id "sim:<n>" (give "id": null to send none), playTime 10, 20, ...
let n = 0, clock = 0;
const fill = (ev) => {
  n++;
  clock = ev.playTime ?? clock + 10;
  const out = { run: 'sim', id: `sim:${n}`, playTime: clock, ...ev };
  if (out.id === null) delete out.id;
  return out;
};
const label = (ev) => `${ev.type}${ev.pid ? ' ' + ev.pid : ''}${ev.to ? ' -> ' + ev.to : ''}`;

for (const step of steps) {
  if (step.action === 'dump') {
    printState((await post({ action: 'dump' })).state);
  } else if (step.action === 'undo') {
    const r = await post({ action: 'undo' });
    console.log(r.ok ? `undo: ${JSON.stringify(r.result)}` : `undo: ${describe(r)}`);
  } else if (step.raw !== undefined) {
    console.log(`raw ${JSON.stringify(step.raw).slice(0, 60)}: ${JSON.stringify(await post(step.raw)).slice(0, 300)}`);
  } else {
    const events = (Array.isArray(step) ? step : [step]).map(fill);
    const r = await post({ events });
    if (!r.ok) {
      console.log(`${events.map(label).join(', ')}: ${describe(r)}`);
      continue;
    }
    events.forEach((ev, i) => {
      const res = r.results[i] || {};
      console.log(`${label(ev)}: ${res.status}${res.reason ? ` (${res.reason})` : ''}`);
    });
  }
}

const final = await post({ action: 'dump' });
if (!final.ok) throw new Error(`final dump failed: ${describe(final)}`);
if (opts.full) console.log(JSON.stringify(final.state, null, 1));
else printState(final.state);

function printState(s) {
  console.log('\n-- Rankings');
  for (const r of s.rows) {
    console.log(`  row ${r.row}  ${r.id || '(no id)'}  ${r.species}${r.nick ? ` "${r.nick}"` : ''}  ${r.status}  ${r.location}  KC ${r.kc.join(' ')} = ${r.total}`);
  }
  console.log(`  panel: badges ${s.panel.badges}, alive ${s.panel.alive}, deaths ${s.panel.deaths}, KOs ${s.panel.koTotal}; run ${s.run}`);
  console.log('-- _Events');
  s.journal.forEach((j, i) => {
    console.log(`  ${i + 2}  ${j.type} ${j.status}${j.active ? ' active' : ''}  t=${j.playTime}  ${j.id || '(no id)'}${j.issues ? `  issues ${j.issues}` : ''}`);
  });
  console.log('-- _Issues');
  s.issues.forEach((m, i) => console.log(`  ${i + 2}  ${m}`));
}

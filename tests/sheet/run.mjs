// Scenario tests against the DEV web app (needs WEB_APP_URL + TOKEN in .env, ENV=dev on the script).
// Usage: npm run test:sheet [-- --dump]   (--dump prints the final state of each scenario)
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const env = Object.fromEntries(
  readFileSync(new URL('../../.env', import.meta.url), 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);
const URL_ = env.WEB_APP_URL, TOKEN = env.TOKEN;
const verbose = process.argv.includes('--dump');
const onlyIdx = process.argv.indexOf('--only');
const only = onlyIdx > 0 ? process.argv[onlyIdx + 1] : null;

async function call(body) {
  const res = await fetch(URL_, { method: 'POST', redirect: 'follow', headers: { 'content-type': 'text/plain' }, body: JSON.stringify({ token: TOKEN, ...body }) });
  const json = await res.json();
  assert.ok(json.ok, `request failed: ${JSON.stringify(json)}`);
  return json;
}
const reset = () => call({ action: 'reset' });
const dump = async () => (await call({ action: 'dump' })).state;
const undo = async () => (await call({ action: 'undo' })).result;

let seq = 0, RUN = 'run1';
const ev = (type, playTime, rest = {}) => ({ id: `${RUN}:${++seq}`, run: RUN, playTime, type, ...rest });
const send = async (...events) => (await call({ events })).results;
const sync = (playTime, mons, extra = {}) => ({ run: RUN, playTime, type: 'sync', mons, ...extra });
const mon = (pid, species, extra = {}) => ({ pid, species, nick: '', hp: 20, where: 'party', ...extra });
const byId = (s, id) => s.rows.find((r) => r.id === id);

const A = '0xA:1', B = '0xB:1', C = '0xC:1';
const catchEv = (playTime, pid, species, loc = 'Route 101') => ev('catch', playTime, { pid, species, nick: '', location: loc, source: 'catch' });
const killEv = (playTime, pid, split, trainer, slot = 0) => ev('kill', playTime, { pid, split, trainer, key: `${trainer}:${slot}`, enemy: 'x', indirect: false });

const scenarios = {
  async 'catch adds a row with zeroed KC and Alive status'() {
    await send(catchEv(10, A, 'Piplup'));
    const s = await dump();
    assert.equal(s.rows.length, 1);
    assert.deepEqual([s.rows[0].species, s.rows[0].status, s.rows[0].location, s.rows[0].total], ['Piplup', 'Alive', 'Route 101', 0]);
    assert.deepEqual(s.rows[0].kc, [0, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert.equal(s.panel.alive, 1);
  },
  async 'duplicate event ids are ignored'() {
    const e = catchEv(10, A, 'Piplup');
    const r1 = await send(e), r2 = await send(e);
    assert.equal(r1[0].status, 'applied');
    assert.equal(r2[0].status, 'duplicate');
    assert.equal((await dump()).rows.length, 1);
  },
  async 'kills land in the right split column, total updates, rows sort by KC'() {
    await send(catchEv(10, A, 'Piplup'), catchEv(11, B, 'Zigzagoon', 'Route 102'));
    await send(killEv(20, B, 2, 't1'), killEv(21, B, 2, 't1', 1), killEv(22, B, 9, 't9'));
    const s = await dump();
    assert.deepEqual(s.rows[0].id, B, 'highest KC first');
    assert.deepEqual(byId(s, B).kc, [0, 2, 0, 0, 0, 0, 0, 0, 1]);
    assert.equal(byId(s, B).total, 3);
    assert.equal(s.panel.koTotal, 3);
  },
  async 'death marks Dead and sorts below living mons'() {
    await send(catchEv(10, A, 'Piplup'), catchEv(11, B, 'Zigzagoon'));
    await send(killEv(20, A, 1, 't1'), ev('death', 30, { pid: A }));
    const s = await dump();
    assert.equal(byId(s, A).status, 'Dead');
    assert.equal(s.rows[0].id, B, 'alive above dead even with fewer kills');
    assert.equal(s.panel.deaths, 1);
    assert.equal(s.panel.alive, 1);
  },
  async 'evolve changes species and keeps KC'() {
    await send(catchEv(10, A, 'Piplup'), killEv(20, A, 1, 't1'));
    await send(ev('evolve', 30, { pid: A, from: 'Piplup', to: 'Prinplup' }));
    const r = byId(await dump(), A);
    assert.equal(r.species, 'Prinplup');
    assert.equal(r.total, 1);
  },
  async 'evolve with a nick renames the mon, and a rewind puts species and nick back'() {
    await send(ev('catch', 10, { pid: A, species: 'Scatterbug', nick: 'Scatterbug', location: 'Route 101', source: 'catch' }));
    await send(ev('evolve', 30, { pid: A, from: 'Scatterbug', to: 'Spewpa', nick: 'Spewpa' }));
    let r = byId(await dump(), A);
    assert.deepEqual([r.species, r.nick], ['Spewpa', 'Spewpa']);
    await send(sync(20, [mon(A, '', { nick: undefined })], { complete: true }));
    r = byId(await dump(), A);
    assert.deepEqual([r.species, r.nick], ['Scatterbug', 'Scatterbug']);
  },
  async 'trade substitutes in place and keeps KC'() {
    await send(catchEv(10, A, 'Seedot'), killEv(20, A, 1, 't1'));
    await send(ev('trade', 30, { old_pid: A, pid: B, species: 'Nincada', nick: 'Bug', location: 'Route 116' }));
    const s = await dump();
    assert.equal(s.rows.length, 1);
    assert.deepEqual([s.rows[0].id, s.rows[0].species, s.rows[0].nick, s.rows[0].location, s.rows[0].total], [B, 'Nincada', 'Bug', 'Route 116', 1]);
  },
  async 'split event sets Badges'() {
    await send(ev('split', 10, { badges: 3 }));
    assert.equal((await dump()).panel.badges, 3);
  },
  async 'rewind: events after the loaded play time are undone'() {
    await send(catchEv(10, A, 'Piplup'), killEv(100, A, 1, 't1'), killEv(200, A, 1, 't2'), catchEv(300, B, 'Zigzagoon'), ev('death', 310, { pid: A }));
    // load a save from playTime 150: only the first kill existed, B not caught yet, A alive
    await send(sync(150, [mon(A, 'Piplup')], { defeated: ['t1'], badges: 0, complete: true }));
    const s = await dump();
    assert.equal(s.rows.length, 1);
    assert.equal(s.rows[0].status, 'Alive');
    assert.equal(s.rows[0].total, 1);
  },
  async 'forward jump: undone events come back when a newer state is loaded'() {
    await send(catchEv(10, A, 'Piplup'), killEv(100, A, 1, 't1'), killEv(200, A, 1, 't2'), catchEv(300, B, 'Zigzagoon'));
    await send(sync(150, [mon(A, 'Piplup')], { defeated: ['t1'], complete: true }));
    assert.equal((await dump()).rows.length, 1);
    await send(sync(350, [mon(A, 'Piplup'), mon(B, 'Zigzagoon')], { defeated: ['t1', 't2'], complete: true }));
    const s = await dump();
    assert.equal(s.rows.length, 2);
    assert.equal(byId(s, A).total, 2);
  },
  async 'replaying a fight with a different killer moves the credit'() {
    await send(catchEv(10, A, 'Mudkip'), catchEv(11, B, 'Torchic'), killEv(200, A, 1, 't2'));
    await send(sync(150, [mon(A, 'Mudkip'), mon(B, 'Torchic')], { defeated: [], complete: true }));
    assert.equal(byId(await dump(), A).total, 0);
    await send(killEv(200, B, 1, 't2'));
    const s = await dump();
    assert.equal(byId(s, A).total, 0);
    assert.equal(byId(s, B).total, 1);
  },
  async 'sync adds a mon that is in the game but not on the sheet and syncs species'() {
    await send(catchEv(10, A, 'Piplup'));
    await send(sync(500, [mon(A, 'Empoleon'), mon(C, 'Ralts', { location: 'Route 102' })], { complete: true }));
    const s = await dump();
    assert.equal(byId(s, A).species, 'Empoleon');
    assert.equal(byId(s, C).species, 'Ralts');
  },
  async 'events from a different run are held'() {
    await send(catchEv(10, A, 'Piplup'));
    const saved = RUN; RUN = 'other';
    const r = await send(catchEv(10, B, 'Zigzagoon'));
    RUN = saved;
    assert.equal(r[0].status, 'held');
    assert.equal((await dump()).rows.length, 1);
  },
  async 'undo reverts the latest change and removes it from the journal, one per press'() {
    await send(catchEv(10, A, 'Piplup'), killEv(20, A, 1, 't1'), killEv(30, A, 2, 't2'));
    assert.match((await undo()).undone, /^KO by Piplup \(split 2\)/);
    let s = await dump();
    assert.deepEqual(byId(s, A).kc, [1, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert.equal(s.journal.length, 2);
    await undo(); await undo();
    s = await dump();
    assert.equal(s.rows.length, 0);
    assert.equal(s.journal.length, 0);
    assert.equal((await undo()).undone, null);
  },
  async 'undo puts back badges, status and an evolution'() {
    await send(catchEv(10, A, 'Scatterbug'), ev('evolve', 20, { pid: A, from: 'Scatterbug', to: 'Spewpa', nick: 'Spewpa' }));
    await send(ev('death', 30, { pid: A }), ev('split', 40, { badges: 1 }));
    await undo(); await undo(); await undo();
    const s = await dump();
    assert.equal(s.panel.badges, 0);
    assert.deepEqual([byId(s, A).status, byId(s, A).species, byId(s, A).nick], ['Alive', 'Scatterbug', '']);
  },
  async 'undo skips entries already undone by a rewind and no-ops'() {
    await send(catchEv(10, A, 'Piplup'), killEv(20, A, 1, 't1'), killEv(200, A, 1, 't2'));
    await send(sync(100, [mon(A, 'Piplup')], { defeated: ['t1'], complete: true }));
    await send(ev('catch', 110, { pid: A, species: 'Piplup', nick: '', location: 'Route 101', source: 'catch' })); // already on the sheet
    assert.match((await undo()).undone, /^KO by/);
    const s = await dump();
    assert.equal(byId(s, A).total, 0);
    assert.deepEqual(s.journal.map((j) => [j.type, j.playTime, j.active]), [['catch', 10, true], ['kill', 200, false], ['catch', 110, true]]);
  },
  async 'an undone event stays undone through a later sync'() {
    await send(catchEv(10, A, 'Piplup'), killEv(20, A, 1, 't1'));
    await undo();
    await send(sync(100, [mon(A, 'Piplup')], { defeated: ['t1'], complete: true }));
    assert.equal(byId(await dump(), A).total, 0);
  },
  async 'sorting keeps row formulas pointing at their own row'() {
    await send(catchEv(10, A, 'Piplup'), catchEv(11, B, 'Zigzagoon'), catchEv(12, C, 'Ralts'));
    await send(killEv(20, C, 1, 't1'), killEv(21, C, 1, 't1', 1), killEv(22, B, 1, 't2'));
    const s = await dump();
    assert.deepEqual(s.rows.map((r) => r.id), [C, B, A]);
    for (const r of s.rows) {
      for (const [col, f] of Object.entries(r.formulas)) {
        const rowRefs = [...f.replace(/"[^"]*"/g, '').matchAll(/(?<![A-Za-z$!:])\$?[A-Z]{1,2}(\d+)(?!\d)/g)].map((m) => Number(m[1]));
        assert.ok(rowRefs.every((n) => n === r.row), `row ${r.row} col ${col} formula refers to another row: ${f}`);
      }
    }
  },
};

let failed = 0;
for (const [name, fn] of Object.entries(scenarios)) {
  if (only && !name.includes(only)) continue;
  seq = 0; RUN = 'run1';
  try {
    await reset();
    await fn();
    console.log(`ok   ${name}`);
    if (verbose) console.log(JSON.stringify(await dump(), null, 1));
  } catch (e) {
    failed++;
    console.log(`FAIL ${name}\n     ${e.message.split('\n').join('\n     ')}`);
    if (verbose) console.log(JSON.stringify(await dump(), null, 1));
  }
}
await reset();
console.log(failed ? `\n${failed} failed` : '\nall passed');
process.exit(failed ? 1 : 0);

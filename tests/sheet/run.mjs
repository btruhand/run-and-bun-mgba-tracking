// Scenario tests against the DEV web app (needs WEB_APP_URL + TOKEN in .env.dev, ENV=dev on the script).
// Usage: npm run test:sheet [-- --dump]   (--dump prints the final state of each scenario)
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { scriptError } from '../../relay/relay.mjs';

const env = Object.fromEntries(
  readFileSync(new URL('../../.env.dev', import.meta.url), 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);
const URL_ = env.WEB_APP_URL, TOKEN = env.TOKEN;
const verbose = process.argv.includes('--dump');
const onlyIdx = process.argv.indexOf('--only');
const only = onlyIdx > 0 ? process.argv[onlyIdx + 1] : null;

// Follows the redirects by hand (Apps Script answers a POST with one to the result) so a failure can say where it went.
async function call(body) {
  const hops = [];
  let res = await fetch(URL_, { method: 'POST', redirect: 'manual', headers: { 'content-type': 'text/plain' }, body: JSON.stringify({ token: TOKEN, ...body }) });
  while (res.status >= 300 && res.status < 400 && hops.length < 5) {
    const to = new URL(res.headers.get('location'), res.url || URL_);
    hops.push(`${res.status} -> ${to.host}${to.pathname}`);
    res = await fetch(to, { redirect: 'manual' });
  }
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {}
  const where = `(HTTP ${res.status}; ${hops.join(', ') || 'no redirect'})`;
  assert.ok(json, `not JSON ${where}: ${scriptError(text) || text.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 200)}`);
  assert.ok(json.ok, `request failed ${where}: ${JSON.stringify(json)}`);
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
const killEv = (playTime, pid, split, trainer, slot = 0) => ev('kill', playTime, { pid, split, trainer, key: `${trainer}:${slot}`, enemy: 'x' });

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
  // The next three send a sync the way lua/sync.lua writes it: trainer ids as numbers (a kill carries its trainer as a
  // string), no hp on a mon in a box, an empty list as [].
  async 'a kill stays when its trainer is in the sync as a number, and goes when it is not'() {
    await send(catchEv(10, A, 'Piplup'), killEv(20, A, 1, '615'));
    await send(sync(30, [mon(A, 'Piplup')], { defeated: [615], badges: 0, complete: true }));
    assert.equal(byId(await dump(), A).total, 1, 'kept');
    await send(sync(30, [mon(A, 'Piplup')], { defeated: [], badges: 0, complete: true }));
    assert.equal(byId(await dump(), A).total, 0, 'taken back');
  },
  async 'after a reload that lost two catches, sync drops their old ids and the recaptures come in'() {
    const OLD_G = '0xB1:0xF9D040AF', OLD_F = '0xC1:0xF9D040AF', NEW_G = '0xB2:0xF9D040AF', NEW_F = '0xC2:0xF9D040AF';
    await send(catchEv(10, A, 'Piplup'), catchEv(20, OLD_G, 'Gligar', 'Rusturf Tunnel'), catchEv(30, OLD_F, 'Foongus', 'Verdanturf Town'), killEv(40, OLD_G, 1, '615'));
    // the game goes back to play time 15, where only Piplup existed
    await send(sync(15, [mon(A, 'Piplup')], { defeated: [], badges: 0, complete: true }));
    let s = await dump();
    assert.deepEqual(s.rows.map((r) => r.id), [A], 'the lost catches are off the sheet');
    // recaptured in the new timeline, with new ids
    await send(catchEv(25, NEW_G, 'Gligar', 'Rusturf Tunnel'), catchEv(26, NEW_F, 'Foongus', 'Verdanturf Town'));
    await send(sync(50, [mon(A, 'Piplup'), mon(NEW_G, 'Gligar'), mon(NEW_F, 'Foongus', { where: 'box', hp: undefined })], { defeated: [], badges: 0, complete: true }));
    s = await dump();
    assert.deepEqual(s.rows.map((r) => r.id).sort(), [A, NEW_G, NEW_F].sort());
    assert.equal(s.rows.filter((r) => r.species === 'Gligar').length, 1, 'no duplicate Gligar');
    assert.equal(s.rows.every((r) => r.total === 0), true, 'the lost kill did not come back');
  },
  async 'when the tracker missed the recaptures, sync adds them from the game'() {
    await send(catchEv(10, A, 'Piplup'), catchEv(20, '0xB1:0xF9D040AF', 'Gligar', 'Rusturf Tunnel'));
    await send(sync(50, [
      mon(A, 'Piplup'),
      mon('0xB2:0xF9D040AF', 'Gligar', { location: 'Rusturf Tunnel' }),
      mon('0xC2:0xF9D040AF', 'Foongus', { location: 'Verdanturf Town', where: 'box', hp: undefined }),
    ], { defeated: [], badges: 0, complete: true }));
    const s = await dump();
    assert.deepEqual(s.rows.map((r) => r.id).sort(), [A, '0xB2:0xF9D040AF', '0xC2:0xF9D040AF'].sort(), 'old Gligar gone, both new ones added');
    assert.equal(byId(s, '0xC2:0xF9D040AF').location, 'Verdanturf Town');
  },
  async 'sync with several mons to add and update writes them all, with a journal row each'() {
    await send(catchEv(10, A, 'Piplup'), catchEv(20, B, 'Zigzagoon'));
    const extra = ['0xD:1', '0xE:1', '0xF:1'];
    await send(sync(50, [
      mon(A, 'Empoleon', { nick: 'Pip' }),
      mon(B, 'Linoone'),
      ...extra.map((id, i) => mon(id, 'Ralts', { nick: `R${i}`, location: `Route 10${i}` })),
    ], { defeated: [], badges: 0, complete: true }));
    const s = await dump();
    assert.deepEqual([byId(s, A).species, byId(s, A).nick, byId(s, B).species], ['Empoleon', 'Pip', 'Linoone']);
    extra.forEach((id, i) => {
      const r = byId(s, id);
      assert.deepEqual([r.species, r.nick, r.location, r.status, r.total], ['Ralts', `R${i}`, `Route 10${i}`, 'Alive', 0]);
    });
    assert.equal(s.rows.length, 5);
    assert.equal(s.journal.filter((j) => j.id.startsWith('reconcile:') && j.active).length, 3);
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
    assert.deepEqual(s.journal.map((j) => [j.type, j.playTime, j.active, j.status]),
      [['catch', 10, true, 'applied'], ['kill', 200, false, 'applied'], ['sync', 100, false, 'reconciled'], ['catch', 110, true, 'applied']]);
  },
  async 'an undone event stays undone through a later sync'() {
    await send(catchEv(10, A, 'Piplup'), killEv(20, A, 1, 't1'));
    await undo();
    await send(sync(100, [mon(A, 'Piplup')], { defeated: ['t1'], complete: true }));
    assert.equal(byId(await dump(), A).total, 0);
  },
  // These two rely on the Species column's dropdown rejecting what isn't on its list, as it does on the template.
  async 'an event that throws is logged to _Issues and the rest of the request still applies'() {
    await send(catchEv(10, A, 'Sizzlipede'));
    const results = await send(ev('evolve', 20, { pid: A, from: 'Sizzlipede', to: 'Venonat' }), killEv(21, A, 1, 't1'));
    assert.deepEqual(results.map((r) => r.status), ['failed', 'applied']);
    assert.match(results[0].reason, /violates the data validation rules/);
    const s = await dump();
    assert.deepEqual([byId(s, A).species, byId(s, A).total], ['Sizzlipede', 1]);
    assert.equal(s.issues.length, 1);
    assert.match(s.issues[0], /^evolve failed: The data you entered in cell I\d+ violates the data validation rules .*\(WebApp:\d+\)$/);
    assert.deepEqual(s.journal.map((j) => [j.type, j.status, j.issues]), [['catch', 'applied', ''], ['evolve', 'failed', '2'], ['kill', 'applied', '']],
      'the failed event is recorded, pointing at its issue (row 2 of _Issues)');
  },
  async 'a sync step that throws is logged and the rest of the sync still applies'() {
    await send(catchEv(10, A, 'Sizzlipede'), catchEv(11, B, 'Zigzagoon'));
    const results = await send(sync(100, [mon(A, 'Venonat'), mon(B, 'Linoone', { nick: 'Zoomer' })], { badges: 2 }));
    assert.deepEqual(results.map((r) => r.status), ['reconciled']);
    const s = await dump();
    assert.equal(byId(s, A).species, 'Sizzlipede');
    assert.deepEqual([byId(s, B).species, byId(s, B).nick], ['Linoone', 'Zoomer']);
    assert.equal(s.panel.badges, 2);
    assert.equal(s.issues.length, 1);
    assert.match(s.issues[0], /^sync could not update 0xA:1: The data you entered in cell I\d+ violates/);
    assert.deepEqual(s.journal.at(-1), { id: '', type: 'sync', pid: '', playTime: 100, active: false, status: 'reconciled', issues: '2' });
  },
  async 'every event is recorded in _Events with its status and issues'() {
    await send(catchEv(10, A, 'Piplup'));
    const other = { id: 'other:1', run: 'other', playTime: 30, type: 'catch', pid: C, species: 'Ralts', nick: '', location: 'Route 102' };
    const results = await send(killEv(20, B, 1, 't1'), { run: RUN, playTime: 25, type: 'death', pid: A }, other);
    assert.deepEqual(results.map((r) => r.status), ['ignored', 'rejected', 'held']);
    const s = await dump();
    assert.deepEqual(s.journal.map((j) => [j.type, j.status, j.active, j.issues]), [
      ['catch', 'applied', true, ''], ['kill', 'ignored', false, '2'], ['death', 'rejected', false, '3'], ['catch', 'held', false, '4'],
    ]);
    assert.match(s.issues[0], /^kill for unknown pid/);
    assert.match(s.issues[1], /^rejected death without an id/);
    assert.match(s.issues[2], /^event from different run/);
    assert.equal(s.issues.length, 3);
    assert.equal(byId(s, A).status, 'Alive');
  },
  async 'a resent event that was not applied is handled again in its own row; an applied one is a duplicate'() {
    await send(catchEv(10, A, 'Sizzlipede'));
    const kill = killEv(20, B, 1, 't1'); // its mon's catch hasn't arrived yet
    const evolve = ev('evolve', 30, { pid: A, from: 'Sizzlipede', to: 'Venonat' }); // the dropdown rejects it
    assert.deepEqual((await send(kill, evolve)).map((r) => r.status), ['ignored', 'failed']);
    await send(catchEv(15, B, 'Zigzagoon'));
    assert.deepEqual((await send(kill, evolve)).map((r) => r.status), ['applied', 'failed']);
    assert.deepEqual((await send(kill)).map((r) => r.status), ['duplicate']);
    const s = await dump();
    assert.equal(byId(s, B).total, 1, 'the kill counted once');
    assert.deepEqual(s.journal.map((j) => [j.type, j.status, j.active, j.issues]), [
      ['catch', 'applied', true, ''], ['kill', 'applied', true, '2'], ['evolve', 'failed', false, '3, 4'], ['catch', 'applied', true, ''],
    ]);
    assert.equal(s.issues.length, 3);
  },
  async 'an issue from rewinding an earlier event is referenced from that event too'() {
    await send(catchEv(10, A, 'Scatterbug'), ev('evolve', 20, { pid: A, from: 'Scatterbug', to: 'Spewpa' }));
    await send(sync(100, [mon(A, 'Silcoon')])); // the sheet now says Silcoon, so undoing the evolution is skipped
    await send(sync(15, [mon(A, 'Scatterbug')]));
    const s = await dump();
    assert.equal(s.issues.length, 1);
    assert.match(s.issues[0], /^skipped undo: species of 0xA:1 was edited/);
    assert.deepEqual(s.journal.map((j) => [j.type, j.playTime, j.active, j.issues]), [
      ['catch', 10, true, ''], ['evolve', 20, false, '2'], ['sync', 100, false, ''], ['sync', 15, false, '2'],
    ]);
    assert.equal(byId(s, A).species, 'Scatterbug', 'the sync still sets what the game has');
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

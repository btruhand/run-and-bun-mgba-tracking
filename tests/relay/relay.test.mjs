// Relay tests, no network or sheet needed:  npm run test:relay
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { afterEach, beforeEach, describe, test } from 'node:test';
import * as R from '../../relay/relay.mjs';

const ev = (n, type = 'kill', run = '0xRUN') => ({ id: `${run}:s.${n}`, run, playTime: 100 + n, type });
const line = (e) => JSON.stringify(e);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Stands in for the web app: dedupes by id, and can be told to be down, refuse the token or fail.
function fakeWebApp() {
  const web = { seen: [], requests: [], down: false, badToken: false, broken: false };
  web.post = async (url, body) => {
    if (web.down) throw new TypeError('fetch failed', { cause: { code: 'ECONNREFUSED' } });
    web.requests.push(body.events.map((e) => e.id));
    if (web.badToken) return [200, JSON.stringify({ ok: false, error: 'unauthorized' })];
    if (web.broken) return [200, '<html><body>TypeError: Cannot read properties of null</body></html>'];
    const results = body.events.map((e) => {
      const dup = web.seen.includes(e.id);
      if (!dup) web.seen.push(e.id);
      return { id: e.id, status: dup ? 'duplicate' : 'applied' };
    });
    return [200, JSON.stringify({ ok: true, results })];
  };
  return web;
}

describe('relay queue', () => {
  let web, logs, waits, r;
  beforeEach(() => {
    web = fakeWebApp();
    logs = [];
    waits = [];
    const sleep = async (s) => { waits.push(s); };
    // random 0.5 is the middle of the jitter, so waits are exactly 1, 2, 4 s unless a test says otherwise
    r = new R.Relay('http://fake/exec', 'tok', { post: web.post, log: (m) => logs.push(m), sleep, random: () => 0.5 });
  });
  const logged = (text) => logs.some((m) => m.includes(text));

  test('a tick sends everything queued as one request and empties the queue', async () => {
    for (let i = 1; i <= 3; i++) r.receive(line(ev(i)));
    assert.equal(await r.tick(), true);
    assert.equal(r.tick(), null, 'nothing left to send');
    assert.deepEqual(web.requests, [['0xRUN:s.1', '0xRUN:s.2', '0xRUN:s.3']]);
    assert.equal(r.queue.length, 0);
    assert.ok(logs.includes('sent 3: kill applied, kill applied, kill applied'));
  });

  test('a failed request is retried 3 times, after 1, 2 and 4 s, then its events are dropped', async () => {
    web.down = true;
    r.receive(line(ev(1)));
    assert.equal(await r.tick(), false);
    assert.deepEqual(waits, [1, 2, 4]);
    assert.ok(logged('retry 3/3 in 4.0s'));
    assert.ok(logged('GAVE UP after 4 attempts (web app unreachable (ECONNREFUSED)); not on the sheet: kill 0xRUN:s.1'));
    assert.equal(r.sending, 0);
  });

  test('each wait is jittered by up to ±50%', async () => {
    web.down = true;
    for (const [rnd, want] of [[0, [0.5, 1, 2]], [0.99, [1.49, 2.98, 5.96]]]) {
      waits.length = 0;
      r.random = () => rnd;
      r.receive(line(ev(1)));
      await r.tick();
      assert.deepEqual(waits.map((w) => Math.round(w * 100) / 100), want, `random ${rnd}`);
    }
  });

  test('a request goes through when the web app comes back during its retries', async () => {
    let failures = 2;
    r.post = async (url, body) => {
      if (failures-- > 0) throw new TypeError('fetch failed', { cause: { code: 'ECONNREFUSED' } });
      return web.post(url, body);
    };
    r.receive(line(ev(1)));
    assert.equal(await r.tick(), true);
    assert.deepEqual(waits, [1, 2]);
    assert.deepEqual(web.seen, ['0xRUN:s.1']);
  });

  test('a request being retried does not hold up the next one', async () => {
    let release;
    r.sleep = () => new Promise((resolve) => { release = resolve; }); // the first request waits here
    web.down = true;
    r.receive(line(ev(1)));
    const first = r.tick();
    await new Promise((resolve) => setImmediate(resolve));
    web.down = false;
    r.receive(line(ev(2)));
    const second = await Promise.race([r.tick(), sleep(500).then(() => 'held up behind the first')]);
    assert.equal(second, true, 'sent while the first is still waiting to retry');
    assert.deepEqual(web.seen, ['0xRUN:s.2']);
    assert.equal(r.sending, 1, 'the first is still in flight');
    release();
    assert.equal(await first, true);
    assert.deepEqual(web.seen, ['0xRUN:s.2', '0xRUN:s.1'], 'the retried event lands after the later one');
  });

  test('a refused token or a broken script is retried, then given up on', async () => {
    for (const flag of ['badToken', 'broken']) {
      web[flag] = true;
      r.receive(line(ev(1)));
      assert.equal(await r.tick(), false, flag);
      web[flag] = false;
    }
    assert.equal(web.requests.length, 8, '4 attempts each');
    assert.ok(logged('web app refused the token'));
    assert.ok(logged('web app answered HTTP 200 without JSON'));
  });

  test('a retry after a request that did reach the sheet applies nothing twice', async () => {
    r.receive(line(ev(1)));
    await web.post(null, { events: [ev(1)] }); // it reached the sheet, but the answer was lost
    await r.tick();
    assert.deepEqual(web.seen, ['0xRUN:s.1']);
    assert.ok(logs.includes('sent 1: kill duplicate'));
  });

  test('lines that are not events are ignored', async () => {
    r.receive('{"type":"kill"');
    r.receive('{"type":"kill"}');
    r.receive(line(ev(1)));
    await r.tick();
    assert.deepEqual(web.seen, ['0xRUN:s.1']);
    assert.ok(logged('not JSON'));
    assert.ok(logged('without a type or id'));
  });
});

describe('tracker connections', () => {
  let logs, got, server, port;
  beforeEach(async () => {
    // Each server gets its own arrays: a connection from the previous test may still be closing.
    const [myLogs, myGot] = [logs, got] = [[], []];
    const id = (e) => e.id + (e.nick ? '/' + e.nick : '');
    const relay = { log: (m) => myLogs.push(m), receive: (l) => myGot.push(id(JSON.parse(l))) };
    server = R.createServer(relay);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    port = server.address().port;
  });
  afterEach(() => new Promise((resolve) => server.close(resolve)));

  async function waitFor(cond) {
    const deadline = Date.now() + 5000;
    while (!cond()) {
      if (Date.now() > deadline) assert.fail(`timed out; got ${JSON.stringify(got)}, log ${JSON.stringify(logs)}`);
      await sleep(10);
    }
  }
  const connect = () => new Promise((resolve) => { const c = net.connect(port, '127.0.0.1', () => resolve(c)); });

  test('lines are split wherever the bytes arrive, including inside a multi-byte character', async () => {
    const c = await connect();
    const data = Buffer.from([ev(1), { ...ev(2), nick: 'Pipé' }, ev(3)].map((e) => line(e) + '\n').join(''));
    const cut = data.indexOf(Buffer.from('é')) + 1; // between the two bytes of é
    for (const part of [data.subarray(0, 10), data.subarray(10, cut), data.subarray(cut)]) {
      c.write(part);
      await sleep(30);
    }
    await waitFor(() => got.length === 3);
    c.end();
    assert.deepEqual(got, ['0xRUN:s.1', '0xRUN:s.2/Pipé', '0xRUN:s.3']);
  });

  test('a line cut off by a disconnect is dropped, and the tracker can reconnect', async () => {
    let c = await connect();
    c.end(line(ev(1)) + '\n' + line(ev(2)).slice(0, 20));
    await waitFor(() => logs.includes('tracker disconnected'));
    assert.deepEqual(got, ['0xRUN:s.1']);
    assert.ok(logs.some((m) => m.includes('partial line')));
    c = await connect();
    c.write(line(ev(3)) + '\n');
    await waitFor(() => got.length === 2);
    c.end();
    assert.deepEqual(got, ['0xRUN:s.1', '0xRUN:s.3']);
  });

  test('the relay never writes to the tracker', async () => {
    // lua/relay_client.lua treats a readable socket as closed by the relay.
    const c = await connect();
    let received = 0;
    c.on('data', (d) => { received += d.length; });
    c.write(line(ev(1)) + '\n');
    await waitFor(() => got.length === 1);
    await sleep(200);
    c.end();
    assert.equal(received, 0);
  });

  test('a second relay on the same port fails to start', async () => {
    const second = R.createServer({ log() {}, receive() {} });
    const err = await new Promise((resolve) => { second.once('error', resolve); second.listen(port, '127.0.0.1'); });
    assert.equal(err.code, 'EADDRINUSE');
  });
});

test('posts over HTTP and follows the redirect to the answer, the way Apps Script answers', async () => {
  const bodies = [];
  const answer = { ok: true, results: [{ id: 'r:s.1', status: 'applied' }] };
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      if (req.method === 'POST') {
        bodies.push(JSON.parse(body));
        res.writeHead(302, { Location: '/echo?user_content_key=abc' }).end();
      } else {
        res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(answer));
      }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const r = new R.Relay(`http://127.0.0.1:${server.address().port}/exec`, 'tok', { log() {} });
    const e = { id: 'r:s.1', run: 'r', type: 'catch', nick: 'Pipé' };
    r.receive(line(e));
    assert.equal(await r.tick(), true);
    assert.deepEqual(bodies, [{ token: 'tok', events: [e] }]);
  } finally {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  }
});

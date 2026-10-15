// Forward the Lua tracker's events to the Apps Script web app. Node 22+ (.nvmrc pins the version), no packages.
//
//   npm run relay                               # WEB_APP_URL and TOKEN from .env
//   node relay/relay.mjs --env .env.dev         # another sheet
//   node relay/relay.mjs --help
//
// lua/tracker.lua connects to 127.0.0.1:38765 and sends each event as a line of JSON. The relay posts them to the web
// app: every 200 ms, whatever has arrived goes out as one request, which is retried 3 times (after about 1, 2 and
// 4 s, each ±50% at random) if it fails. Requests are independent, so one being retried doesn't hold up the next; the price is that a retried
// event can reach the sheet after a later one (a kill before its mon's catch is then ignored by the sheet, and logged).
// Nothing is stored: events whose request still fails are logged and dropped, as is anything not yet sent when the
// relay stops. Events carry ids stamped by the tracker and the web app skips ids it has already applied, so a retry
// that follows a request which did reach the sheet doesn't apply anything twice.
import { readFileSync } from 'node:fs';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

export const PORT = 38765;  // must match TRACKER_RELAY_PORT's default in lua/tracker.lua
export const RETRIES = 3;   // retries of a failed request, after 1, 2, 4 s ±50%; then its events are dropped
export const TICK = 200;    // ms between looks at the queue
const TIMEOUT = 60;         // seconds per request (the web app waits up to 30 s for its lock)

const ROOT = fileURLToPath(new URL('..', import.meta.url));

export function readEnv(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return {};
  }
  const env = {};
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.includes('=') && !line.startsWith('#')) {
      const i = line.indexOf('=');
      env[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
  }
  return env;
}

// POSTs `body` as JSON and returns [status, text]. Apps Script answers a POST with a redirect to the result, which
// fetch follows with a GET.
export async function httpPost(url, body) {
  const res = await fetch(url, {
    method: 'POST', redirect: 'follow', headers: { 'content-type': 'text/plain' }, body: JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT * 1000),
  });
  return [res.status, await res.text()];
}

const wait = (seconds) => new Promise((r) => setTimeout(r, seconds * 1000));
const defaultLog = (msg) => console.log(new Date().toTimeString().slice(0, 8), msg);

// The web app answered, but not with a successful JSON reply (an error in the script).
export class WebAppError extends Error {}
export class Unauthorized extends Error {}

// Between the tracker connections and the web app.
export class Relay {
  constructor(url, token, { post = httpPost, log = defaultLog, sleep = wait, random = Math.random } = {}) {
    Object.assign(this, { url, token, post, log, sleep, random });
    this.queue = [];   // events that arrived since the last tick, oldest first
    this.sending = 0;  // events in requests that haven't finished (with their retries)
  }

  // Queues one line from the tracker.
  receive(line) {
    let ev;
    try {
      ev = JSON.parse(line);
    } catch (e) {
      this.log(`ignored a line that is not JSON (${e.message}): ${line.slice(0, 80)}`);
      return;
    }
    if (!ev || typeof ev !== 'object' || !ev.type || !ev.id) {
      this.log(`ignored an event without a type or id: ${line.slice(0, 80)}`);
      return;
    }
    this.queue.push(ev);
  }

  // One request to the web app. Returns its parsed answer, or throws: whatever fetch throws when it can't be
  // reached, WebAppError when it answers but not with a successful JSON reply, Unauthorized when it refuses the token.
  async call(events) {
    const [status, text] = await this.post(this.url, { token: this.token, events });
    let resp = null;
    try {
      resp = JSON.parse(text);
    } catch {}
    if (!resp || typeof resp !== 'object') {
      const crash = scriptError(text);
      if (crash) throw new WebAppError(`script failed: ${crash}`);
      throw new WebAppError(`answered HTTP ${status} without JSON: ${text.split(/\s+/).join(' ').slice(0, 120)}`);
    }
    if (resp.ok) return resp;
    if (resp.error === 'unauthorized') {
      throw new Unauthorized("refused the token; TOKEN in .env must match TOKEN in the script's properties");
    }
    throw new WebAppError(`answered with error ${JSON.stringify(resp.error)}`);
  }

  // Takes everything queued and sends it as one request, without waiting for earlier requests. Returns the
  // request's promise (true once on the sheet, false if given up on), or null if nothing was queued.
  tick() {
    if (!this.queue.length) return null;
    const batch = this.queue;
    this.queue = [];
    return this.send(batch);
  }

  async send(batch) {
    this.sending += batch.length;
    try {
      for (let attempt = 0; ; attempt++) {
        let resp;
        try {
          resp = await this.call(batch);
        } catch (e) {
          const known = e instanceof Unauthorized || e instanceof WebAppError;
          const why = known ? `web app ${e.message}` : `web app unreachable (${e.cause?.code || e.message})`;
          if (attempt === RETRIES) {
            this.log(`GAVE UP after ${RETRIES + 1} attempts (${why}); not on the sheet: `
              + batch.map((ev) => `${ev.type} ${ev.id}`).join(', '));
            return false;
          }
          // Jitter, so requests that failed together (the web app was down) don't all retry at the same moment.
          const delay = 2 ** attempt * (0.5 + this.random());
          this.log(`${why}; retry ${attempt + 1}/${RETRIES} in ${delay.toFixed(1)}s`);
          await this.sleep(delay);
          continue;
        }
        this.log(`sent ${batch.length}: ${summarize(batch, resp.results || [])}`);
        return true;
      }
    } finally {
      this.sending -= batch.length;
    }
  }
}

// The exception in the page Apps Script answers with (HTTP 200) when doPost throws, e.g.
// `TypeError: Cannot read properties of null (reading 'token') (line 35, file "WebApp")`, or null for any other page.
// The page shows it in the last <div>, after the logo's.
export function scriptError(html) {
  if (!html.includes('<title>Error</title>')) return null;
  const divs = [...html.matchAll(/<div[^>]*>([^<]+)<\/div>/g)];
  if (!divs.length) return null;
  const entities = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" };
  return divs.at(-1)[1].replace(/&(amp|lt|gt|quot|#39);/g, (_, e) => entities[e]).trim();
}

export function summarize(batch, results) {
  return batch.map((ev, i) => {
    const r = results[i] && typeof results[i] === 'object' ? results[i] : {};
    return `${ev.type} ${r.status || '?'}` + (r.reason ? ` (${r.reason})` : '');
  }).join(', ');
}

// Accepts tracker connections and hands each complete line to the relay. It never writes to a connection:
// lua/relay_client.lua takes a readable socket to mean the relay closed it.
export function createServer(relay) {
  return net.createServer((sock) => {
    relay.log('tracker connected');
    // Chunks can end anywhere, mid-line included; whatever follows the last newline waits in buf for the rest.
    // setEncoding holds back a multi-byte character cut across chunks, so it is never decoded in halves.
    sock.setEncoding('utf8');
    let buf = '';
    sock.on('data', (chunk) => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) relay.receive(line);
      }
    });
    sock.on('error', () => {}); // a reset; 'close' follows
    sock.on('close', () => {
      if (buf.length) relay.log(`ignored a partial line at disconnect: ${buf.slice(0, 80)}`);
      relay.log('tracker disconnected');
    });
  });
}

const USAGE = `Forward the Lua tracker's events to the Apps Script web app.

Usage: node relay/relay.mjs [--env FILE] [--port N]
       npm run relay -- [--env FILE] [--port N]

Options:
  --env FILE   file with WEB_APP_URL and TOKEN (default: .env in the repo root);
               WEB_APP_URL and TOKEN in the environment override it
  --port N     port to listen on for the tracker (default: ${PORT}; must match TRACKER_RELAY_PORT)
  -h, --help   show this help

Examples:
  npm run relay                          # the sheet in .env
  node relay/relay.mjs --env .env.dev    # the sheet in .env.dev
`;

async function main() {
  let args;
  try {
    ({ values: args } = parseArgs({
      options: {
        env: { type: 'string', default: ROOT + '.env' },
        port: { type: 'string', default: String(PORT) },
        help: { type: 'boolean', short: 'h' },
      },
    }));
  } catch (e) {
    fail(`${e.message}\n\n${USAGE}`);
  }
  if (args.help) {
    process.stdout.write(USAGE);
    return;
  }
  const env = readEnv(args.env);
  const url = process.env.WEB_APP_URL || env.WEB_APP_URL;
  const token = process.env.TOKEN || env.TOKEN;
  const port = Number(args.port);
  if (!url || !token) fail(`WEB_APP_URL and TOKEN are needed, in ${args.env} or the environment`);
  if (!URL.canParse(url)) fail(`bad WEB_APP_URL ${url}`);

  const relay = new Relay(url, token);
  const server = createServer(relay);
  await new Promise((resolve) => {
    server.once('error', (e) => fail(`cannot listen on 127.0.0.1:${port} (${e.code}); is another relay running?`));
    server.listen(port, '127.0.0.1', resolve);
  });
  relay.log(`relay: listening on 127.0.0.1:${port}; posting to ${new URL(url).host}`);
  try {
    await relay.call([]);
    relay.log('web app reachable, token accepted');
  } catch (e) {
    if (e instanceof Unauthorized) fail(`web app ${e.message}`);
    relay.log(`web app not answering yet (${e.cause?.code || e.message})`);
  }

  const stop = () => {
    const n = relay.queue.length + relay.sending;
    relay.log('stopped' + (n ? `; ${n} event(s) were not sent` : ''));
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  setInterval(() => relay.tick(), TICK);
}

function fail(msg) {
  console.error('relay: ' + msg);
  process.exit(1);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();

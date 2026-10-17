/**
 * @OnlyCurrentDoc
 */

// Web app endpoint: receives events from the local relay (which gets them from the mGBA Lua script)
// and applies them to the Rankings sheet. See docs/DESIGN.md.
//
// Script Properties:
//   TOKEN  shared secret, required on every request
//   ENV    "dev" enables the test-only `dump` and `reset` actions
//   RUN    managed by the script: trainer/run id the sheet is currently tracking

var JOURNAL = '_Events';
var ISSUES = '_Issues';
// Every event received gets a row in _Events. status is how it was handled: applied, ignored (unknown mon, full
// table, ...), failed (threw), held (another run), rejected (malformed) or reconciled (a sync); only applied rows are
// rewound, re-applied or undone, and active says whether one is on the sheet now. issue reference lists the _Issues
// rows about the event, each a link to its row. A resent event that was applied is a duplicate; one that wasn't is
// handled again and its row updated, keeping the earlier issues.
var JOURNAL_HEADERS = ['id', 'run', 'playTime', 'type', 'pid', 'payload', 'active', 'inverse', 'recorded', 'status',
  'issue reference'];
var JOURNAL_STATUS_COL = JOURNAL_HEADERS.indexOf('status') + 1;
var JOURNAL_ISSUES_COL = JOURNAL_HEADERS.indexOf('issue reference') + 1;
var ISSUE_HEADERS = ['time', 'message', 'event'];

function doPost(e) {
  var req;
  try {
    req = JSON.parse(e.postData.contents);
  } catch (err) {
    return json_({ok: false, error: 'bad-json'});
  }
  return handleRequest_(req);
}

function doGet(e) {
  return handleRequest_(e.parameter || {});
}

// Anything that throws is written to _Issues: within an event or a step of a sync it fails only that event or step;
// outside them (the lock, opening the sheet) the request answers {ok: false} and the relay retries it.
function handleRequest_(req) {
  try {
    return handleRequestUnsafe_(req);
  } catch (err) {
    logIssue_(null, 'request failed: ' + errorText_(err), req && req.events ? {events: req.events} : null);
    return json_({ok: false, error: errorText_(err)});
  }
}

function handleRequestUnsafe_(req) {
  var props = PropertiesService.getScriptProperties();
  var token = props.getProperty('TOKEN');
  if (!token || !safeEqual_(String(req.token || ''), token)) {
    return json_({ok: false, error: 'unauthorized'});
  }

  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    var ctx = newContext_();
    var action = req.action || 'events';
    var out;

    if (action === 'dump' || action === 'reset' || action === 'undo') {
      if (props.getProperty('ENV') !== 'dev') return json_({ok: false, error: 'dev-only'});
      if (action === 'dump') return json_({ok: true, state: dump_(ctx)});
      if (action === 'undo') { // same as the Undo button, for the scenario tests
        var res = undoLatest_(ctx);
        SpreadsheetApp.flush();
        sortRankings(ctx.sheet);
        return json_({ok: true, result: res});
      }
      resetDev_(ctx);
      return json_({ok: true});
    }

    if (action !== 'events') return json_({ok: false, error: 'unknown-action'});

    var events = req.events || (req.type ? [req] : []);
    var results = [];
    for (var i = 0; i < events.length; i++) {
      results.push(processEvent_(ctx, events[i]));
    }
    if (ctx.mutated) {
      guard_(ctx, 'could not sort Rankings', null, function() {
        SpreadsheetApp.flush();
        sortRankings(ctx.sheet);
      });
    }
    return json_({ok: true, results: results});
  } finally {
    lock.releaseLock();
  }
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function safeEqual_(a, b) {
  if (a.length !== b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function newContext_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  return {
    ss: ss,
    sheet: ss.getSheetByName(RANKINGS),
    journal: hiddenSheet_(ss, JOURNAL, JOURNAL_HEADERS),
    issues: hiddenSheet_(ss, ISSUES, ISSUE_HEADERS),
    ids: null,
    issueRows: [], // _Issues rows written while handling the current event
    mutated: false
  };
}

function hiddenSheet_(ss, name, headers) {
  var sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    sh.getRange(1, 1, 1, headers.length).setValues([headers]);
    sh.hideSheet();
  } else if (sh.getLastColumn() < headers.length) { // made before columns were added: head the new ones
    sh.getRange(1, 1, 1, headers.length).setValues([headers]);
  }
  return sh;
}

// Returns the row written, and adds it to ctx.issueRows for the event being handled. Never throws: a problem
// writing the issue goes to the execution log instead (and 0 is returned). ctx may be null.
function logIssue_(ctx, message, ev) {
  try {
    var sh = ctx ? ctx.issues : hiddenSheet_(SpreadsheetApp.getActiveSpreadsheet(), ISSUES, ISSUE_HEADERS);
    sh.appendRow([new Date(), message, ev ? JSON.stringify(ev).slice(0, 49000) : '']); // a cell holds 50,000 chars
    var row = sh.getLastRow();
    if (ctx) ctx.issueRows.push(row);
    return row;
  } catch (err) {
    console.error('could not write to ' + ISSUES + ': ' + errorText_(err) + '; issue was: ' + message);
    return 0;
  }
}

// Runs fn and returns true; if it throws, writes `what: <error>` to _Issues and returns false. Flushes so that
// a write the sheet rejects fails here, not in whatever touches the sheet next.
function guard_(ctx, what, ev, fn) {
  try {
    fn();
    SpreadsheetApp.flush();
    return true;
  } catch (err) {
    logIssue_(ctx, what + ': ' + errorText_(err), ev);
    return false;
  }
}

// The error's message and where it was thrown, e.g. "Exception: ... (WebApp:232)".
function errorText_(err) {
  var msg = String(err && err.message || err);
  var at = /\((\w+:\d+):\d+\)/.exec(String(err && err.stack || ''));
  return at ? msg + ' (' + at[1] + ')' : msg;
}

// ---------------------------------------------------------------- journal

function readJournal_(ctx) {
  var last = ctx.journal.getLastRow();
  if (last < 2) return [];
  var vals = ctx.journal.getRange(2, 1, last - 1, JOURNAL_HEADERS.length).getValues();
  return vals.map(function(r, i) {
    return {
      rowNum: i + 2,
      id: String(r[0]),
      run: String(r[1]),
      playTime: Number(r[2]),
      type: r[3],
      pid: r[4],
      payload: parseJson_(r[5]) || {},
      active: r[6] === true || r[6] === 'TRUE',
      inverse: parseJson_(r[7]),
      status: String(r[9] || 'applied'), // rows from before the status column were all applied
      issueRefs: String(r[10])
    };
  });
}

function parseJson_(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch (err) {
    return null; // a cut-off or hand-edited cell
  }
}

// id -> {row, status} of the events in _Events.
function knownIds_(ctx) {
  if (!ctx.ids) {
    ctx.ids = {};
    var last = ctx.journal.getLastRow();
    if (last >= 2) {
      var ids = ctx.journal.getRange(2, 1, last - 1, 1).getValues();
      var statuses = ctx.journal.getRange(2, JOURNAL_STATUS_COL, last - 1, 1).getValues();
      ids.forEach(function(r, i) {
        // rows from before the status column were all applied
        if (r[0] !== '') ctx.ids[String(r[0])] = {row: i + 2, status: String(statuses[i][0] || 'applied')};
      });
    }
  }
  return ctx.ids;
}

// Records an event in _Events with its status, referencing the _Issues rows issueRows (default: those logged while
// handling the current event): a new row, or the event's own row when it is already there (a retry). Never throws:
// if the row can't be written, that is logged to _Issues, so the event's answer still goes back.
function appendJournal_(ctx, ev, status, inverse, issueRows) {
  issueRows = issueRows || ctx.issueRows;
  var e = ev && typeof ev === 'object' ? ev : {};
  try {
    var known = e.id ? knownIds_(ctx)[e.id] : null;
    var row;
    var rest = [journalPayload_(ev), status === 'applied', inverse ? JSON.stringify(inverse) : '', new Date(), status];
    if (known) {
      row = known.row;
      ctx.journal.getRange(row, 6, 1, rest.length).setValues([rest]); // payload .. status
    } else {
      ctx.journal.appendRow([e.id || '', e.run || '', e.playTime === undefined ? '' : e.playTime, e.type || '',
        e.pid || e.old_pid || ''].concat(rest, ['']));
      row = ctx.journal.getLastRow();
    }
    if (issueRows.length) addIssueRefs_(ctx, row, issueRows);
    if (e.id) knownIds_(ctx)[e.id] = {row: row, status: status};
  } catch (err) {
    logIssue_(ctx, 'could not record ' + (e.type || 'event') + ' ' + (e.id || '') + ' in ' + JOURNAL + ': ' + errorText_(err), ev);
  }
}

// What _Events keeps of an event: all of it, except that a sync's lists are only counted. They are long, and the
// whole journal is read on every sync.
function journalPayload_(ev) {
  if (ev && ev.type === 'sync') {
    var short = {};
    Object.keys(ev).forEach(function(k) { short[k] = ev[k]; });
    if (Array.isArray(ev.mons)) short.mons = ev.mons.length + ' mons';
    if (Array.isArray(ev.defeated)) short.defeated = ev.defeated.length + ' trainers';
    return JSON.stringify(short);
  }
  return String(JSON.stringify(ev === undefined ? null : ev)).slice(0, 49000);
}

// Adds _Issues rows to a journal row's issue reference (after those already there), each a link to its row.
function addIssueRefs_(ctx, journalRow, rows) {
  var cell = ctx.journal.getRange(journalRow, JOURNAL_ISSUES_COL);
  var all = String(cell.getValue()).split(/\D+/).filter(Boolean).map(Number);
  rows.forEach(function(r) { if (r && all.indexOf(r) < 0) all.push(r); });
  if (!all.length) return;
  var text = all.join(', ');
  var rich = SpreadsheetApp.newRichTextValue().setText(text);
  var url = '#gid=' + ctx.issues.getSheetId() + '&range=A';
  var at = 0;
  all.forEach(function(r) {
    rich.setLinkUrl(at, at + String(r).length, url + r);
    at += String(r).length + 2;
  });
  cell.setNumberFormat('@'); // or Sheets reads "3, 4" as a date
  cell.setRichTextValue(rich.build());
}

function setJournalState_(ctx, entry, active, inverse) {
  ctx.journal.getRange(entry.rowNum, 7).setValue(active);
  if (inverse !== undefined) ctx.journal.getRange(entry.rowNum, 8).setValue(inverse ? JSON.stringify(inverse) : '');
}

// ---------------------------------------------------------------- events

// Handles one event and records it in _Events (unless it is already there), whatever happened to it.
function processEvent_(ctx, ev) {
  ctx.issueRows = [];
  var res;
  try {
    res = processEventUnsafe_(ctx, ev);
  } catch (err) {
    // Whatever the event wrote before the error stays on the sheet.
    logIssue_(ctx, (ev && ev.type || 'event') + ' failed: ' + errorText_(err), ev);
    res = {id: ev && ev.id, status: 'failed', reason: errorText_(err)};
  }
  if (res.status !== 'duplicate') appendJournal_(ctx, ev, res.status, res.inverse);
  delete res.inverse;
  return res;
}

function processEventUnsafe_(ctx, ev) {
  if (!ev || !ev.type || !ev.run) {
    logIssue_(ctx, 'rejected an event without a type or run', ev);
    return {status: 'rejected', reason: 'missing type/run'};
  }

  var props = PropertiesService.getScriptProperties();
  var run = props.getProperty('RUN');
  if (!run) {
    props.setProperty('RUN', String(ev.run));
  } else if (run !== String(ev.run)) {
    logIssue_(ctx, 'event from different run (' + ev.run + ' vs ' + run + '); press Reset Run to switch', ev);
    return {id: ev.id, status: 'held', reason: 'run-mismatch'};
  }

  if (ev.type === 'sync') {
    reconcile_(ctx, ev);
    return {status: 'reconciled'};
  }

  if (!ev.id) {
    logIssue_(ctx, 'rejected ' + ev.type + ' without an id', ev);
    return {status: 'rejected', reason: 'missing id'};
  }
  var known = knownIds_(ctx)[ev.id];
  if (known && known.status === 'applied') return {id: ev.id, status: 'duplicate'};

  var res = applyForward_(ctx, ev);
  SpreadsheetApp.flush(); // the sheet reports a rejected write (validation, protection) only at its next call
  if (res.error) {
    logIssue_(ctx, res.error, ev);
    return {id: ev.id, status: 'ignored', reason: res.error};
  }
  return {id: ev.id, status: 'applied', inverse: res.inverse};
}

// Applies one event to the sheet. Returns {inverse} or {error}.
function applyForward_(ctx, ev) {
  var sheet = ctx.sheet;
  var row;

  switch (ev.type) {
    case 'catch': {
      if (findRowById(sheet, ev.pid)) return {inverse: null};
      row = firstEmptyRow(sheet);
      if (!row) return {error: 'Rankings table is full'};
      sheet.getRange(row, COL.LOCATION).setValue(ev.location || '');
      initRow(sheet, row);
      sheet.getRange(row, COL.SPECIES).setValue(ev.species || '');
      sheet.getRange(row, COL.NICK).setValue(ev.nick || '');
      sheet.getRange(row, COL.ID).setValue(ev.pid);
      ctx.mutated = true;
      return {inverse: {op: 'removeMon', pid: ev.pid}};
    }
    case 'kill': {
      row = findRowById(sheet, ev.pid);
      if (!row) return {error: 'kill for unknown pid ' + ev.pid};
      var idx = Number(ev.split) - 1;
      if (!(idx >= 0 && idx < SPLIT_COUNT)) return {error: 'bad split ' + ev.split};
      addKc(sheet, row, idx, 1);
      ctx.mutated = true;
      return {inverse: {op: 'addKc', pid: ev.pid, idx: idx, delta: -1}};
    }
    case 'death': {
      row = findRowById(sheet, ev.pid);
      if (!row) return {error: 'death for unknown pid ' + ev.pid};
      var statusCell = sheet.getRange(row, COL.STATUS);
      if (statusCell.getValue() === 'Dead') return {inverse: null};
      statusCell.setValue('Dead');
      ctx.mutated = true;
      return {inverse: {op: 'setStatus', pid: ev.pid, status: 'Alive', onlyIf: 'Dead'}};
    }
    case 'evolve': {
      row = findRowById(sheet, ev.pid);
      if (!row) return {error: 'evolve for unknown pid ' + ev.pid};
      sheet.getRange(row, COL.SPECIES).setValue(ev.to);
      var inverse = {op: 'setSpecies', pid: ev.pid, species: ev.from, onlyIf: ev.to};
      if (ev.nick) { // the game renamed a mon that still had its species name
        var nickCell = sheet.getRange(row, COL.NICK);
        inverse.nick = nickCell.getValue();
        inverse.nickIf = ev.nick;
        nickCell.setValue(ev.nick);
      }
      ctx.mutated = true;
      return {inverse: inverse};
    }
    case 'trade': {
      row = findRowById(sheet, ev.old_pid);
      if (!row) return {error: 'trade for unknown pid ' + ev.old_pid};
      var old = {
        pid: ev.old_pid,
        species: sheet.getRange(row, COL.SPECIES).getValue(),
        nick: sheet.getRange(row, COL.NICK).getValue(),
        location: sheet.getRange(row, COL.LOCATION).getValue()
      };
      sheet.getRange(row, COL.ID).setValue(ev.pid);
      sheet.getRange(row, COL.SPECIES).setValue(ev.species || '');
      sheet.getRange(row, COL.NICK).setValue(ev.nick || '');
      sheet.getRange(row, COL.LOCATION).setValue(ev.location || '');
      ctx.mutated = true;
      return {inverse: {op: 'swapBack', pid: ev.pid, old: old}};
    }
    case 'split': {
      var prev = getBadges(sheet);
      setBadges(sheet, Number(ev.badges));
      return {inverse: {op: 'setBadges', value: prev, onlyIf: Number(ev.badges)}};
    }
    default:
      return {error: 'unknown event type ' + ev.type};
  }
}

// Applies an inverse operation. Conditional: if the sheet no longer looks like what the event produced
// (e.g. a manual edit), it is skipped and recorded in _Issues rather than fought; returns false then.
function applyInverse_(ctx, inv, ev) {
  if (!inv) return;
  var sheet = ctx.sheet;
  var row;
  switch (inv.op) {
    case 'removeMon': {
      row = findRowById(sheet, inv.pid);
      if (!row) return;
      sheet.getRange(row, COL.GENDER).clearContent();
      sheet.getRange(row, COL.STATUS).clearContent();
      sheet.getRange(row, COL.NICK, 1, COL.TOTAL - COL.NICK + 1).clearContent();
      sheet.getRange(row, COL.ID).clearContent();
      ctx.mutated = true;
      return;
    }
    case 'addKc': {
      row = findRowById(sheet, inv.pid);
      if (!row) return;
      addKc(sheet, row, inv.idx, inv.delta);
      ctx.mutated = true;
      return;
    }
    case 'setStatus': {
      row = findRowById(sheet, inv.pid);
      if (!row) return;
      var cell = sheet.getRange(row, COL.STATUS);
      if (inv.onlyIf && cell.getValue() !== inv.onlyIf) {
        logIssue_(ctx, 'skipped undo: status of ' + inv.pid + ' was edited', ev);
        return false;
      }
      cell.setValue(inv.status);
      ctx.mutated = true;
      return;
    }
    case 'setSpecies': {
      row = findRowById(sheet, inv.pid);
      if (!row) return;
      var sp = sheet.getRange(row, COL.SPECIES);
      if (inv.onlyIf && sp.getValue() !== inv.onlyIf) {
        logIssue_(ctx, 'skipped undo: species of ' + inv.pid + ' was edited', ev);
        return false;
      }
      sp.setValue(inv.species);
      ctx.mutated = true;
      if (inv.nickIf !== undefined) {
        var nick = sheet.getRange(row, COL.NICK);
        if (nick.getValue() !== inv.nickIf) {
          logIssue_(ctx, 'skipped undo: nickname of ' + inv.pid + ' was edited', ev);
          return false;
        }
        nick.setValue(inv.nick);
      }
      return;
    }
    case 'swapBack': {
      row = findRowById(sheet, inv.pid);
      if (!row) return;
      sheet.getRange(row, COL.ID).setValue(inv.old.pid);
      sheet.getRange(row, COL.SPECIES).setValue(inv.old.species);
      sheet.getRange(row, COL.NICK).setValue(inv.old.nick);
      sheet.getRange(row, COL.LOCATION).setValue(inv.old.location);
      ctx.mutated = true;
      return;
    }
    case 'setBadges': {
      if (inv.onlyIf !== undefined && getBadges(sheet) !== inv.onlyIf) {
        logIssue_(ctx, 'skipped undo: badges was edited', ev);
        return false;
      }
      setBadges(sheet, inv.value);
      return;
    }
  }
}

// ---------------------------------------------------------------- reconcile (sync)

// sync: {run, playTime, mons:[{pid,species,nick,location,hp,where}], defeated:[...], badges, complete}
function reconcile_(ctx, sync) {
  var entries = readJournal_(ctx).filter(function(en) { return en.run === String(sync.run) && en.status === 'applied'; });
  var present = {};
  (sync.mons || []).forEach(function(m) { present[m.pid] = m; });
  var defeated = null;
  if (sync.defeated) {
    defeated = {};
    sync.defeated.forEach(function(d) { defeated[String(d)] = true; });
  }

  // 1. Which mons' arrival events hold in this timeline (dependent events inherit this)
  var arrival = {};
  entries.forEach(function(en) {
    if (en.type === 'catch') arrival[en.pid] = arrivalHolds_(en, sync, present);
    if (en.type === 'trade') arrival[en.payload.pid] = arrivalHolds_(en, sync, present);
  });

  // 2. Desired active state per entry
  var desired = entries.map(function(en) {
    return shouldBeActive_(en, sync, present, defeated, arrival);
  });

  // The same enemy mon can only have been killed once: keep the most recently recorded credit
  var lastForKey = {};
  entries.forEach(function(en, i) {
    if (en.type === 'kill' && desired[i] && en.payload.key) lastForKey[en.payload.key] = i;
  });
  entries.forEach(function(en, i) {
    if (en.type === 'kill' && desired[i] && en.payload.key && lastForKey[en.payload.key] !== i) desired[i] = false;
  });

  // 3. Undo newest-first, then redo oldest-first
  // An entry whose undo or redo throws keeps its state, so the next sync tries it again.
  for (var i = entries.length - 1; i >= 0; i--) {
    if (entries[i].active && !desired[i]) {
      forEntry_(ctx, entries[i], 'sync could not undo ' + entries[i].type, function(en) {
        applyInverse_(ctx, en.inverse, en.payload);
        SpreadsheetApp.flush();
        setJournalState_(ctx, en, false);
      });
    }
  }
  entries.forEach(function(en, i) {
    if (!en.active && desired[i]) {
      forEntry_(ctx, en, 'sync could not re-apply ' + en.type, function() {
        var res = applyForward_(ctx, en.payload);
        SpreadsheetApp.flush();
        if (res.error) {
          logIssue_(ctx, 'could not re-apply: ' + res.error, en.payload);
        } else {
          setJournalState_(ctx, en, true, res.inverse);
        }
      });
    }
  });

  // 4. Sync what the game stores directly: species / nickname / location, missing mons, badges
  var sheet = ctx.sheet;
  Object.keys(present).forEach(function(pid) {
    guard_(ctx, 'sync could not update ' + pid, present[pid], function() { syncMon_(ctx, sync, pid, present[pid]); });
  });

  if (sync.complete) {
    guard_(ctx, 'sync could not check for mons missing from the game', null, function() {
      var n = rowCount_();
      var ids = sheet.getRange(FIRST_ROW, COL.ID, n, 1).getValues();
      ids.forEach(function(r) {
        if (r[0] !== '' && !present[r[0]]) logIssue_(ctx, 'mon ' + r[0] + ' is on the sheet but not in the game', null);
      });
    });
  }

  if (sync.badges !== undefined) {
    guard_(ctx, 'sync could not set badges', null, function() {
      if (getBadges(sheet) !== Number(sync.badges)) setBadges(sheet, Number(sync.badges));
    });
  }
}

// Runs fn(en) for a journal entry the sync rewinds or re-applies, like guard_; the issues it logs are referenced from
// the entry's row as well as the sync's.
function forEntry_(ctx, en, what, fn) {
  var before = ctx.issueRows.length;
  guard_(ctx, what, en.payload, function() { fn(en); });
  var rows = ctx.issueRows.slice(before);
  if (rows.length) guard_(ctx, 'could not reference issues from ' + JOURNAL, null, function() { addIssueRefs_(ctx, en.rowNum, rows); });
}

// Adds a mon from a sync that isn't on the sheet, or brings its species and nickname in line with the game.
function syncMon_(ctx, sync, pid, m) {
  var sheet = ctx.sheet;
  var row = findRowById(sheet, pid);
  if (!row) {
    var synth = {
      id: 'reconcile:' + sync.run + ':' + pid + ':' + Date.now(),
      run: sync.run, playTime: sync.playTime, type: 'catch', pid: pid,
      species: m.species, nick: m.nick || '', location: m.location || '', source: 'reconcile'
    };
    var before = ctx.issueRows.length;
    var res = applyForward_(ctx, synth);
    SpreadsheetApp.flush();
    if (res.error) logIssue_(ctx, res.error, synth);
    appendJournal_(ctx, synth, res.error ? 'ignored' : 'applied', res.inverse, ctx.issueRows.slice(before));
    return;
  }
  if (m.species && sheet.getRange(row, COL.SPECIES).getValue() !== m.species) {
    sheet.getRange(row, COL.SPECIES).setValue(m.species);
    ctx.mutated = true;
  }
  if (m.nick !== undefined && sheet.getRange(row, COL.NICK).getValue() !== m.nick) {
    sheet.getRange(row, COL.NICK).setValue(m.nick);
    ctx.mutated = true;
  }
}

function arrivalHolds_(en, sync, present) {
  if (en.playTime > sync.playTime) return false;
  var pid = en.type === 'trade' ? en.payload.pid : en.pid;
  return !!present[pid];
}

function shouldBeActive_(en, sync, present, defeated, arrival) {
  if (en.playTime > sync.playTime) return false;
  var m;
  switch (en.type) {
    case 'catch':
    case 'trade':
      return !!arrival[en.type === 'trade' ? en.payload.pid : en.pid];
    case 'evolve':
      if (arrival[en.pid] === false) return false;
      return !!present[en.pid];
    case 'death':
      if (arrival[en.pid] === false) return false;
      m = present[en.pid];
      return !(m && m.where === 'party' && m.hp > 0);
    case 'kill':
      if (arrival[en.pid] === false) return false;
      if (defeated && en.payload.trainer !== undefined) return !!defeated[String(en.payload.trainer)];
      return true;
    case 'split':
      return true; // badges are set directly from the snapshot
  }
  return true;
}

// ---------------------------------------------------------------- undo (button)

// Called by the Undo button: reverts the newest active journal entry that changed the sheet and deletes it
// from the journal, so a later sync can't re-apply it. Entries already undone by a rewind and no-ops
// are skipped. If the mon's row is gone (cleared by hand), nothing is reverted but the entry is still deleted,
// so the next press moves on. Returns {undone: description, partial, missing} or {undone: null}.
function undoLatest_(ctx) {
  var entries = readJournal_(ctx);
  for (var i = entries.length - 1; i >= 0; i--) {
    var en = entries[i];
    if (en.status !== 'applied' || !en.active || !en.inverse) continue;
    var what = describeEntry_(ctx, en);
    var missing = en.inverse.pid !== undefined && !findRowById(ctx.sheet, en.inverse.pid);
    var ok = true;
    if (missing) logIssue_(ctx, 'skipped undo: ' + en.inverse.pid + ' is not on the sheet', en.payload);
    else ok = applyInverse_(ctx, en.inverse, en.payload);
    ctx.journal.deleteRow(en.rowNum);
    return {undone: what, partial: ok === false, missing: missing};
  }
  return {undone: null};
}

function describeEntry_(ctx, en) {
  var ev = en.payload;
  var row = findRowById(ctx.sheet, en.pid);
  var name = row ? (ctx.sheet.getRange(row, COL.NICK).getValue() || ctx.sheet.getRange(row, COL.SPECIES).getValue()) : en.pid;
  switch (en.type) {
    case 'catch': return 'catch of ' + (ev.nick || ev.species);
    case 'kill': return 'KO by ' + name + ' (split ' + ev.split + ')';
    case 'death': return 'death of ' + name;
    case 'evolve': return 'evolution ' + ev.from + ' → ' + ev.to;
    case 'trade': return 'trade for ' + (ev.nick || ev.species);
    case 'split': return 'split change to ' + ev.badges + ' badges';
  }
  return en.type;
}

// ---------------------------------------------------------------- run reset + dev-only actions

// Called by the Reset Run button.
function resetRunState_() {
  PropertiesService.getScriptProperties().deleteProperty('RUN');
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  [JOURNAL, ISSUES].forEach(function(name) {
    var sh = ss.getSheetByName(name);
    if (sh && sh.getLastRow() > 1) sh.getRange(2, 1, sh.getLastRow() - 1, sh.getLastColumn()).clearContent();
  });
}

function resetDev_(ctx) {
  clearRankings(ctx.sheet);
  setBadges(ctx.sheet, 0);
  resetRunState_();
}

function dump_(ctx) {
  var sheet = ctx.sheet;
  var n = rowCount_();
  var width = COL.ID - COL.GENDER + 1;
  var range = sheet.getRange(FIRST_ROW, COL.GENDER, n, width);
  var values = range.getValues();
  var formulas = range.getFormulas();
  var off = function(col) { return col - COL.GENDER; };
  var rows = [];
  for (var i = 0; i < n; i++) {
    var v = values[i];
    if (v[off(COL.LOCATION)] === '' && v[off(COL.SPECIES)] === '' && v[off(COL.ID)] === '') continue;
    var f = {};
    for (var c = 0; c < width; c++) {
      if (formulas[i][c]) f[colLetter_(COL.GENDER + c)] = formulas[i][c];
    }
    rows.push({
      row: FIRST_ROW + i,
      id: v[off(COL.ID)],
      status: v[off(COL.STATUS)],
      nick: v[off(COL.NICK)],
      species: v[off(COL.SPECIES)],
      location: v[off(COL.LOCATION)],
      kc: v.slice(off(COL.KC_FIRST), off(COL.KC_LAST) + 1),
      total: v[off(COL.TOTAL)],
      formulas: f
    });
  }
  var panel = function(row) { return sheet.getRange(row, PANEL.COL).getValue(); };
  return {
    rows: rows,
    panel: {attempt: panel(2), alive: panel(3), badges: panel(4), deaths: panel(5), koTotal: panel(6)},
    run: PropertiesService.getScriptProperties().getProperty('RUN'),
    journal: readJournal_(ctx).map(function(en) {
      return {id: en.id, type: en.type, pid: en.pid, playTime: en.playTime, active: en.active, status: en.status, issues: en.issueRefs};
    }),
    issues: ctx.issues.getLastRow() > 1
      ? ctx.issues.getRange(2, 2, ctx.issues.getLastRow() - 1, 1).getValues().map(function(r) { return r[0]; })
      : []
  };
}

function colLetter_(col) {
  var s = '';
  while (col > 0) {
    var m = (col - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    col = Math.floor((col - 1) / 26);
  }
  return s;
}

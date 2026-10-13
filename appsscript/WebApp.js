/**
 * @OnlyCurrentDoc
 */

// Web app endpoint: receives events from the local relay (which gets them from the mGBA Lua script)
// and applies them to the Rankings sheet. See DESIGN.md.
//
// Script Properties:
//   TOKEN  shared secret, required on every request
//   ENV    "dev" enables the test-only `dump` and `reset` actions
//   RUN    managed by the script: trainer/run id the sheet is currently tracking

var JOURNAL = '_Events';
var ISSUES = '_Issues';
var JOURNAL_HEADERS = ['id', 'run', 'playTime', 'type', 'pid', 'payload', 'active', 'inverse', 'recorded'];
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

function handleRequest_(req) {
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
      SpreadsheetApp.flush();
      sortRankings(ctx.sheet);
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
    mutated: false
  };
}

function hiddenSheet_(ss, name, headers) {
  var sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    sh.getRange(1, 1, 1, headers.length).setValues([headers]);
    sh.hideSheet();
  }
  return sh;
}

function logIssue_(ctx, message, ev) {
  ctx.issues.appendRow([new Date(), message, ev ? JSON.stringify(ev) : '']);
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
      payload: r[5] ? JSON.parse(r[5]) : {},
      active: r[6] === true || r[6] === 'TRUE',
      inverse: r[7] ? JSON.parse(r[7]) : null
    };
  });
}

function knownIds_(ctx) {
  if (!ctx.ids) {
    ctx.ids = {};
    var last = ctx.journal.getLastRow();
    if (last >= 2) {
      ctx.journal.getRange(2, 1, last - 1, 1).getValues().forEach(function(r) { ctx.ids[String(r[0])] = true; });
    }
  }
  return ctx.ids;
}

function appendJournal_(ctx, ev, inverse, active) {
  ctx.journal.appendRow([
    ev.id, ev.run, ev.playTime, ev.type, ev.pid || ev.old_pid || '',
    JSON.stringify(ev), active, inverse ? JSON.stringify(inverse) : '', new Date()
  ]);
  knownIds_(ctx)[ev.id] = true;
}

function setJournalState_(ctx, entry, active, inverse) {
  ctx.journal.getRange(entry.rowNum, 7).setValue(active);
  if (inverse !== undefined) ctx.journal.getRange(entry.rowNum, 8).setValue(inverse ? JSON.stringify(inverse) : '');
}

// ---------------------------------------------------------------- events

function processEvent_(ctx, ev) {
  if (!ev || !ev.type || !ev.run) return {status: 'rejected', reason: 'missing type/run'};

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

  if (!ev.id) return {status: 'rejected', reason: 'missing id'};
  if (knownIds_(ctx)[ev.id]) return {id: ev.id, status: 'duplicate'};

  var res = applyForward_(ctx, ev);
  if (res.error) {
    logIssue_(ctx, res.error, ev);
    return {id: ev.id, status: 'ignored', reason: res.error};
  }
  appendJournal_(ctx, ev, res.inverse, true);
  return {id: ev.id, status: 'applied'};
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
  var entries = readJournal_(ctx).filter(function(en) { return en.run === String(sync.run); });
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
  for (var i = entries.length - 1; i >= 0; i--) {
    if (entries[i].active && !desired[i]) {
      applyInverse_(ctx, entries[i].inverse, entries[i].payload);
      setJournalState_(ctx, entries[i], false);
    }
  }
  entries.forEach(function(en, i) {
    if (!en.active && desired[i]) {
      var res = applyForward_(ctx, en.payload);
      if (res.error) {
        logIssue_(ctx, 'could not re-apply: ' + res.error, en.payload);
      } else {
        setJournalState_(ctx, en, true, res.inverse);
      }
    }
  });

  // 4. Sync what the game stores directly: species / nickname / location, missing mons, badges
  var sheet = ctx.sheet;
  Object.keys(present).forEach(function(pid) {
    var m = present[pid];
    var row = findRowById(sheet, pid);
    if (!row) {
      var synth = {
        id: 'reconcile:' + sync.run + ':' + pid + ':' + Date.now(),
        run: sync.run, playTime: sync.playTime, type: 'catch', pid: pid,
        species: m.species, nick: m.nick || '', location: m.location || '', source: 'reconcile'
      };
      var res = applyForward_(ctx, synth);
      if (res.error) logIssue_(ctx, res.error, synth);
      else appendJournal_(ctx, synth, res.inverse, true);
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
  });

  if (sync.complete) {
    var n = rowCount_();
    var ids = sheet.getRange(FIRST_ROW, COL.ID, n, 1).getValues();
    ids.forEach(function(r) {
      if (r[0] !== '' && !present[r[0]]) logIssue_(ctx, 'mon ' + r[0] + ' is on the sheet but not in the game', null);
    });
  }

  if (sync.badges !== undefined && getBadges(sheet) !== Number(sync.badges)) {
    setBadges(sheet, Number(sync.badges));
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
    if (!en.active || !en.inverse) continue;
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
      return {id: en.id, type: en.type, pid: en.pid, playTime: en.playTime, active: en.active};
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

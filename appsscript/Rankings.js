// Shared helpers for the Rankings tab. Used by both the manual onEdit handlers (Sorter.js)
// and the automatic web app (WebApp.js), so both paths behave identically.

var RANKINGS = 'Rankings';

var FIRST_ROW = 3;
var LAST_ROW = 102;

// 1-based column indexes on Rankings
var COL = {
  GENDER: 4,    // D
  STATUS: 6,    // F
  NICK: 8,      // H
  SPECIES: 9,   // I
  LOCATION: 10, // J
  KC_FIRST: 11, // K (Split 1)
  KC_LAST: 19,  // S (E4 split)
  TOTAL: 20,    // T
  ADD_KO: 23,   // W
  ID: 25        // Y (hidden "pidotid" key, written only by the web app)
};
var SPLIT_COUNT = COL.KC_LAST - COL.KC_FIRST + 1; // 9

// Right-hand panel (column AA = 27)
var PANEL = {
  COL: 27,
  ATTEMPT_ROW: 2,
  BADGES_ROW: 4, // also the current split offset: KC column = KC_FIRST + badges
  ADVANCE_ROW: 7,
  RESET_ROW: 9
};

// Sorted block: everything the old script sorted (D:T) plus the ID column so it travels with its row.
var SORT_RANGE = 'D' + FIRST_ROW + ':Y' + LAST_ROW;

function getRankings_() {
  return SpreadsheetApp.getActiveSpreadsheet().getSheetByName(RANKINGS);
}

function rowCount_() {
  return LAST_ROW - FIRST_ROW + 1;
}

// Sets the Total KC cell for a row to the sum of the nine split cells.
function recomputeTotal(sheet, row) {
  var vals = sheet.getRange(row, COL.KC_FIRST, 1, SPLIT_COUNT).getValues()[0];
  var sum = 0;
  for (var i = 0; i < vals.length; i++) sum += Number(vals[i]) || 0;
  sheet.getRange(row, COL.TOTAL).setValue(sum);
  return sum;
}

// Row set up as a freshly encountered mon (what entering an Encounter Location does by hand).
function initRow(sheet, row) {
  sheet.getRange(row, COL.STATUS).setValue('Alive');
  sheet.getRange(row, COL.KC_FIRST, 1, SPLIT_COUNT).setValue(0);
  sheet.getRange(row, COL.TOTAL).setValue(0);
}

// Row blanked as if the Encounter Location had been removed by hand.
function blankRow(sheet, row) {
  sheet.getRange(row, COL.STATUS).setValue('');
  sheet.getRange(row, COL.KC_FIRST, 1, SPLIT_COUNT).setValue('');
  sheet.getRange(row, COL.TOTAL).setFormula('');
}

// Adds delta to the KC cell for splitIdx (0-based, 0..8), never below 0, and refreshes the total.
function addKc(sheet, row, splitIdx, delta) {
  var cell = sheet.getRange(row, COL.KC_FIRST + splitIdx);
  var next = Math.max(0, (Number(cell.getValue()) || 0) + delta);
  cell.setValue(next);
  recomputeTotal(sheet, row);
  return next;
}

// Total KC descending, then Status ascending (stable, so Alive above Dead, each ordered by KC).
function sortRankings(sheet) {
  var toSort = sheet.getRange(SORT_RANGE);
  toSort.sort([{column: COL.TOTAL, ascending: false}]);
  toSort.sort([{column: COL.STATUS, ascending: true}]);
}

// Everything Reset Run wipes, plus the ID column. Does not touch the attempt counter or badges.
function clearRankings(sheet) {
  sheet.getRange('D' + FIRST_ROW + ':D' + LAST_ROW).clearContent();
  sheet.getRange('F' + FIRST_ROW + ':F' + LAST_ROW).clearContent();
  sheet.getRange('H' + FIRST_ROW + ':T' + LAST_ROW).clearContent();
  sheet.getRange('Y' + FIRST_ROW + ':Y' + LAST_ROW).clearContent();
}

// Row number (3..102) holding the given mon ID, or 0.
function findRowById(sheet, id) {
  var ids = sheet.getRange(FIRST_ROW, COL.ID, rowCount_(), 1).getValues();
  for (var i = 0; i < ids.length; i++) {
    if (ids[i][0] === id) return FIRST_ROW + i;
  }
  return 0;
}

// First row with no encounter location, species or ID, or 0 if the table is full.
function firstEmptyRow(sheet) {
  var n = rowCount_();
  var loc = sheet.getRange(FIRST_ROW, COL.LOCATION, n, 1).getValues();
  var species = sheet.getRange(FIRST_ROW, COL.SPECIES, n, 1).getValues();
  var ids = sheet.getRange(FIRST_ROW, COL.ID, n, 1).getValues();
  for (var i = 0; i < n; i++) {
    if (loc[i][0] === '' && species[i][0] === '' && ids[i][0] === '') return FIRST_ROW + i;
  }
  return 0;
}

function getBadges(sheet) {
  return Number(sheet.getRange(PANEL.BADGES_ROW, PANEL.COL).getValue()) || 0;
}

function setBadges(sheet, n) {
  sheet.getRange(PANEL.BADGES_ROW, PANEL.COL).setValue(n);
}

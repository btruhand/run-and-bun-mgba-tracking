function onEdit(e) {
  var range = e.range;
  var sheet = range.getSheet();
  var name = sheet.getName();

  try {
    if (name === RANKINGS) onEditRankings_(e, sheet, range);
    else if (name === "Planner") onEditPlanner_(e, sheet, range);
    else if (name === "Preparation") onEditPreparation_(e, sheet, range);

    if (name === RANKINGS) sortRankings(sheet);
  } catch (err) {
    var where = name + '!' + range.getA1Notation();
    logIssue_(null, 'edit of ' + where + ' failed: ' + errorText_(err), null);
    e.source.toast('Something went wrong handling the edit of ' + where + '; see _Issues.', 'Error');
  }
}

function inRankRows_(range) {
  return range.getRow() >= FIRST_ROW && range.getRow() <= LAST_ROW;
}

function onEditRankings_(e, sheet, range) {
  var col = range.getColumn();
  var row = range.getRow();

  // Keep Total KC in step when a split cell is edited by hand
  if (col >= COL.KC_FIRST && col <= COL.KC_LAST && inRankRows_(range)) {
    recomputeTotal(sheet, row);
  }

  // Selecting an encounter location initialises the row; erasing it blanks the row
  if (col === COL.LOCATION && inRankRows_(range)) {
    if (range.getValue() === '') blankRow(sheet, row);
    else initRow(sheet, row);
  }

  // KC button: +1 KO in the current split column (current split = Badges)
  if (col === COL.ADD_KO && inRankRows_(range) && e.value == 'TRUE') {
    addKc(sheet, row, getBadges(sheet), 1);
    range.setValue(false);
  }

  // RESET RUN: wipes the table and increments the attempt counter by 1
  if (col === PANEL.COL && row === PANEL.RESET_ROW && e.value == 'TRUE') {
    clearRankings(sheet);
    resetRunState_();
    var attempt = sheet.getRange(PANEL.ATTEMPT_ROW, PANEL.COL);
    attempt.setValue(attempt.getValue() + 1);
    setBadges(sheet, 0);
    range.setValue(false);
  }

  // UNDO LATEST TRACKING CHANGE: reverts the newest web-app event and removes it from _Events
  if (col === PANEL.COL && row === PANEL.UNDO_ROW && e.value == 'TRUE') {
    range.setValue(false);
    var lock = LockService.getScriptLock();
    if (!lock.tryLock(10000)) {
      e.source.toast('The tracker is busy, try again in a moment.', 'Undo');
      return;
    }
    try {
      var res = undoLatest_(newContext_());
      SpreadsheetApp.flush();
      if (!res.undone) e.source.toast('Nothing to undo.', 'Undo');
      else if (res.missing) e.source.toast('Removed ' + res.undone + ' from the log, but that mon is no longer on the sheet, so nothing changed.', 'Undo');
      else e.source.toast('Undid ' + res.undone + (res.partial ? '. Part of it was edited by hand and kept; see _Issues.' : '.'), 'Undo');
    } finally {
      lock.releaseLock();
    }
  }

  // ADVANCE SPLIT: Badges + 1
  if (col === PANEL.COL && row === PANEL.ADVANCE_ROW && e.value == 'TRUE') {
    setBadges(sheet, getBadges(sheet) + 1);
    range.setValue(false);
  }
}

// Clear button for planning sheet
function onEditPlanner_(e, sheet, range) {
  if (range.getColumn() == 15 && range.getRow() == 3 && e.value == 'TRUE') {
    // Clear content in specified ranges
    sheet.getRange("C4:D905").clearContent();
    sheet.getRange("H4:H905").clearContent();
    sheet.getRange("L4:L905").clearContent();
    sheet.getRange("R4:S905").clearContent();
    sheet.getRange("Z4:AB905").clearContent();
    sheet.getRange("AF4:AF905").clearContent();
    sheet.getRange("AJ4:AJ905").clearContent();

    var ranges = [
      'J4:J905',
      'AD4:AD905',
      'AH4:AH905'
    ];

    ranges.forEach(function(rangeStr) {
      var r = sheet.getRange(rangeStr);
      var values = r.getValues();

      // Loop through each cell in the range
      for (var i = 0; i < values.length; i++) {
        if ((i + 1) % 3 !== 0) {
          values[i][0] = false;
        }
      }

      r.setValues(values);
    });

    range.setValue(false);
  }
}

// Clear button for prep sheet
function onEditPreparation_(e, sheet, range) {
  if (range.getColumn() == 12 && range.getRow() == 3 && e.value == 'TRUE') {
    sheet.getRange("D4:E9").clearContent();
    sheet.getRange("G4:J9").clearContent();
    sheet.getRange("P4:P9").clearContent();
    sheet.getRange("R4:U9").clearContent();
    sheet.getRange("F4:F9").clearContent();
    sheet.getRange("Q4:Q9").clearContent();
    range.setValue(false);
  }
}

function autoSortRange() {
  sortRankings(getRankings_());
}

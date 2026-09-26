/**
 * Sends edits made in this spreadsheet to the application's API.
 *
 * Set up once per spreadsheet (Extensions > Apps Script, paste this and
 * appsscript.json, then Project Settings > Script properties):
 *   API_URL        the API's address (Terraform output api_url)
 *   SHEETS_SECRET  the signing secret, the same value as the API's
 *                  SHEETS_WEBHOOK_SECRET
 * Then run install() once and grant access.
 *
 * Only the changed cells are sent, signed; the API applies each only if the
 * app still has the value this row last showed, and writes the outcome to
 * _status. Changes the API itself writes do not fire this, so nothing loops.
 */

var CONTROL = ['_id', '_status', '_version', '_hashes'];

function install() {
  var ss = SpreadsheetApp.getActive();
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncEdit') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('syncEdit').forSpreadsheet(ss).onEdit().create();
  ss.getSheets().forEach(function (sheet) {
    var headers = headerRow(sheet);
    CONTROL.forEach(function (name) {
      var col = headers.indexOf(name) + 1;
      if (col < 1) return;
      if (name !== '_status') sheet.hideColumns(col);
      var p = sheet.getRange(1, col, sheet.getMaxRows(), 1).protect();
      p.setDescription('Kept by the sync. Do not edit.');
      p.removeEditors(p.getEditors());
      if (p.canDomainEdit()) p.setDomainEdit(false);
    });
  });
}

function syncEdit(e) {
  var props = PropertiesService.getScriptProperties();
  var apiUrl = props.getProperty('API_URL');
  var secret = props.getProperty('SHEETS_SECRET');
  if (!apiUrl || !secret) return;
  var sheet = e.range.getSheet();
  var headers = headerRow(sheet);
  var idCol = headers.indexOf('_id');
  var statusCol = headers.indexOf('_status');
  var hashesCol = headers.indexOf('_hashes');
  if (idCol < 0 || statusCol < 0 || hashesCol < 0) return;

  var first = e.range.getRow();
  var values = e.range.getValues();
  for (var r = 0; r < values.length; r++) {
    var rowNumber = first + r;
    if (rowNumber < 2) continue;
    var row = sheet.getRange(rowNumber, 1, 1, headers.length).getValues()[0];
    var hashes = {};
    try { hashes = JSON.parse(row[hashesCol] || '{}'); } catch (ignored) {}
    var edits = [];
    for (var c = 0; c < values[r].length; c++) {
      var header = headers[e.range.getColumn() - 1 + c];
      if (!header || CONTROL.indexOf(header) >= 0) continue;
      edits.push({ header: header, value: String(values[r][c]), base: hashes[header] || '' });
    }
    if (edits.length === 0) continue;
    var body = JSON.stringify({
      spreadsheetId: sheet.getParent().getId(),
      tab: sheet.getName(),
      row: rowNumber,
      id: String(row[idCol] || ''),
      edits: edits
    });
    var timestamp = String(Math.floor(Date.now() / 1000));
    var nonce = Utilities.getUuid();
    var signature = Utilities.base64Encode(
      Utilities.computeHmacSha256Signature(
        timestamp + '.' + nonce + '.' + body, secret, Utilities.Charset.UTF_8));
    var response = UrlFetchApp.fetch(apiUrl.replace(/\/$/, '') + '/webhooks/sheets', {
      method: 'post',
      contentType: 'application/json; charset=utf-8',
      payload: body,
      headers: {
        'x-sheets-timestamp': timestamp,
        'x-sheets-nonce': nonce,
        'x-sheets-signature': signature
      },
      muteHttpExceptions: true
    });
    if (response.getResponseCode() !== 200) {
      sheet.getRange(rowNumber, statusCol + 1).setValue(
        'not synced (' + response.getResponseCode() + '): try again, or edit in the app');
    }
  }
}

function headerRow(sheet) {
  var last = sheet.getLastColumn();
  if (last < 1) return [];
  return sheet.getRange(1, 1, 1, last).getValues()[0].map(String);
}

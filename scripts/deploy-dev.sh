#!/usr/bin/env bash
# Pushes the Apps Script files to the DEV copy of the sheet only and (re)deploys the web app.
# Stages files in .build/dev with the dev scriptId so the real project (.clasp.json) is never touched.
#
# Why stage instead of `clasp -P .clasp.dev.json`: clasp 3.x rejects a non-default project file with
# "srcDir escapes project root", even with rootDir set. Copying the files flat into .build/dev next to a
# copy of .clasp.dev.json (renamed .clasp.json) sidesteps that, and is also why .clasp.dev.json has no
# rootDir: the staged files are already at the top level. As a result .clasp.dev.json only works through
# this script. Create both clasp files with `npm run setup-clasp`.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE=.build/dev
FILES=(appsscript/appsscript.json appsscript/Sorter.js appsscript/Rankings.js appsscript/WebApp.js)
CLASP="$PWD/node_modules/.bin/clasp"

rm -rf "$STAGE" && mkdir -p "$STAGE"
cp .clasp.dev.json "$STAGE/.clasp.json"
cp "${FILES[@]}" "$STAGE/"

cd "$STAGE"
"$CLASP" push --force

cd - >/dev/null
DEP_ID=$(grep -E '^DEPLOYMENT_ID=' .env 2>/dev/null | cut -d= -f2- || true)
cd "$STAGE"
if [ -n "$DEP_ID" ]; then
  "$CLASP" redeploy "$DEP_ID" -d "dev $(date +%H:%M:%S)"
else
  OUT=$("$CLASP" deploy -d "dev web app")
  echo "$OUT"
  DEP_ID=$(echo "$OUT" | grep -oE 'AKfycb[A-Za-z0-9_-]+' | head -1)
  cd - >/dev/null
  [ -n "$DEP_ID" ] || { echo "could not parse deployment id" >&2; exit 1; }
  printf 'DEPLOYMENT_ID=%s\nWEB_APP_URL=https://script.google.com/macros/s/%s/exec\n' "$DEP_ID" "$DEP_ID" >> .env
  echo "Saved DEPLOYMENT_ID and WEB_APP_URL to .env"
fi

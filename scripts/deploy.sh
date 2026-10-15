#!/usr/bin/env bash
# Pushes the Apps Script files to the script in a clasp project file and (re)deploys the web app, then writes the
# deployment's DEPLOYMENT_ID and WEB_APP_URL to an env file (replacing any already there).
#
#   scripts/deploy.sh                                       # .clasp.json, .env
#   scripts/deploy.sh --clasp .clasp.dev.json --env .env.dev  # what deploy-dev.sh runs
#
# Stages the files in .build/<clasp file name> next to a .clasp.json holding only the scriptId, because clasp 3.x
# rejects a non-default project file with "srcDir escapes project root", even with rootDir set. The project file's
# rootDir is therefore ignored. If the env file has a DEPLOYMENT_ID, that deployment is updated so the URL stays the
# same; otherwise a new one is created.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Push the Apps Script files and (re)deploy the web app; write DEPLOYMENT_ID and WEB_APP_URL to the env file.

Usage: npm run deploy -- [--clasp FILE] [--env FILE]
       scripts/deploy.sh [--clasp FILE] [--env FILE]

Options:
  --clasp FILE  clasp project file with the scriptId to push to (default: .clasp.json)
  --env FILE    file to read DEPLOYMENT_ID from and write DEPLOYMENT_ID and WEB_APP_URL to (default: .env)
  -h, --help    show this help

Examples:
  npm run deploy                                          # your sheet
  npm run deploy -- --clasp .clasp.dev.json --env .env.dev  # the dev copy (same as npm run deploy:dev)
EOF
}

CLASP_FILE=.clasp.json
ENV_FILE=.env
while [ $# -gt 0 ]; do
  case "$1" in
    --clasp) CLASP_FILE=${2:?--clasp needs a file}; shift 2 ;;
    --env) ENV_FILE=${2:?--env needs a file}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "deploy: unknown argument $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

[ -f "$CLASP_FILE" ] || { echo "deploy: $CLASP_FILE not found; create it with npm run setup-clasp" >&2; exit 1; }
SCRIPT_ID=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).scriptId || "")' "$CLASP_FILE")
[ -n "$SCRIPT_ID" ] || { echo "deploy: $CLASP_FILE has no scriptId" >&2; exit 1; }

STAGE=.build/$(basename "$CLASP_FILE" .json | sed 's/^\.//')
FILES=(appsscript/appsscript.json appsscript/Sorter.js appsscript/Rankings.js appsscript/WebApp.js)
CLASP="$PWD/node_modules/.bin/clasp"

rm -rf "$STAGE" && mkdir -p "$STAGE"
printf '{"scriptId": "%s"}\n' "$SCRIPT_ID" > "$STAGE/.clasp.json"
cp "${FILES[@]}" "$STAGE/"

(cd "$STAGE" && "$CLASP" push --force)

DEP_ID=$(grep -E '^DEPLOYMENT_ID=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -n "$DEP_ID" ]; then
  (cd "$STAGE" && "$CLASP" redeploy "$DEP_ID" -d "$(date '+%Y-%m-%d %H:%M:%S')")
  NEW=
else
  OUT=$(cd "$STAGE" && "$CLASP" deploy -d "web app")
  echo "$OUT"
  DEP_ID=$(echo "$OUT" | grep -oE 'AKfycb[A-Za-z0-9_-]+' | head -1)
  [ -n "$DEP_ID" ] || { echo "deploy: could not parse the deployment id" >&2; exit 1; }
  NEW=1
fi

# Replaces the keys' lines in the env file (or appends them), keeping everything else; a new file is private (0600)
# like the one gen-token writes, since it also holds TOKEN.
node - "$ENV_FILE" "DEPLOYMENT_ID=$DEP_ID" "WEB_APP_URL=https://script.google.com/macros/s/$DEP_ID/exec" <<'EOF'
const fs = require('fs');
const [file, ...pairs] = process.argv.slice(2);
let text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
for (const pair of pairs) {
  const key = pair.slice(0, pair.indexOf('='));
  const re = new RegExp(`^${key}=.*$`, 'gm');
  if (re.test(text)) text = text.replace(re, pair);
  else text += (text && !text.endsWith('\n') ? '\n' : '') + pair + '\n';
}
fs.writeFileSync(file, text, { mode: 0o600 });
EOF
echo "Wrote DEPLOYMENT_ID and WEB_APP_URL to $ENV_FILE"

if [ -n "$NEW" ]; then
  echo
  echo "New deployment. Open this URL once in a browser and approve the permission prompt:"
  echo "  https://script.google.com/macros/s/$DEP_ID/exec"
  echo 'Afterwards it shows {"ok":false,"error":"unauthorized"}, which means it works and just needs the token.'
fi

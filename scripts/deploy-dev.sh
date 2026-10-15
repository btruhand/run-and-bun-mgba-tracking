#!/usr/bin/env bash
# Pushes the Apps Script files to the DEV copy of the sheet only and (re)deploys the web app; DEPLOYMENT_ID and
# WEB_APP_URL are read from and written to .env.dev. Never touches the script in .clasp.json. See deploy.sh.
exec "$(dirname "$0")/deploy.sh" --clasp .clasp.dev.json --env .env.dev "$@"

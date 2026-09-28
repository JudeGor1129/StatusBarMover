#!/usr/bin/env bash
# Push StatusBarMover to GitHub using a Personal Access Token.
# The token is read from $GITHUB_TOKEN and NEVER printed.
#
#   REPO_NAME   repo to create/use   (default: StatusBarMover)
#   REPO_PRIV   "true" for private   (default: false)
set -e

: "${GITHUB_TOKEN:?GITHUB_TOKEN is not set}"
REPO_NAME="${REPO_NAME:-StatusBarMover}"
REPO_PRIV="${REPO_PRIV:-false}"
API="https://api.github.com"
AUTH="Authorization: token ${GITHUB_TOKEN}"

cd "$(dirname "$0")"

# 1. Who is the token owner?
LOGIN=$(curl -fsSL -H "$AUTH" "$API/user" | sed -n 's/.*"login" *: *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$LOGIN" ] || { echo "ERROR: could not read user from token (check scope: needs 'repo')"; exit 1; }
echo ">> GitHub user: $LOGIN"

# 2. Create the repo (ignore 'already exists').
echo ">> Creating repo $LOGIN/$REPO_NAME (private=$REPO_PRIV) ..."
CODE=$(curl -s -o /tmp/repo.json -w '%{http_code}' -H "$AUTH" \
  -d "{\"name\":\"$REPO_NAME\",\"private\":$REPO_PRIV,\"description\":\"Rootless jailbreak tweak to move each iOS 15 status bar icon (XinaA15).\"}" \
  "$API/user/repos")
if [ "$CODE" = "201" ]; then echo "   created."
elif grep -q "name already exists" /tmp/repo.json; then echo "   already exists, reusing."
else echo "   repo create returned HTTP $CODE:"; cat /tmp/repo.json; fi

# 3. Push. Token is embedded only in-memory for this push, not stored in config.
REMOTE="https://${LOGIN}:${GITHUB_TOKEN}@github.com/${LOGIN}/${REPO_NAME}.git"
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/${LOGIN}/${REPO_NAME}.git"
git branch -M main
echo ">> Pushing ..."
git push "$REMOTE" main --force

echo
echo ">> Done."
echo "   Repo:    https://github.com/${LOGIN}/${REPO_NAME}"
echo "   Actions: https://github.com/${LOGIN}/${REPO_NAME}/actions  (builds the .deb)"
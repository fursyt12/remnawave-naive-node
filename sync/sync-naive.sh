#!/bin/bash
LOCK="/tmp/sync-naive.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0
set -euo pipefail

: "${RW_API:?RW_API is not set}"
: "${RW_TOKEN:?RW_TOKEN is not set}"
: "${TLS_DOMAIN:?TLS_DOMAIN is not set}"
: "${SSH_HOST:?SSH_HOST is not set}"
: "${SSH_USER:?SSH_USER is not set}"
: "${SSH_KEY_PATH:?SSH_KEY_PATH is not set}"
: "${NODE_NAME:?NODE_NAME is not set}"

TLS_PORT="${TLS_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"
SSH_REMOTE_PATH="${SSH_REMOTE_PATH:-/home/${SSH_USER}/naive/}"
CADDY_ADMIN_URL="${CADDY_ADMIN_URL:-http://caddy:2019}"

STATE="/data/naive-users.json"
TMP_USERS="/tmp/rw-users.json"
ACTIVE_USERS="/tmp/active-users.json"
CADDY_USERS="/caddy-config/naive-users.caddy"
CADDY_TMP="/tmp/naive-users.caddy"
CADDYFILE="/caddy-config/Caddyfile"
LINKS_FILE="/data/${NODE_NAME}.txt"
LINKS_TMP="/tmp/${NODE_NAME}-naive-links.txt"

echo "[+] Download users"
curl -sf \
  -H "Authorization: Bearer ${RW_TOKEN}" \
  "${RW_API}/users?start=0&size=100" \
  -o "${TMP_USERS}"

COUNT=$(jq '.response.users | length' "${TMP_USERS}")
echo "Users received: ${COUNT}"

echo "[+] Filtering ACTIVE users in a naive squad"
jq '
.response.users
| map(select(
    .status == "ACTIVE"
    and ((.activeInternalSquads // []) | any((.name // "") | ascii_downcase | contains("naive")))
  ))
| map({username, id})
' "${TMP_USERS}" > "${ACTIVE_USERS}"

ACTIVE_COUNT=$(jq 'length' "${ACTIVE_USERS}")
echo "Active users in naive squads: ${ACTIVE_COUNT}"

echo "[+] Generating passwords"
mkdir -p "$(dirname "$STATE")"
[ -f "$STATE" ] || echo "{}" > "$STATE"

NEW_STATE=$(mktemp)
jq -n '{}' > "$NEW_STATE"

while read -r USER ID; do
    EXISTING=$(jq -r --arg id "$ID" '.[$id].password // empty' "$STATE")
    if [ -z "$EXISTING" ]; then
        PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
        echo "New user: $USER"
    else
        PASSWORD="$EXISTING"
    fi

    jq \
      --arg id "$ID" \
      --arg username "$USER" \
      --arg password "$PASSWORD" \
      '.[$id] = {username: $username, password: $password}' \
      "$NEW_STATE" > "${NEW_STATE}.tmp"
    mv "${NEW_STATE}.tmp" "$NEW_STATE"
done < <(jq -r '.[] | "\(.username) \(.id)"' "${ACTIVE_USERS}")

mv "$NEW_STATE" "$STATE"

echo "[+] Generating Caddy config"
{
    echo "# generated automatically"
    echo "# $(date)"
    jq -r '.[] | "basic_auth \(.username) \(.password)"' "$STATE"
} > "$CADDY_TMP"

echo "[+] Generating naive links"
{
    echo "# generated automatically"
    echo "# $(date)"
    echo
    jq -r \
      --arg domain "$TLS_DOMAIN" \
      --arg port "$TLS_PORT" '
    .[] | "\(.username) naive+https://\(.username):\(.password)@\($domain):\($port)"
    ' "$STATE"
} > "$LINKS_TMP"

mv "$LINKS_TMP" "$LINKS_FILE"

echo "[+] Uploading links file"
scp -P "${SSH_PORT}" -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=accept-new \
    "${LINKS_FILE}" "${SSH_USER}@${SSH_HOST}:${SSH_REMOTE_PATH}"

if ! cmp -s "$CADDY_TMP" "$CADDY_USERS" 2>/dev/null; then
    echo "[+] Config changed"
    mv "$CADDY_TMP" "$CADDY_USERS"
    echo "[+] Reloading Caddy via admin API"
    curl -sf -X POST "${CADDY_ADMIN_URL}/load" \
      -H "Content-Type: text/caddyfile" \
      --data-binary @"${CADDYFILE}"
    echo "[+] Caddy reloaded"
else
    echo "[+] No Caddy changes"
    rm -f "$CADDY_TMP"
fi

echo "[+] Done"

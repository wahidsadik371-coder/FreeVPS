#linux-run.sh — temp VM: web terminal (ttyd) via free ngrok HTTP tunnel
#!/bin/bash
# ngrok free allows HTTP endpoints without a card (TCP requires one).
# ttyd runs a bash terminal on :7681, ngrok exposes it over HTTPS.

set -u

if [[ -z "${GITHUB_TOKEN:-}" || -z "${REPO:-}" || -z "${LINUX_USER_PASSWORD:-}" ]]; then
  echo "required env missing (GITHUB_TOKEN/REPO/LINUX_USER_PASSWORD)"
  exit 2
fi

echo "### Install ttyd ###"
if ! command -v ttyd >/dev/null; then
  sudo apt-get install -y -qq ttyd 2>/dev/null || true
  if ! command -v ttyd >/dev/null; then
    curl -sL https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 -o ttyd
    chmod +x ttyd && sudo mv ttyd /usr/local/bin/ttyd
  fi
fi
command -v ttyd >/dev/null || { echo "ttyd install failed"; exit 3; }

# The Ubuntu ttyd package auto-starts its own systemd service on :7681 that
# serves a system login prompt. Disable it so OUR ttyd (auth + direct bash
# shell) owns the port.
sudo systemctl disable --now ttyd >/dev/null 2>&1 || true
sudo pkill -f "ttyd .*login" 2>/dev/null || true

echo "### Install ngrok v3 ###"
wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
tar xzf ngrok-v3-stable-linux-amd64.tgz
chmod +x ./ngrok
[[ -x ./ngrok ]] || { echo "ngrok install failed"; exit 4; }

echo "### Start web terminal (ttyd) ###"
nohup ttyd -W -c "jarvis:${LINUX_USER_PASSWORD}" bash >/tmp/ttyd.log 2>&1 &
sleep 2
# Our ttyd enforces basic auth, so an unauthenticated request MUST return 401.
# A 200 means some other server still owns the port (e.g. the packaged service).
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7681 || echo 000)
if [[ "$HTTP_CODE" != "401" ]]; then
  echo "expected 401 from our auth-protected ttyd, got $HTTP_CODE"
  cat /tmp/ttyd.log
  exit 5
fi

echo "### Start ngrok HTTP tunnel ###"
./ngrok authtoken "${NGROK_AUTH_TOKEN:-}"
nohup ./ngrok http 7681 --log .ngrok.log >/dev/null 2>&1 &
sleep 10

PUBLIC_URL=""
for i in $(seq 1 10); do
  PUBLIC_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url // empty' 2>/dev/null)
  [[ "$PUBLIC_URL" == https://* ]] && break
  sleep 5
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "no ngrok public url"
  tail -5 .ngrok.log 2>/dev/null
  exit 6
fi

echo ""
echo "=========================================="
echo "Web terminal: $PUBLIC_URL"
echo "Login: jarvis / \$LINUX_USER_PASSWORD"
echo "=========================================="

echo "::notice title=Temp VM ready::Web terminal $PUBLIC_URL (login jarvis)"
{
  echo "## Temp VM — web terminal"
  echo ""
  echo '```'
  echo "$PUBLIC_URL"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

PAYLOAD=$(jq -n --arg c "$(printf '%s' "$PUBLIC_URL" | base64 -w0)" '{message: "vm web terminal url", content: $c}')
SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$REPO/contents/tunnel.txt" | jq -r '.sha // empty')
if [[ -n "$SHA" ]]; then
  PAYLOAD=$(echo "$PAYLOAD" | jq --arg s "$SHA" '. + {sha: $s}')
fi
PUT_OK=""
for i in 1 2 3; do
  RESP=$(curl -s -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/$REPO/contents/tunnel.txt")
  echo "tunnel.txt PUT attempt $i: $(echo "$RESP" | head -c 200)"
  if echo "$RESP" | jq -e '.content.path' >/dev/null 2>&1; then PUT_OK=1; break; fi
  sleep 5
done
[[ -n "$PUT_OK" ]] || { echo "FAILED to publish tunnel.txt"; exit 7; }

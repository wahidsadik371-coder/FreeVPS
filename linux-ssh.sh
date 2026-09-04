#linux-run.sh — temp VM via tmate (no account, no card, no ngrok)
#!/bin/bash
# Publishes the tmate SSH line to tunnel.txt in the repo via GITHUB_TOKEN

set -u

if [[ -z "${GITHUB_TOKEN:-}" || -z "${REPO:-}" ]]; then
  echo "GITHUB_TOKEN/REPO env missing"
  exit 2
fi

echo "### Install tmate ###"
sudo apt-get update -qq
sudo apt-get install -y -qq tmate
command -v tmate >/dev/null || { echo "tmate install failed"; exit 3; }

echo "### Start tmate session ###"
tmate -S /tmp/tmate.sock new-session -d
tmate -S /tmp/tmate.sock wait tmate-ready 2>/dev/null || true

echo "### tmate messages ###"
tmate -S /tmp/tmate.sock show-messages

SSH_LINE=""
for i in $(seq 1 12); do
  SSH_LINE=$(tmate -S /tmp/tmate.sock show-messages | grep "ssh session:" | awk '{print $3}' | head -1)
  [[ -n "$SSH_LINE" ]] && break
  sleep 5
done
WEB_LINE=$(tmate -S /tmp/tmate.sock show-messages | grep "web session:" | awk '{print $3}' | head -1)

if [[ -z "$SSH_LINE" ]]; then
  echo "no tmate ssh line found"
  tmate show-messages
  exit 5
fi

echo ""
echo "=========================================="
echo "To connect: tmate show-messages said: $SSH_LINE"
echo "Web terminal: $WEB_LINE"
echo "=========================================="

echo "::notice title=Temp VM ready::ssh $SSH_LINE"
{
  echo "## Temp VM connection"
  echo ""
  echo '```'
  echo "ssh $SSH_LINE"
  echo "Web terminal: $WEB_LINE"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

SSH_CMD="ssh $SSH_LINE"
PAYLOAD=$(jq -n --arg c "$(printf '%s | web: %s' "$SSH_CMD" "${WEB_LINE:-none}" | base64 -w0)" '{message: "vm address", content: $c}')
SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$REPO/contents/tunnel.txt" | jq -r '.sha // empty')
if [[ -n "$SHA" ]]; then
  PAYLOAD=$(echo "$PAYLOAD" | jq --arg s "$SHA" '. + {sha: $s}')
fi
curl -s -X PUT \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "$PAYLOAD" \
  "https://api.github.com/repos/$REPO/contents/tunnel.txt" | jq -r '.content.path // .message'

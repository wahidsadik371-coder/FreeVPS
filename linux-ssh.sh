#linux-run.sh LINUX_USER_PASSWORD NGROK_AUTH_TOKEN LINUX_USERNAME LINUX_MACHINE_NAME
#!/bin/bash
# /home/runner/.ngrok2/ngrok.yml

sudo useradd -m $LINUX_USERNAME
sudo adduser $LINUX_USERNAME sudo
echo "$LINUX_USERNAME:$LINUX_USER_PASSWORD" | sudo chpasswd
sed -i 's/\/bin\/sh/\/bin\/bash/g' /etc/passwd
sudo hostname $LINUX_MACHINE_NAME

if [[ -z "$NGROK_AUTH_TOKEN" ]]; then
  echo "Please set 'NGROK_AUTH_TOKEN'"
  exit 2
fi

if [[ -z "$LINUX_USER_PASSWORD" ]]; then
  echo "Please set 'LINUX_USER_PASSWORD' for user: $USER"
  exit 3
fi

echo "### Install ngrok ###"

wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
tar xzf ngrok-v3-stable-linux-amd64.tgz
chmod +x ./ngrok
[[ -x ./ngrok ]] || { echo "ngrok download/install failed"; exit 6; }

echo "### Update user: $USER password ###"
echo -e "$LINUX_USER_PASSWORD\n$LINUX_USER_PASSWORD" | sudo passwd "$USER"

echo "### Start ngrok proxy for 22 port ###"


rm -f .ngrok.log
./ngrok authtoken "$NGROK_AUTH_TOKEN"
./ngrok tcp 22 --log ".ngrok.log" &

sleep 15

# Read the tunnel address from ngrok's local agent API (reliable, no log parsing)
ADDR=$(curl -s http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url // empty')
if [[ -z "$ADDR" || "$ADDR" != tcp://* ]]; then
  echo "ngrok agent API returned no tcp tunnel: '$ADDR'"
  cat .ngrok.log | tail -20
  exit 5
fi
SSH_HOST="${ADDR#tcp://}"; SSH_HOST="${SSH_HOST%%:*}"
SSH_PORT="${ADDR##*:}"

echo ""
echo "=========================================="
echo "To connect: ssh $LINUX_USERNAME@$SSH_HOST -p $SSH_PORT"
echo "=========================================="

# Visible while run is in progress
echo "::notice title=Temp VM ready::ssh $LINUX_USERNAME@$SSH_HOST -p $SSH_PORT"
{
  echo "## Temp VM connection"
  echo ""
  echo '```'
  echo "ssh $LINUX_USERNAME@$SSH_HOST -p $SSH_PORT"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

# Publish the address as a file in the repo so it is readable via API immediately
PAYLOAD=$(jq -n --arg c "$(printf 'ssh %s@%s -p %s' "$LINUX_USERNAME" "$SSH_HOST" "$SSH_PORT" | base64 -w0)" '{message: "vm address", content: $c}')
SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$REPO/contents/tunnel.txt" | jq -r '.sha // empty')
if [[ -n "$SHA" ]]; then
  PAYLOAD=$(echo "$PAYLOAD" | jq --arg s "$SHA" '. + {sha: $s}')
fi
curl -s -X PUT \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "$PAYLOAD" \
  "https://api.github.com/repos/$REPO/contents/tunnel.txt" | jq -r '.content.path // .message'

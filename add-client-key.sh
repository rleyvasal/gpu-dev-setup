#!/bin/bash
# add-client-key.sh - Add a new client's SSH public key

KEY=$1
USER_HOME=$2  # Optional, defaults to current user

if [ -z "$KEY" ]; then
    echo "Usage: $1 'ssh-ed25519 AAAAC3Nza... user@host'"
    exit 1
fi

HOME_DIR=${USER_HOME:-$HOME}
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"

mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

# Check if key already exists
if grep -qxF "$KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "Key already exists"
    exit 0
fi

echo "$KEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
echo "✅ Key added for $(echo $KEY | awk '{print $3}')"


#!/usr/bin/env bash
# Creates the EC2 SSH key pair if it does not exist; never overwrites an existing key.
set -euo pipefail

KEY="${1:-$HOME/.ssh/monitoring-poc-ed25519}"

if [[ -e "$KEY" || -e "$KEY.pub" ]]; then
  echo "Key $KEY already exists; leaving it untouched."
else
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -t ed25519 -N "" -C "monitoring-poc" -f "$KEY"
fi

echo "Public key: $KEY.pub"

#!/bin/bash
# vps-rsync.sh — rsync wrapper ke VPS tujuan via Tailscale (lewat proxy
# egress yang sama dengan vps-ssh.sh).
#
# Override: SSH_KEY, KNOWN_HOSTS, PROXY_HELPER. Default: kunci dan known
# hosts di ~/.ssh, helper di direktori script ini.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/tailscale-vps}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts_tailscale}"
PROXY_HELPER="${PROXY_HELPER:-$SCRIPT_DIR/proxy-ssh-helper.py}"
exec rsync -avz --perms \
  -e "ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -i $SSH_KEY -o ProxyCommand='$PROXY_HELPER %h %p'" \
  "$@"

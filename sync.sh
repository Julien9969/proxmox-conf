#!/bin/bash
set -e
REPO=/root/pve-config/pve
dirs=("firewall" "lxc" "mapping" "qemu-server")

mkdir -p "$REPO"

for d in "${dirs[@]}"; do
  mkdir -p "$REPO/$d"
  rsync -a --delete "/etc/pve/$d/" "$REPO/$d/" 2>/dev/null || true
done

rsync -a /etc/pve/*.cfg "$REPO/" 2>/dev/null || true
rsync -a /etc/network/interfaces "$REPO/network-interfaces"

cd "$REPO"
git add -A
git diff --cached --quiet || git commit -m "Auto snapshot $(date -Iseconds)" && git push

# Proxmox Config Backup

Tracks Proxmox cluster filesystem config (`/etc/pve`) in git via periodic rsync snapshots,
since `/etc/pve` is a FUSE-backed pmxcfs mount and shouldn't be git'd directly.

## Layout

- `pve/` — mirrored copy of `/etc/pve` (config snapshot, git-tracked)
- `sync.sh` — rsyncs `/etc/pve` into `pve/` and commits any changes
- `pve-config-git.service` — systemd unit that runs `sync.sh`
- `pve-config-git.timer` — systemd timer that triggers the service on a schedule

## Installation

1. Clone or place this repo at `/root/pve-config`:
```bash
   git clone <your-remote-url> /root/pve-config
   cd /root/pve-config
```
   (Or `git init` here if starting fresh.)

2. Make the sync script executable:
```bash
   chmod +x sync.sh
```

3. Install the systemd units:
```bash
   cp pve-config-git.service /etc/systemd/system/
   cp pve-config-git.timer /etc/systemd/system/
   systemctl daemon-reload
```

4. Enable and start the timer:
```bash
   systemctl enable --now pve-config-git.timer
```

5. Verify:
```bash
   systemctl list-timers pve-config-git.timer
   systemctl status pve-config-git.service
```

## Manual run

```bash
./sync.sh
```

## Notes

- `pve/` is overwritten (with `--delete`) on every sync, so it always mirrors
  the current state of `/etc/pve`. History lives in git commits, not on disk.
- Only versions config — not VM/LXC disk data. Use vzdump / Proxmox Backup Server for that.

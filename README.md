# setup_ipfs

One interactive script that turns a fresh Debian, Ubuntu or Raspberry Pi OS
install into a production-ready [IPFS](https://ipfs.tech) node running
[Kubo](https://github.com/ipfs/kubo) in Docker, with its files backed up to a
NAS.

```bash
curl -fsSL https://raw.githubusercontent.com/StrungSafe/setup_ipfs/main/setup.sh | sudo bash
```

Pipe it to `bash`, not `sh`. The questions still work when the script is
piped in, because they are read from the terminal.

To see what it would change first:

```bash
curl -fsSL https://raw.githubusercontent.com/StrungSafe/setup_ipfs/main/setup.sh | sudo bash -s -- --dry-run
```

## What it does

1. **Docker**: installs Docker Engine and the compose plugin from Docker's
   official apt repository (skipped if already installed).
2. **NAS mount**: mounts an SMB/CIFS share through `/etc/fstab` with systemd
   automount, so it survives reboots and NAS outages. The SMB version
   defaults to 3.1.1. SMB 1.0 is available for older NAS devices, with a
   warning that it is insecure. The password is kept in
   `/etc/ipfs-setup/smb-credentials` (mode 600), never in fstab.
3. **IPFS node**: runs `ipfs/kubo` with Docker Compose in `/opt/ipfs`, using
   host networking. The repo stays on local disk in `/opt/ipfs/data`.
4. **Kubo settings**, re-applied every time the container starts:
   - API allowed origins and methods (CORS)
   - `Import.CidVersion` (default 1)
   - your router's dynamic DNS name added to `Addresses.AppendAnnounce`, so
     peers outside your home network can find you, plus UPnP, relays and
     hole punching
5. **Firewall** (ufw, or firewalld if it is already active):
   - SSH is allowed first, so you can't get locked out
   - `4001/tcp` and `4001/udp` (swarm) are open to everyone
   - `5001` (API), `8080` (gateway) and `5353/udp` (mDNS) are open to your
     LAN subnet only
6. **Import of an existing backup** (optional): if the backup folder on the
   NAS already has files, each top-level item is added to IPFS, pinned, and
   placed in MFS at `/<name>`, with the same structure and names as the
   backup. Hidden files are skipped unless you choose to include them.
7. **Scheduled backup**: a systemd timer (`ipfs-mfs-backup.timer`, default
   daily at 02:00) copies MFS to the NAS backup folder with rsync. The backup
   refuses to run if the NAS isn't mounted. Its log is
   `/var/log/ipfs_mfs_backup.log`, rotated weekly.

## What it asks

| Question | Default |
| --- | --- |
| SMB share, mount point, user, domain, password | mount point `/mnt/ipfs` |
| SMB version | `3.1.1` |
| Kubo image tag | latest release |
| Container restart policy | `unless-stopped` |
| Allowed origins | `http://<hostname>.local:5001`, localhost and the LAN IP |
| Allowed methods | `PUT,POST,GET` |
| CID version | `1` |
| Router DNS name to announce | none (you can use your current public IP instead) |
| LAN subnet for API/gateway | detected |
| Backup folder, schedule, mirror deletions | `backup`, `*-*-* 02:00:00`, no |
| Back up the node config and keys | no |
| Include hidden files when importing | no |
| If an imported item already exists in MFS | skip |

Answers are saved in `/etc/ipfs-setup/setup.conf` and become the defaults the
next time you run the script. The NAS password is saved only in the
credentials file.

## After setup

- **Forward port 4001 (TCP and UDP)** on your router to this machine, so
  peers outside your network can connect. Never forward 5001 or 8080. The
  API gives full control of the node.
- WebUI: `http://<this-machine>:5001/webui`

## Running it again

Running the script again is safe. It shows your saved answers as defaults
and only changes what you change. Other options:

```bash
# Only import the NAS backup folder into MFS (e.g. after restoring a NAS)
sudo bash setup.sh --import-backup

# Run without questions, using an answers file
sudo NAS_PASSWORD='...' bash setup.sh --config setup.conf
```

See [examples/setup.conf.example](examples/setup.conf.example) for every
setting.

## Files it manages

| Path | Purpose |
| --- | --- |
| `/opt/ipfs/docker-compose.yml` | Kubo container |
| `/opt/ipfs/init.d/001-ipfs-setup.sh` | Kubo settings, applied on each start |
| `/opt/ipfs/data` | IPFS repo |
| `/opt/ipfs/import` | temporary staging for the backup import (emptied afterwards) |
| `/etc/fstab` (marked block) | NAS mount; a timestamped backup of fstab is kept |
| `/etc/ipfs-setup/` | saved answers, SMB credentials, backup settings |
| `/usr/local/sbin/ipfs_mfs_backup.sh` | backup script |
| `/etc/systemd/system/ipfs-mfs-backup.{service,timer}` | backup schedule |
| `/etc/logrotate.d/ipfs_mfs_backup` | log rotation |

Useful commands:

```bash
systemctl list-timers ipfs-mfs-backup.timer   # next backup
sudo systemctl start ipfs-mfs-backup.service  # back up now
docker logs -f ipfs                           # node logs
docker exec ipfs ipfs id                      # peer ID and addresses
```

## Notes

- **Imported content may get new CIDs.** CIDs depend on the import settings.
  If the old node used CID v0 or different settings, the same files get new
  CIDs, and old links won't resolve to them.
- **The node's private key isn't backed up by default.** Turning on "back up
  the node config and keys" copies `config` and `keystore` to
  `<mount>/node-config`. Anyone who can read the share can then impersonate
  the node.
- **The backup copies MFS only.** Content pinned outside MFS is not included.

## Uninstall

```bash
sudo systemctl disable --now ipfs-mfs-backup.timer
sudo docker compose -p ipfs -f /opt/ipfs/docker-compose.yml down
sudo rm -f /etc/systemd/system/ipfs-mfs-backup.* /usr/local/sbin/ipfs_mfs_backup.sh /etc/logrotate.d/ipfs_mfs_backup
# Remove the "ipfs-setup" block from /etc/fstab, then:
sudo rm -rf /etc/ipfs-setup
# The repo in /opt/ipfs/data is left in place; delete it yourself if you no longer need it.
```

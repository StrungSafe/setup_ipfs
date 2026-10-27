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
2. **NAS check**: right after the NAS questions, it checks that the NAS
   answers on the SMB ports, then logs in with a test mount and writes a test
   file. If something is wrong it says what (unknown host, wrong password,
   missing share, read-only access, unsupported SMB version) and asks again
   for just that part. If the NAS rejects the SMB version, it finds one that
   works and offers it. It never switches to SMB 1.0 without asking. This
   installs `cifs-utils`, the only change made before you confirm the
   summary.
3. **NAS mount**: mounts an SMB/CIFS share through `/etc/fstab` with systemd
   automount, so it survives reboots and NAS outages. The SMB version
   defaults to 3.1.1. SMB 1.0 is available for older NAS devices, with a
   warning that it is insecure. The password is kept in
   `/etc/ipfs-setup/smb-credentials` (mode 600), never in fstab.
4. **IPFS node**: runs `ipfs/kubo` with Docker Compose in `/opt/ipfs`, using
   host networking. The repo stays on local disk in `/opt/ipfs/data`.
5. **Kubo settings**, re-applied every time the container starts:
   - API allowed origins and methods (CORS)
   - `Import.CidVersion` (default 1)
   - `Import.UnixFSChunker`, the chunk size for content added without its
     own: Kubo's default (256 KiB), 1 MiB, or a custom size. Files up to
     the chunk size are stored as one block. It applies to `ipfs add`, MFS
     writes and the backup import, but not to apps that send their own chunk
     size. Content already on the node is not re-chunked.
   - your router's dynamic DNS name added to `Addresses.AppendAnnounce`, so
     peers outside your home network can find you, plus UPnP, relays and
     hole punching
6. **Firewall** (ufw, or firewalld if it is already active):
   - SSH is allowed first, so you can't get locked out
   - `4001/tcp` and `4001/udp` (swarm) are open to everyone
   - `5001` (API), `8080` (gateway) and `5353/udp` (mDNS) are open to your
     LAN subnet only
7. **Import of an existing backup** (optional): if the backup folder on the
   NAS already has files, each top-level item is added to IPFS, pinned, and
   placed in MFS at `/<name>`, with the same structure and names as the
   backup. Hidden files are skipped unless you choose to include them.
8. **Scheduled backup**: a systemd timer (`ipfs-mfs-backup.timer`) copies
   MFS to the NAS backup folder with rsync. The backup refuses to run if the
   NAS isn't mounted. Its log is `/var/log/ipfs_mfs_backup.log`, rotated
   weekly. You pick the schedule from a menu, and it shows the next three
   run times before you confirm:

   | Choice | Then asks | Example |
   | --- | --- | --- |
   | Daily (default) | time | `02:00` or `2am` |
   | Every few hours | 1, 2, 3, 4, 6, 8 or 12 hours | `6` runs at 00:00, 06:00, 12:00, 18:00 |
   | Weekly | day(s) and time | `mon,thu` or `weekdays`, then `9:30pm` |
   | Monthly | day 1-28 and time | `1`, then `02:00` |
   | Custom | a systemd `OnCalendar` expression | `Sat *-*-* 03:15:00` |

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
| Chunk size for new files | 256 KiB (Kubo's default); also 1 MiB or custom, e.g. `512KiB`, `1.5MiB` (KB/MB are binary units; max 2,096,896 bytes) |
| Router DNS name to announce | none (you can use your current public IP instead) |
| LAN subnet for API/gateway | detected |
| Backup folder, schedule, mirror deletions | `backup`, daily at 02:00, no |
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

- **Imported files keep their CIDs only if the import settings match.** A
  file's CID depends on the chunk size, CID version and raw-leaves setting
  it was added with. If the backup import uses the same ones, files get
  their original CIDs back and old links keep working. Otherwise they get
  new CIDs. For example, with Kubo's default 256 KiB chunks, a 1 MB file is
  split into 4 blocks and gets a different CID than an app that stored it
  as one block.
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

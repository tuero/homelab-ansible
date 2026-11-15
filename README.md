# Homelab Ansible

This repository configures Ubuntu VMs that already exist in Proxmox. Proxmox, Cloud-Init, TrueNAS datasets/shares, DHCP/static addressing, and GPU PCI passthrough are external prerequisites.

## Managed Hosts

| Group | Inventory host | IP | Role |
| --- | --- | --- | --- |
| `gpu_servers` | `gpu-server` | `192.168.2.111` | CUDA development and JupyterLab |
| `infra_servers` | `infra` | `192.168.2.236` | Tailscale and AdGuard Home |
| `services_servers` | `services` | `192.168.2.113` | Docker services |

Cloud-Init creates user `tuero` and installs the controller's initial SSH key. Ansible manages configuration from that point.

Infra uses a static Cloud-Init address (`ip=192.168.2.236/24,gw=192.168.2.1`)
with NIC MAC `02:24:11:3C:91:94` and initial DNS `192.168.2.1`.
Keep static host addresses outside Bell's DHCP allocation range. After the
modem reset, the AdGuard role migrates its persisted listener configuration
from `192.168.2.212` to the new address. Switch modem DNS to `192.168.2.236` only after
both public and internal queries directly against AdGuard succeed. Configure
Tailscale split DNS for `tuerolab.ca` with nameserver `192.168.2.236`.

## Vault

The encrypted shared Vault is `group_vars/all/vault.yml`. Active roles require:

```yaml
vault_truenas_smb_password
vault_github_private_key
vault_github_public_key
vault_jupyter_password_hash
vault_adguard_password
vault_pia_username
vault_pia_password
vault_cloudflare_api_token
```

Create it only on a fresh checkout:

```bash
test ! -e group_vars/all/vault.yml \
  && cp group_vars/all/vault.yml.example group_vars/all/vault.yml \
  && ansible-vault encrypt group_vars/all/vault.yml
```

Edit an existing Vault with:

```bash
ansible-vault edit group_vars/all/vault.yml
```

## Normal Provisioning

`run.sh` installs the required Galaxy collections and asks for the Vault password:

```bash
./run.sh
./run.sh --limit gpu_servers
./run.sh --limit infra_servers
./run.sh --limit services_servers
```

The services role order is:

```text
truenas_mounts
service_appdata_restore   # recovery only; skipped by normal runs
docker
arr_stack
downloads_stack
reverse_proxy
monitoring_stack
service_backups
```

Tag-only runs assume their prerequisites already exist. Use a full host-group run for ordinary fresh provisioning.

### Plex

Plex is hosted on Ardougne, the services VM (`192.168.2.113`), in the
`arr_stack` Compose project, with `/mnt/media` mounted at
`/media` and persistent settings, library metadata, and watch history under
`/srv/docker/appdata/plex`. Its appdata is included in daily backups and
fresh-VM restore checks. `VERSION=docker` keeps updates tied to the pinned image.

Run all commands in this section on the Mac that runs Ansible, from
`~/Documents/homelab-ansible`. Ansible connects to the managed VMs over SSH;
the claim-token commands run locally on the Mac.

On an already provisioned homelab, update DNS and deploy the media images
before generating the short-lived first-run claim token:

```bash
./run.sh --limit infra_servers --tags adguard
./run.sh --limit services_servers --tags arr,proxy,monitoring,backups
```

For a new server, get a token from <https://plex.tv/claim>, then run within four
minutes (the prompt avoids putting the token in shell history):

```bash
printf 'Plex claim token: '
read -r -s PLEX_CLAIM; printf '\n'
export PLEX_CLAIM
./run.sh --limit services_servers --tags arr
unset PLEX_CLAIM
```

This block works in macOS's default Zsh and in Bash. Paste the token at the
prompt; input is hidden. Ansible writes it to a mode-`0600` `plex.env`
file and suppresses claim-related task output. Subsequent runs without the
environment variable clear the token; an already claimed or restored server
does not need another token.

Open `https://plex.tuerolab.ca/web` (direct access:
`http://192.168.2.113:32400/web`), sign in, and create libraries using paths such
as `/media/Movies`, `/media/TV Shows`, and `/media/Anime`. In Plex's advanced
**Settings > Network**, set **Custom server access URLs** to
`https://plex.tuerolab.ca:443` so clients can discover the proxy address.
Tautulli can connect directly to host `plex`, port `32400`, with SSL disabled
on the shared Docker network. Run and verify an appdata backup after setup.

When migrating an existing Plex installation, transfer its complete Plex Media
Server data directory while both instances are stopped, preserving the server
preferences and database. In this container it belongs under
`/srv/docker/appdata/plex/Library/Application Support/Plex Media Server`, owned
by the configured service user. Use a Plex version at least as new as the
source server. Restoring this data retains server identity, metadata, and watch
history; a claim token alone does not migrate them. Disable automatic trash
emptying before changing library paths to `/media/...`, then verify libraries,
playback, and Tautulli before retiring the source instance. Only one instance
using the migrated server identity should run at a time.

### Tautulli

Tautulli runs alongside Radarr and Sonarr in the `arr_stack` Compose project.
To add it to an already provisioned homelab, update DNS and deploy the service,
proxy, Homepage entry, and backup configuration:

```bash
./run.sh --limit infra_servers --tags adguard
./run.sh --limit services_servers --tags arr,proxy,monitoring,backups
```

Open `https://tautulli.tuerolab.ca` and complete the setup wizard to connect your
Plex account and server. Its Web UI also listens on the services VM's port `8181`.
Settings and history persist in `/srv/docker/appdata/tautulli` and are included
in the daily appdata backup and fresh-VM restore checks. After deployment, run
and verify a backup so the recoverable archive includes Tautulli.

## Docker Startup And Network Storage

The services VM prevents Docker from starting until every path in `docker_required_cifs_mounts` is mounted as CIFS and responds to a directory read.
This handles full-site restarts where the VM boots before TrueNAS is ready.
The check retries instead of relying on a fixed Proxmox startup delay.

The following containers require `/mnt/media`:

| Container | Storage use |
| --- | --- |
| Radarr | Movie library import and management |
| Sonarr | Series library import and management |
| Plex | Media library scanning and streaming |
| Bazarr | Media scanning and subtitle management |
| qBittorrent | Download storage |

Docker bind mounts use private propagation by default.
If one of these containers starts against a failed automount, mounting the share later on the host does not repair the container's mount.
Gating Docker avoids containers that appear healthy but cannot access `/media`.

The readiness service gates the Docker daemon, so all containers on the VM are postponed even if they do not use network storage.
When adding a container that uses the existing `/mnt/media` mount, no startup configuration change is needed, but add it to the dependency table above.
When adding a different required CIFS mount, add its absolute host path to `docker_required_cifs_mounts` in `group_vars/services_servers/vars.yml`.
A container without network-storage bind mounts needs no additional entry.

To diagnose startup waiting on the services VM:

```bash
systemctl status docker-storage-ready.service docker.service
journalctl -b -u docker-storage-ready.service
findmnt -n -t cifs --target /mnt/media
```

## Updating Pinned Software

Ansible converges each managed service to the version or image reference in its role variables.
Updating a pin does not happen automatically: review the release, update the listed variable, take a backup for stateful services, and run the scoped command.
The same command installs a fresh host or updates an existing one without deleting persistent application data.

| Software | Pin variable(s) | Command |
| --- | --- | --- |
| AdGuard Home | `adguardhome_version` in `roles/adguard/defaults/main.yml` | `./run.sh --limit infra_servers --tags adguard` |
| Tailscale | `tailscale_version` in `roles/tailscale/defaults/main.yml` | `./run.sh --limit infra_servers --tags tailscale` |
| Docker Engine and plugins | `docker_ce_version`, `docker_containerd_version`, `docker_buildx_version`, `docker_compose_version` in `roles/docker/defaults/main.yml` | `./run.sh --limit services_servers --tags docker` |
| Plex, Radarr, Sonarr, Tautulli, Bazarr, Prowlarr | `arr_images.<service>` in `roles/arr_stack/defaults/main.yml` | `./run.sh --limit services_servers --tags arr` |
| Gluetun and qBittorrent | `gluetun_image`, `qbittorrent_image` in `roles/downloads_stack/defaults/main.yml` | `./run.sh --limit services_servers --tags downloads` |
| Caddy and Cloudflare module | `caddy_version`, `caddy_cloudflare_module_version` in `roles/reverse_proxy/defaults/main.yml` | `./run.sh --limit services_servers --tags proxy` |
| Homepage and Uptime Kuma | `homepage_image`, `uptime_kuma_image` in `roles/monitoring_stack/defaults/main.yml` | `./run.sh --limit services_servers --tags monitoring` |
| LLVM and GCC | `llvm_version`, `gcc_version` in `group_vars/gpu_servers/vars.yml` | `./run.sh --limit gpu_servers --tags dev` |
| NVIDIA driver and CUDA toolkit | `nvidia_driver_package`, `cuda_toolkit_version`, `cuda_toolkit_package_version` in `group_vars/gpu_servers/vars.yml` | `./run.sh --limit gpu_servers --tags cuda` |
| JupyterLab environment | `jupyter_python_version`, `jupyterlab_version`, `jupyter_ipykernel_version` in `group_vars/gpu_servers/vars.yml` | `./run.sh --limit gpu_servers --tags jupyter` |

Docker references use a release tag and immutable digest.
Update both together after reviewing the upstream release.
The Compose roles pull the requested image and recreate only changed containers; bind-mounted appdata remains under `/srv/docker/appdata`.

### Finding Container Image Pins

For LinuxServer images, use its latest GitHub release to obtain the complete container tag, including the LinuxServer `-ls` revision.
Then query the image index digest through Docker on the services VM. Set `service` to `plex`, `radarr`, `sonarr`, `tautulli`, `bazarr`, `prowlarr`, or `qbittorrent`:

```bash
service=radarr
tag="$(curl -fsSL "https://api.github.com/repos/linuxserver/docker-${service}/releases/latest" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
digest="$(ssh tuero@192.168.2.113 \
  "docker buildx imagetools inspect --format '{{.Manifest.Digest}}' lscr.io/linuxserver/${service}:${tag}")"
printf 'lscr.io/linuxserver/%s:%s@%s\n' "$service" "$tag" "$digest"
```

For example, the command prints a complete value suitable for an Ansible variable:

```text
lscr.io/linuxserver/radarr:6.4.4.10685-ls318@sha256:adb6c09d6b729ea5e642c99cea35af72702ef476bf4763f153299ac5db9f0b4f
```

For non-LinuxServer images, first select and review a release tag from the upstream release page, then resolve that exact tag rather than `latest`:

| Variable | Image | Release source |
| --- | --- | --- |
| `gluetun_image` | `qmcgaw/gluetun` | `qdm12/gluetun` GitHub releases |
| `homepage_image` | `ghcr.io/gethomepage/homepage` | `gethomepage/homepage` GitHub releases |
| `uptime_kuma_image` | `louislam/uptime-kuma` | `louislam/uptime-kuma` GitHub releases |

```bash
image=qmcgaw/gluetun
tag=v3.41.3
digest="$(ssh tuero@192.168.2.113 \
  "docker buildx imagetools inspect --format '{{.Manifest.Digest}}' ${image}:${tag}")"
printf '%s:%s@%s\n' "$image" "$tag" "$digest"
```

The digest reported by `.Manifest.Digest` is the multi-platform image-index digest used by this repository.
Do not substitute one of the architecture or attestation digests shown by the unformatted `imagetools inspect` output.
After updating the corresponding role variable, take a backup and run the scoped command from the table above.

Before updating a stateful services-VM application, run and verify its backup:

```bash
ssh tuero@192.168.2.113 sudo systemctl start service-appdata-backup.service
ssh tuero@192.168.2.113 systemctl status service-appdata-backup.service
```

Verify the service version and health after deployment, then commit the updated pin.
Package repositories can eventually discard old versions, so retain a VM backup when changing host packages or drivers.

### Finding APT Package Pins

APT package versions are repository version strings, not release numbers.
Do not construct or increment them manually: copy a version reported by the configured repository.
Check the candidate and available versions before changing a pin:

```bash
apt-cache policy <package>
apt-cache madison <package>
```

For an LLVM major-version update, change `llvm_version` and run the development role.
The role configures the matching apt.llvm.org repository, then installs the current packages for that major:

```bash
./run.sh --limit gpu_servers --tags dev
```

Use the same approach for the exact pins in the update table:

```bash
# Infra VM
apt-cache policy tailscale

# Services VM
for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
  apt-cache policy "$package"
done

# GPU VM
apt-cache policy nvidia-driver-595-open cuda-toolkit-13-3
```

The LLVM major version is intentional; apt.llvm.org package build strings are not pinned because a new major's repository must be configured before APT can discover its candidate version.

The NVIDIA driver package fixes the driver branch (`nvidia-driver-595-open`) without pinning a patch version. OS upgrades can install newer patch releases within that branch, and the NVIDIA role accepts an already installed version rather than downgrading it. The role reboots when its driver installation changes or `/var/run/reboot-required` exists, including when run on its own with `--tags cuda`. The CUDA toolkit retains its exact package version pin.

## Project Workspace Sync

TrueNAS provides canonical, snapshot-protected project trees through the `projects` SMB share mounted at `/mnt/projects` on Varrock.
The local workspace is `~/projects`; build there rather than on SMB. Create the TrueNAS `projects` share before deploying its mount and helper commands:

```bash
./run.sh --limit gpu_servers --tags storage,projects
```

The commands are directional and preview by default.
Review the itemized `rsync` output, then repeat with `--apply` to make the destination match the source:

```bash
project-pull example-project
project-pull example-project --apply

project-push example-project
project-push example-project --apply
```

`.git` directories are synchronized. Generated build and cache paths are excluded through `project_sync_excludes` in `group_vars/gpu_servers/vars.yml`.
Symlinks are preserved through CIFS `mfsymlinks`.
A project-root `compile_commands.json` symlink is synchronized, while its generated target under an excluded build directory is not; the link remains dangling until the local build recreates its target.
The SMB transport does not preserve POSIX ownership or modes; see the GPU VM project-workspace documentation for Git executable-bit and symlink guidance.
When seeding `projects` from a TrueNAS root shell, recursively assign imported children to the `tuero` SMB user or reapply the dataset ACL recursively.
Dataset ownership does not change existing child ownership; root-owned imports can be readable but reject updates and `rsync` deletions from Varrock.

## Services Backup

The `service_backups` role creates a daily systemd timer.
It quiesces the managed Compose stacks, stages `/srv/docker/appdata`, then publishes one compressed archive to:

```text
/mnt/service-backups/ardougne/appdata/current/
├── appdata.tar.zst
├── appdata.tar.zst.sha256
├── manifest.yml
└── success.yml

/mnt/service-backups/ardougne/appdata/.last-success
```

The archive preserves Unix metadata internally. TrueNAS snapshots, not Ansible, provide historical retention.

Verify or run it manually on Ardougne:

```bash
timedatectl
systemctl list-timers service-appdata-backup.timer
sudo systemctl start service-appdata-backup.service
systemctl status service-appdata-backup.service
journalctl -u service-appdata-backup.service
```

## Recover a Fresh Services VM

The restore role is deliberately fresh-VM-only.
It refuses to run when `/srv/docker/appdata` contains data, Docker containers are running, or the published archive is incomplete.

1. Create/restore the Ubuntu VM in Proxmox and ensure its inventory address is reachable.
2. Install the common base and TrueNAS mounts:

```bash
./run.sh --limit services_servers --tags common,storage
```

3. Validate the restore preflight without changing appdata:

```bash
./run.sh \
  --limit services_servers \
  --tags restore \
  --check \
  -e service_restore_enabled=true \
  -e service_restore_confirmation=RESTORE_ardougne_TO_services
```

4. Restore the archive:

```bash
./run.sh \
  --limit services_servers \
  --tags restore \
  -e service_restore_enabled=true \
  -e service_restore_confirmation=RESTORE_ardougne_TO_services
```

5. Recreate Docker, Compose files, generated secrets, and services:

```bash
./run.sh --limit services_servers --tags docker,arr,downloads,proxy,monitoring
```

6. Validate applications, media access, Gluetun, qBittorrent forwarding, and Caddy.
Enable backups only after validation:

```bash
./run.sh --limit services_servers --tags backups
```

Do not use this restore path to repair a running services VM. Restore a Proxmox VM backup, or perform a separate, deliberate in-place recovery procedure.

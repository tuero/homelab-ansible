# Homelab Ansible

This repository configures Ubuntu VMs that already exist in Proxmox. Proxmox, Cloud-Init, TrueNAS datasets/shares, DHCP/static addressing, and GPU PCI passthrough are external prerequisites.

## Managed Hosts

| Group | Inventory host | IP | Role |
| --- | --- | --- | --- |
| `gpu_servers` | `gpu-server` | `10.0.0.111` | CUDA development and JupyterLab |
| `infra_servers` | `infra` | `10.0.0.112` | Tailscale and AdGuard Home |
| `services_servers` | `services` | `10.0.0.113` | Docker services |

Cloud-Init creates user `tuero` and installs the controller's initial SSH key. Ansible manages configuration from that point.

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

## Updating Pinned Software

Ansible converges each managed service to the version or image reference in its
role variables. Updating a pin does not happen automatically: review the
release, update the listed variable, take a backup for stateful services, and
run the scoped command. The same command installs a fresh host or updates an
existing one without deleting persistent application data.

| Software | Pin variable(s) | Command |
| --- | --- | --- |
| AdGuard Home | `adguardhome_version` in `roles/adguard/defaults/main.yml` | `./run.sh --limit infra_servers --tags adguard` |
| Tailscale | `tailscale_version` in `roles/tailscale/defaults/main.yml` | `./run.sh --limit infra_servers --tags tailscale` |
| Docker Engine and plugins | `docker_ce_version`, `docker_containerd_version`, `docker_buildx_version`, `docker_compose_version` in `roles/docker/defaults/main.yml` | `./run.sh --limit services_servers --tags docker` |
| Radarr, Sonarr, Bazarr, Prowlarr | `arr_images.<service>` in `roles/arr_stack/defaults/main.yml` | `./run.sh --limit services_servers --tags arr` |
| Gluetun and qBittorrent | `gluetun_image`, `qbittorrent_image` in `roles/downloads_stack/defaults/main.yml` | `./run.sh --limit services_servers --tags downloads` |
| Caddy and Cloudflare module | `caddy_version`, `caddy_cloudflare_module_version` in `roles/reverse_proxy/defaults/main.yml` | `./run.sh --limit services_servers --tags proxy` |
| Homepage and Uptime Kuma | `homepage_image`, `uptime_kuma_image` in `roles/monitoring_stack/defaults/main.yml` | `./run.sh --limit services_servers --tags monitoring` |
| LLVM and GCC | `llvm_version`, `llvm_package_version`, `gcc_version` in `group_vars/gpu_servers/vars.yml` | `./run.sh --limit gpu_servers --tags dev` |
| NVIDIA driver and CUDA toolkit | `nvidia_driver_package`, `cuda_toolkit_version`, `cuda_toolkit_package_version` in `group_vars/gpu_servers/vars.yml` | `./run.sh --limit gpu_servers --tags cuda` |
| JupyterLab environment | `jupyter_python_version`, `jupyterlab_version`, `jupyter_ipykernel_version` in `group_vars/gpu_servers/vars.yml` | `./run.sh --limit gpu_servers --tags jupyter` |

Docker references use a release tag and immutable digest. Update both together
after reviewing the upstream release. The Compose roles pull the requested
image and recreate only changed containers; bind-mounted appdata remains under
`/srv/docker/appdata`.

Before updating a stateful services-VM application, run and verify its backup:

```bash
ssh tuero@10.0.0.113 sudo systemctl start service-appdata-backup.service
ssh tuero@10.0.0.113 systemctl status service-appdata-backup.service
```

Verify the service version and health after deployment, then commit the updated
pin. Package repositories can eventually discard old versions, so retain a VM
backup when changing host packages or drivers.

### Finding APT Package Pins

APT package versions are repository version strings, not release numbers. Do
not construct or increment them manually: copy a version reported by the
configured repository. Check the candidate and available versions before
changing a pin:

```bash
apt-cache policy <package>
apt-cache madison <package>
```

For an LLVM major-version update, change `llvm_version`, then query that major
and copy the full candidate value into `llvm_package_version`:

```bash
apt-cache policy clang-23

for package in clang-23 clang-format-23 clangd-23 clang-tidy-23; do
  apt-cache policy "$package"
done
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

The package version must be available for every package that shares that pin.
For example, all four LLVM packages use `llvm_package_version`; select a value
listed for all four, rather than editing its timestamp or suffix by hand.

## Project Workspace Sync

TrueNAS provides canonical, snapshot-protected project trees through the
`projects` SMB share mounted at `/mnt/projects` on Varrock. The local workspace
is `~/projects`; build there rather than on SMB. Create the TrueNAS `projects`
share before deploying its mount and helper commands:

```bash
./run.sh --limit gpu_servers --tags storage,projects
```

The commands are directional and preview by default. Review the itemized
`rsync` output, then repeat with `--apply` to make the destination match the
source:

```bash
project-pull example-project
project-pull example-project --apply

project-push example-project
project-push example-project --apply
```

`.git` directories are synchronized. Generated build and cache paths are
excluded through `project_sync_excludes` in `group_vars/gpu_servers/vars.yml`.
Symlinks are preserved through CIFS `mfsymlinks`. A project-root
`compile_commands.json` symlink is synchronized, while its generated target
under an excluded build directory is not; the link remains dangling until the
local build recreates its target.
The SMB transport does not preserve POSIX ownership or modes; see the GPU VM
project-workspace documentation for Git executable-bit and symlink guidance.
When seeding `projects` from a TrueNAS root shell, recursively assign imported
children to the `tuero` SMB user or reapply the dataset ACL recursively. Dataset
ownership does not change existing child ownership; root-owned imports can be
readable but reject updates and `rsync` deletions from Varrock.

## Services Backup

The `service_backups` role creates a daily systemd timer. It quiesces the managed Compose stacks, stages `/srv/docker/appdata`, then publishes one compressed archive to:

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

The restore role is deliberately fresh-VM-only. It refuses to run when `/srv/docker/appdata` contains data, Docker containers are running, or the published archive is incomplete.

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

6. Validate applications, media access, Gluetun, qBittorrent forwarding, and Caddy. Enable backups only after validation:

```bash
./run.sh --limit services_servers --tags backups
```

Do not use this restore path to repair a running services VM. Restore a Proxmox VM backup, or perform a separate, deliberate in-place recovery procedure.

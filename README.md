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

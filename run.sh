#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "ansible-playbook is not installed on this controller."
    echo "On Ubuntu/WSL: sudo apt update && sudo apt install -y ansible"
    exit 1
fi

ansible-galaxy collection install -r requirements.yml

if [[ ! -f group_vars/all/vault.yml ]]; then
    echo "Missing encrypted group_vars/all/vault.yml"
    echo
    echo "Create it with:"
    echo "  cp group_vars/all/vault.yml.example group_vars/all/vault.yml"
    echo "  nano group_vars/all/vault.yml"
    echo "  ansible-vault encrypt group_vars/all/vault.yml"
    exit 1
fi

# One entry point for the whole homelab. Because the shared Vault lives under
# group_vars/all, Ansible will ask for the Vault password on each run.
ansible-playbook site.yml --ask-vault-pass "$@"

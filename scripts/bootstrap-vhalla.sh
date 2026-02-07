#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
USERNAME="vhalla"
TZ="America/Sao_Paulo"

SSH_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCQdIu9xbyLG0hbrbl9FW8FWYt1TjDUgW8wAnLqXnDvGJKwQDe97uK7szuf+bwB8WmujlxplQ3GAm9czxZFSLE1BsBZL9wDRYpyse4l3d8Ig/RGT5Xd7sDpSjTXkOu+2taOWL/1msw6NRlu3VazPURpdOOdab62VHNsVlk9CswnPAtaM/xrqT5sd+uw52q2B2uW00diqsyVSdDYUX1QtRdtqU8fcbN3wqQ8Nfwx2pyR+GtmBNcTjqN9beY2CA6QA5TheOTfmPGBliYyw6IBDIFXIRtA4psN21dCX7AWIisHZqIkZLLk1ARc2OZzRHn35/Ml+b65DopDNzH/xCNJtMrr The Parker Servers The Parker'
# ==================

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este script precisa rodar como root. Use: sudo bash <(curl -fsSL URL)"
    exit 1
  fi
}

apt_update_upgrade() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get autoremove -y
}

set_timezone() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "${TZ}"
  else
    echo "${TZ}" > /etc/timezone
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  fi
}

ensure_user() {
  if id "${USERNAME}" >/dev/null 2>&1; then
    echo "Usuário ${USERNAME} já existe."
  else
    useradd -m -s /bin/bash "${USERNAME}"
    echo "Usuário ${USERNAME} criado."
  fi
}

ensure_groups() {
  # sudo
  if getent group sudo >/dev/null; then
    usermod -aG sudo "${USERNAME}"
  fi

  # docker (somente se existir)
  if getent group docker >/dev/null; then
    usermod -aG docker "${USERNAME}"
  else
    echo "Grupo docker não existe (ok). Se instalar Docker depois, rode novamente."
  fi
}

ensure_ssh_key() {
  local home_dir
  home_dir="$(getent passwd "${USERNAME}" | cut -d: -f6)"
  local ssh_dir="${home_dir}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${ssh_dir}"
  touch "${auth_keys}"
  chown "${USERNAME}:${USERNAME}" "${auth_keys}"
  chmod 600 "${auth_keys}"

  # adiciona a chave apenas se ainda não existir (idempotente)
  if ! grep -Fqx "${SSH_KEY}" "${auth_keys}"; then
    echo "${SSH_KEY}" >> "${auth_keys}"
    echo "Chave SSH adicionada em ${auth_keys}"
  else
    echo "Chave SSH já está presente em ${auth_keys}"
  fi
}

main() {
  require_root
  apt_update_upgrade
  set_timezone
  ensure_user
  ensure_groups
  ensure_ssh_key

  echo
  echo "OK ✅"
  echo "- Timezone: ${TZ}"
  echo "- Usuário: ${USERNAME}"
  echo "- Grupos do usuário: $(id -nG "${USERNAME}" || true)"
}

main "$@"

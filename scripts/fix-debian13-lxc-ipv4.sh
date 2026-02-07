#!/usr/bin/env bash
# fix-debian13-lxc-ipv4.sh
# Debian 13 (trixie) LXC on Proxmox: ensure IPv4 via DHCP survives networking restarts.
#
# Usage (inside the container, as root):
#   curl -fsSL https://SEU_SITE/fix-debian13-lxc-ipv4.sh | bash
#
set -euo pipefail

log() { printf "\n[fix] %s\n" "$*"; }
die() { printf "\n[fix][ERROR] %s\n" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Execute como root."

IFACE="${IFACE:-eth0}"

RESOLV="/etc/resolv.conf"
RESOLV_BAK="/etc/resolv.conf.vhalla.bak.$(date +%Y%m%d%H%M%S)"
INTERFACES="/etc/network/interfaces"
INTERFACES_BAK="/etc/network/interfaces.vhalla.bak.$(date +%Y%m%d%H%M%S)"
HOOK_DIR="/etc/network/if-up.d"
HOOK="$HOOK_DIR/dhclient4"

TEMP_DNS_IPV6_1="${TEMP_DNS_IPV6_1:-2606:4700:4700::1111}" # Cloudflare
TEMP_DNS_IPV6_2="${TEMP_DNS_IPV6_2:-2001:4860:4860::8888}" # Google

# --- Helpers to safely change and restore resolv.conf ---
is_resolv_symlink() { [ -L "$RESOLV" ]; }
backup_resolv() {
  log "Backup do DNS: $RESOLV -> $RESOLV_BAK"
  cp -a "$RESOLV" "$RESOLV_BAK" 2>/dev/null || true
  if is_resolv_symlink; then
    log "resolv.conf é symlink; preservando também o alvo."
    readlink -f "$RESOLV" > "${RESOLV_BAK}.symlink_target" || true
  fi
}

set_temp_ipv6_dns() {
  log "Aplicando DNS IPv6 temporário (para conseguir baixar pacotes sem IPv4)..."
  if is_resolv_symlink; then
    # In LXC this is usually safe; overwrite the link target by replacing the file.
    # We'll restore later from backup.
    rm -f "$RESOLV"
  fi
  cat > "$RESOLV" <<EOF
# Temporário (script fix-debian13-lxc-ipv4)
nameserver $TEMP_DNS_IPV6_1
nameserver $TEMP_DNS_IPV6_2
options timeout:1 attempts:3
EOF
}

restore_dns() {
  log "Restaurando DNS original..."
  if [ -f "$RESOLV_BAK" ]; then
    rm -f "$RESOLV"
    cp -a "$RESOLV_BAK" "$RESOLV"
    log "DNS restaurado a partir de: $RESOLV_BAK"
  else
    log "Backup de resolv.conf não encontrado; mantendo configuração atual."
  fi
}

# --- Networking config ---
backup_interfaces() {
  log "Backup de interfaces: $INTERFACES -> $INTERFACES_BAK"
  cp -a "$INTERFACES" "$INTERFACES_BAK" 2>/dev/null || true
}

write_interfaces() {
  log "Configurando $INTERFACES (ifupdown) para LXC..."
  cat > "$INTERFACES" <<EOF
auto lo
iface lo inet loopback

allow-hotplug $IFACE
iface $IFACE inet dhcp

iface $IFACE inet6 auto
EOF
}

install_dhcp_client() {
  log "Atualizando índices do APT..."
  apt-get update -y

  log "Instalando isc-dhcp-client..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y isc-dhcp-client
}

write_hook() {
  log "Criando hook $HOOK para garantir DHCPv4 ao subir interface..."
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK" <<'EOF'
#!/bin/sh
# Ensure IPv4 DHCP is requested on LXC Debian 13 when interface comes up.
set -eu

IFACE_EXPECTED="${IFACE_EXPECTED:-eth0}"

[ "${IFACE:-}" = "$IFACE_EXPECTED" ] || exit 0

# If dhclient is already running, keep it. Otherwise request IPv4 in background.
if command -v dhclient >/dev/null 2>&1; then
  # -nw = no wait; do not block boot
  dhclient -4 -nw "$IFACE_EXPECTED" >/dev/null 2>&1 || true
fi
EOF
  chmod +x "$HOOK"
}

restart_networking() {
  log "Reiniciando rede (systemd networking.service)..."
  # Debian containers sometimes have systemd, sometimes not; handle both.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart networking || true
  fi

  # Also try ifup/ifdown to be safe in LXC
  if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
    ifdown "$IFACE" 2>/dev/null || true
    ifup "$IFACE" 2>/dev/null || true
  fi

  # Finally, ensure an IPv4 lease is requested right now
  if command -v dhclient >/dev/null 2>&1; then
    dhclient -4 -nw "$IFACE" >/dev/null 2>&1 || true
  fi
}

show_status() {
  log "Status da interface ($IFACE):"
  ip a show "$IFACE" || true

  log "Rotas:"
  ip route || true

  log "DNS atual:"
  cat /etc/resolv.conf || true
}

main() {
  log "Iniciando correção Debian 13 LXC (IPv4 DHCP persistente) na interface: $IFACE"

  backup_resolv
  set_temp_ipv6_dns

  backup_interfaces
  write_interfaces

  install_dhcp_client
  write_hook

  restart_networking

  # Restore original DNS at the end
  restore_dns

  show_status

  log "Concluído. Se quiser validar reboot:"
  log "  reboot"
}

main "$@"

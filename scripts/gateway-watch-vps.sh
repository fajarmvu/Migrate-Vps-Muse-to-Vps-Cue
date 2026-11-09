#!/bin/bash
# gateway-watch-vps.sh — watchdog deterministik untuk hermes-gateway-vps
# di Muse By Cue (menggantikan penilaian manual tiap run).
#
# Aturan Fajar (2026-10-08): "nek 5 menit gk jalan yo restart en ae"
#
# Dua lapis cek via SSH:
#   1. hermes-gateway-vps.service harus `active` -> kalau tidak, restart.
#   2. MainPID gateway harus memegang >=1 koneksi TCP ESTABLISHED ke :443
#      (IP API Telegram, mis. 149.154.166.110). Polling mode yang sehat
#      selalu memegang koneksi long-poll persisten. Kalau 0, cek ulang
#      setelah 60 detik; kalau masih 0 -> polling stall -> restart.
#
# Verifikasi restart: "Connected to Telegram (polling mode)" muncul di
# journal dalam 90 detik setelah restart.
#
# Exit 0 = sehat / tidak ada aksi. Exit 1 = restart dilakukan.
# Exit 2 = restart gagal / tidak bisa verifikasi (butuh manusia).
# Exit 3 = SSH ke VPS tidak terjangkau — status gateway UNKNOWN
#          (inconclusive), bukan "service mati". Jangan alert sebagai
#          kegagalan gateway; jalur keepalive SSH sudah menangani notifikasi
#          link-down secara terpisah.
#
# Override: SERVICE (nama unit gateway), VPS_SSH (wrapper SSH),
# GATEWAY_WATCH_LOG (file log). Default: pakai lokasi script ini.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_SSH="${VPS_SSH:-$SCRIPT_DIR/vps-ssh.sh}"
SERVICE="${SERVICE:-hermes-gateway-vps}"
LOG="${GATEWAY_WATCH_LOG:-$SCRIPT_DIR/gateway-watch-vps.log}"

# Proxy creds: this cron worker's runtime env carries an HTTPS_PROXY whose
# credentials the Tailscale relay (port 3130) rejects -> every probe fails and
# the gateway goes effectively unwatched (exit 3 since 2026-10-09). Prefer the
# stored, auto-rotated file (same one the tg-link-monitor unit loads), which
# handles both "HTTPS_PROXY=<url>" and bare-URL formats.
_PF="$HOME/.config/vps-ssh-proxy-env"
if [ -f "$_PF" ]; then
  _PV=$(grep -m1 '^HTTPS_PROXY=' "$_PF" | cut -d= -f2- | sed "s/^['\"]//;s/['\"]\$//")
  [ -z "$_PV" ] && _PV=$(grep -m1 -E '^[^#= ]*://' "$_PF" | sed 's/#.*//;s/^ *//;s/ *$//')
  [ -n "$_PV" ] && export HTTPS_PROXY="$_PV"
fi
unset _PF _PV

log() { echo "[$(date '+%F %H:%M:%S %Z')] $*" >> "$LOG"; }
say() { echo "$*"; log "$*"; }

vps() { timeout 30 bash "$VPS_SSH" "$1" 2>/dev/null; }

# ---- cek 0: SSH terjangkau? (bedakan "link mati" dari "service mati") ----
probe=$(vps "echo VPS-OK")
if [ "$probe" != "VPS-OK" ]; then
  say "INCONCLUSIVE: SSH ke Muse By Cue tidak terjangkau (probe='$probe') — status gateway UNKNOWN, bukan restart"
  exit 3
fi

tg_conns() {
  # NB: nang output ss, ":443" (remote) muncul SAKDURUNGE "pid=" (users),
  # dadi pola kudu :443 dhisik baru pid.
  vps 'GPID=$(systemctl show '"$SERVICE"' -p MainPID | cut -d= -f2); ss -tnp state established 2>/dev/null | grep -c ":443 .*pid=${GPID}\([^0-9]\|$\)"'
}

do_restart() { # $1 = alasan
  local reason="$1"
  say "RESTART: $reason"
  vps "systemctl restart $SERVICE" >/dev/null
  local ok=0
  for _ in $(seq 1 18); do
    sleep 5
    if vps "journalctl -u $SERVICE --since '2 minutes ago' --no-pager 2>/dev/null" | grep -q "Connected to Telegram (polling mode)"; then
      ok=1; break
    fi
  done
  if [ "$ok" = "1" ]; then
    say "RESTART OK: gateway reconnected to Telegram ($reason)"
    return 1
  fi
  say "RESTART GAGAL: no reconnect within 90s ($reason) — butuh manusia"
  return 2
}

# ---- cek 1: service aktif? ----
active=$(vps "systemctl is-active $SERVICE")
if [ "$active" != "active" ]; then
  do_restart "service not active (is-active=$active)"
  exit $?
fi

# ---- cek 2: koneksi Telegram hidup? ----
c1=$(tg_conns); c1=${c1:-0}
if [ "$c1" -gt 0 ] 2>/dev/null; then
  echo "OK: $c1 telegram connection(s), service active"
  exit 0
fi
sleep 60
c2=$(tg_conns); c2=${c2:-0}
if [ "$c2" -gt 0 ] 2>/dev/null; then
  echo "OK: recovered ($c2 telegram connection(s))"
  exit 0
fi
do_restart "0 telegram connections selama 60+d detik (polling stall)"
exit $?

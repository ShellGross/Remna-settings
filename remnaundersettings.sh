#!/usr/bin/env bash
#
# remnaundersettings.sh — надстройка над install_remnawave.sh (eGamesAPI)
#
# При первом запуске кладёт себя в /usr/local/bin и создаёт ярлык `srus`,
# после чего вызывается из любого каталога командой srus.
#
# Запускать ПОСЛЕ того, как скрипт eGames поставил ноду.
#
#   1. sysctl-тюнинг под автоопределённый профиль железа (+ RPS/RFS, conntrack)
#   2. UFW: открыть порт xHTTP, спрятать NODE_PORT за IP панели
#   3. Найти сертификаты SelfSteal, смонтировать в remnanode, повесить хук на продление
#   4. Собрать xHTTP+TLS инбаунд с рандомным path, проверить через xray -test, залить в панель
#   5. Постфлайт: логи ядра, порт, TLS-рукопожатие снаружи
#   6. Откат профиля из бэкапа одной командой
#
# Без аргументов — интерактивное меню. С флагами — неинтерактивный прогон.
#
set -uo pipefail

VERSION="3.3.0"
SELF_NAME="remnaundersettings.sh"
SELF_PATH="/usr/local/bin/$SELF_NAME"
SHORTCUT="/usr/local/bin/srus"
CONF="/etc/remna-node-kit.conf"
LOG="/var/log/remna-node-kit.log"
BACKUP_DIR="/var/backups/remna-node-kit"
SYSCTL_CONF="/etc/sysctl.d/99-xray-tuning.conf"
COMPOSE_DIR="/opt/remnanode"
CONTAINER_CERT_DIR="/etc/ssl/node"
CERT_STAMP="/var/lib/remna-node-kit/cert.stamp"

# ---------------------------------------------------------------- вывод ----

# ${#строка} считает байты, если локаль не UTF-8 — кириллица ломает вёрстку.
# C.UTF-8 есть в glibc на Ubuntu 22.04+, для остальных ниже деградация.
if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then export LC_ALL=en_US.UTF-8
fi
UTF_OK=0; _probe="ЯЯ"; (( ${#_probe} == 2 )) && UTF_OK=1

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_R=$'\033[0;31m';  C_G=$'\033[0;32m';  C_Y=$'\033[0;33m'
  C_B=$'\033[0;36m';  C_M=$'\033[0;35m';  C_BL=$'\033[0;34m'
  C_W=$'\033[1;37m';  C_GR=$'\033[0;90m'; C_D=$'\033[2m'
  C_BD=$'\033[1m';    C_N=$'\033[0m'
  C_RB=$'\033[1;31m'; C_GB=$'\033[1;32m'; C_YB=$'\033[1;33m'; C_BB=$'\033[1;36m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_M=""; C_BL=""; C_W=""; C_GR=""
  C_D=""; C_BD=""; C_N=""; C_RB=""; C_GB=""; C_YB=""; C_BB=""
fi

BOX_W=46

# Ширина строки в символах. printf %-Ns выравнивает по байтам, поэтому
# добиваем пробелами сами — пробел всегда однобайтовый.
pad() {
  local s="$1" w="$2" n
  if (( UTF_OK )); then n=$(( w - ${#s} )); else n=$(( w - ${#s} )); fi
  (( n < 0 )) && n=0
  printf '%s%*s' "$s" "$n" ""
}

rep() { local ch="$1" n="$2" i out=""; for ((i=0;i<n;i++)); do out+="$ch"; done; printf '%s' "$out"; }

box_top()  { printf '%s╭%s╮%s\n' "$C_GR" "$(rep '─' $((BOX_W-2)))" "$C_N"; }
box_bot()  { printf '%s╰%s╯%s\n' "$C_GR" "$(rep '─' $((BOX_W-2)))" "$C_N"; }
box_sep()  { printf '%s├%s┤%s\n' "$C_GR" "$(rep '─' $((BOX_W-2)))" "$C_N"; }
box_row()  { printf '%s│%s %s %s│%s\n' "$C_GR" "$C_N" "$(pad "$1" $((BOX_W-4)))" "$C_GR" "$C_N"; }

# Строка в рамке, где текст уже содержит цветовые коды: ширину считаем
# по «чистому» варианту, переданному вторым аргументом.
box_rowc() {
  local colored="$1" plain="$2"
  local n=$(( BOX_W - 4 - ${#plain} ))
  (( n < 0 )) && n=0
  printf '%s│%s %s%*s %s│%s\n' "$C_GR" "$C_N" "$colored" "$n" "" "$C_GR" "$C_N"
}

section() { printf '\n  %s%s%s\n' "$C_BD$C_BL" "$1" "$C_N"; }

item() {  # item <клавиша> <название> <подсказка>
  printf '   %s%s%s  %s%s%s  %s%s%s\n' \
    "$C_BB" "$(pad "$1" 2)" "$C_N" \
    "$C_W" "$(pad "$2" 16)" "$C_N" \
    "$C_GR" "$3" "$C_N"
}

dot() {  # dot <есть?> <текст> — зелёная точка или серая
  if [[ -n "$2" && "$2" != "—" ]]; then printf '%s●%s %s' "$C_G" "$C_N" "$2"
  else printf '%s○%s %s' "$C_GR" "$C_N" "${3:-не задано}"; fi
}

_tolog() {
  [[ -w "$(dirname "$LOG")" ]] || return 0
  # в лог без цветовых кодов, иначе grep по нему бесполезен
  printf '%s %s\n' "$(date '+%F %T')" "$(sed 's/\x1b\[[0-9;]*m//g' <<<"$1")" >>"$LOG" 2>/dev/null || true
}

log()  { printf '  %s▸%s %s\n' "$C_BB" "$C_N" "$*"; _tolog "[*] $*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GB" "$C_N" "$*"; _tolog "[+] $*"; }
warn() { printf '  %s!%s %s\n' "$C_YB" "$C_N" "$*" >&2; _tolog "[!] $*"; }
err()  { printf '  %s✗%s %s\n' "$C_RB" "$C_N" "$*" >&2; _tolog "[x] $*"; }
die()  { err "$*"; exit 1; }
dim()  { printf '    %s%s%s\n' "$C_GR" "$*" "$C_N"; }
hr()   { printf '  %s%s%s\n' "$C_GR" "$(rep '─' $((BOX_W-2)))" "$C_N"; }

# ------------------------------------------------------------ параметры ----

DOMAIN=""; XHTTP_PORT=""; XHTTP_PATH=""; INBOUND_TAG=""
PANEL_URL=""; PANEL_TOKEN=""; PANEL_COOKIE=""; PANEL_API_KEY=""; PANEL_IP=""
PROFILE_NAME=""; NODE_NAME=""; SQUAD_NAME=""; HOST_REMARK=""
TUNE_PROFILE=""; API_SCOPE=""; CERT_DIR=""
XHTTP_MODE=""; XHTTP_ALPN=""; PATH_STYLE=""; POST_BYTES=""; ROUTE_ONLY=""
LAST_PROFILE_UUID=""; ALL_INBOUNDS=""
DRY_RUN=0; ASSUME_YES=0; SKIP_VALIDATE=0; EXPERT=0; NO_INSTALL=0; ACTIONS=()

DEFAULT_PORT="8445"

CERT_HOST_DIR=""; CERT_FILE=""; KEY_FILE=""; MOUNT_SRC=""; MOUNT_DST=""
CERT_IN_CONTAINER=""; KEY_IN_CONTAINER=""

# ------------------------------------------------------------- утилиты -----

need_root() { [[ $EUID -eq 0 ]] || die "Нужен root."; }

confirm() {
  (( ASSUME_YES )) && return 0
  local a; read -r -p "$1 [y/N]: " a </dev/tty
  [[ "$a" =~ ^[yYдД]$ ]]
}

ask() {
  local prompt="$1" default="${2:-}" a
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " a </dev/tty; printf '%s' "${a:-$default}"
  else
    read -r -p "$prompt: " a </dev/tty; printf '%s' "$a"
  fi
}

# ask_valid <prompt> <default> <validator-fn> <подсказка при ошибке>
# Спрашивает, пока не введут корректное. Значение — в stdout, всё остальное — в stderr.
ask_valid() {
  local prompt="$1" default="$2" vfn="$3" hint="$4" v
  while :; do
    v=$(ask "$prompt" "$default")
    if "$vfn" "$v"; then printf '%s' "$v"; return 0; fi
    printf '  %s%s%s\n' "$C_Y" "$hint" "$C_N" >&2
  done
}

# choose <prompt> <default-номер> <метка1> <значение1> <метка2> <значение2> …
choose() {
  local prompt="$1" def="$2"; shift 2
  local -a labels=() values=()
  while (( $# >= 2 )); do labels+=("$1"); values+=("$2"); shift 2; done
  local n=${#labels[@]}

  { printf '\n  %s%s%s\n' "$C_BD$C_BL" "$prompt" "$C_N"; local i
    for (( i=0; i<n; i++ )); do
      if (( i+1 == def )); then
        printf '   %s%s%s  %s%s%s %s←%s\n' "$C_BB" "$(pad "$((i+1))" 2)" "$C_N" \
          "$C_W" "${labels[$i]}" "$C_N" "$C_GR" "$C_N"
      else
        printf '   %s%s%s  %s\n' "$C_BB" "$(pad "$((i+1))" 2)" "$C_N" "${labels[$i]}"
      fi
    done; echo
  } >&2

  if (( ASSUME_YES )); then printf '%s' "${values[$((def-1))]}"; return 0; fi
  local c
  while :; do
    c=$(ask "  номер" "$def")
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )) && break
    echo "  Введи число 1..$n" >&2
  done
  printf '%s' "${values[$((c-1))]}"
}

ensure_deps() {
  local miss=()
  for b in jq curl openssl; do command -v "$b" >/dev/null 2>&1 || miss+=("$b"); done
  (( ${#miss[@]} == 0 )) && return 0
  log "Ставлю недостающее: ${miss[*]}"
  apt-get update -qq && apt-get install -y -qq "${miss[@]}" || die "Не смог поставить: ${miss[*]}"
}

load_conf() { [[ -f "$CONF" ]] && . "$CONF"; return 0; }

save_conf() {
  umask 077
  cat >"$CONF" <<EOF
# remna-node-kit — сохранённые параметры. chmod 600, внутри токен.
DOMAIN="$DOMAIN"
XHTTP_PORT="$XHTTP_PORT"
XHTTP_PATH="$XHTTP_PATH"
INBOUND_TAG="$INBOUND_TAG"
PANEL_URL="$PANEL_URL"
PANEL_TOKEN="$PANEL_TOKEN"
PANEL_COOKIE="$PANEL_COOKIE"
PANEL_API_KEY="$PANEL_API_KEY"
PANEL_IP="$PANEL_IP"
PROFILE_NAME="$PROFILE_NAME"
NODE_NAME="$NODE_NAME"
SQUAD_NAME="$SQUAD_NAME"
CERT_DIR="$CERT_DIR"
XHTTP_MODE="$XHTTP_MODE"
XHTTP_ALPN="$XHTTP_ALPN"
POST_BYTES="$POST_BYTES"
ROUTE_ONLY="$ROUTE_ONLY"
HOST_REMARK="$HOST_REMARK"
LAST_PROFILE_UUID="$LAST_PROFILE_UUID"
EOF
  chmod 600 "$CONF"
}

ram_mb()    { awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo; }
cpu_cores() { nproc; }
cpu_model() { awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo; }
swap_mb()   { awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo; }

NODE_CT=""
# Имя контейнера не всегда remnanode — ищем по образу
find_node_container() {
  [[ -n "$NODE_CT" ]] && { printf '%s' "$NODE_CT"; return 0; }
  local c
  c=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
      | awk -F'\t' '$2 ~ /remnawave\/node/ {print $1; exit}')
  [[ -z "$c" ]] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -E 'remnanode|remnawave-node')
  [[ -z "$c" ]] && return 1
  NODE_CT="$c"; printf '%s' "$c"
}
have_node_container() { find_node_container >/dev/null 2>&1; }

# ======================================================================
#  1. ТЮНИНГ ХОСТА
# ======================================================================
#
#  Три профиля под реальное железо нод:
#
#   base  — 1 сильное ядро / 2 GB   (типа Ryzen 9950X, 1 vCPU)
#   dual  — 2 слабых ядра / 2 GB    (+ RPS/RFS, иначе одно ядро упирается в softirq)
#   tiny  — 1 ядро / 1 GB           (буферы вдвое меньше, conntrack урезан, своп критичен)
#
# ======================================================================

detect_tune_profile() {
  local ram cores; ram=$(ram_mb); cores=$(cpu_cores)
  if   (( ram < 1536 ));  then echo "tiny"
  elif (( cores >= 2 ));  then echo "dual"
  else                         echo "base"
  fi
}

describe_profile() {
  case "$1" in
    base) echo "1 сильное ядро / 2 GB — базовые буферы, без RPS" ;;
    dual) echo "2 слабых ядра / 2 GB — базовые буферы + RPS/RFS" ;;
    tiny) echo "1 ядро / 1 GB — буферы вдвое меньше, conntrack 65k" ;;
    *)    echo "неизвестный" ;;
  esac
}

set_kv() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_CONF" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$SYSCTL_CONF"
  else
    echo "${key} = ${val}" >>"$SYSCTL_CONF"
  fi
}

do_tune() {
  need_root
  local auto; auto=$(detect_tune_profile)
  local prof="${TUNE_PROFILE:-}"

  if [[ -z "$prof" || "$prof" == "auto" ]]; then
    if (( ASSUME_YES )); then
      prof="$auto"
    else
      hr
      echo "Железо: $(cpu_model)" >&2
      echo "        $(cpu_cores) ядер · $(ram_mb) MB RAM · своп $(swap_mb) MB" >&2
      prof=$(choose "Профиль тюнинга (автоопределение: $auto)" \
        "$(case "$auto" in base) echo 1 ;; dual) echo 2 ;; tiny) echo 3 ;; *) echo 1 ;; esac)" \
        "base — 1 сильное ядро / 2 GB, буферы 16M, conntrack 262k" base \
        "dual — 2 слабых ядра / 2 GB, то же + RPS/RFS" dual \
        "tiny — 1 ядро / 1 GB, буферы 8M, conntrack 65k" tiny)
    fi
  fi

  hr
  log "Железо: $(cpu_model)"
  log "        $(cpu_cores) ядер · $(ram_mb) MB RAM · своп $(swap_mb) MB"
  log "Профиль: ${C_Y}${prof}${C_N} — $(describe_profile "$prof")"
  [[ "$prof" != "$auto" ]] && warn "Задан вручную, автоопределение дало '$auto'"
  hr

  if (( DRY_RUN )); then dim "dry-run: не пишу в $SYSCTL_CONF"; return 0; fi

  touch "$SYSCTL_CONF"
  cp -a "$SYSCTL_CONF" "$SYSCTL_CONF.bak.$(date +%s)" 2>/dev/null || true

  # ---- общее для всех профилей: rate новых соединений, TIME_WAIT, keepalive
  set_kv net.core.somaxconn 65535
  set_kv net.core.netdev_max_backlog 16384
  set_kv net.ipv4.tcp_max_syn_backlog 8192
  set_kv net.ipv4.tcp_syncookies 1
  set_kv net.ipv4.tcp_timestamps 1          # без него tcp_tw_reuse молча не работает
  set_kv net.ipv4.tcp_tw_reuse 1
  set_kv net.ipv4.tcp_fin_timeout 15
  set_kv net.ipv4.tcp_keepalive_time 300
  set_kv net.ipv4.tcp_keepalive_probes 5
  set_kv net.ipv4.tcp_keepalive_intvl 15
  set_kv net.ipv4.tcp_max_tw_buckets 262144
  set_kv net.ipv4.ip_local_port_range "10240 65535"
  set_kv net.ipv4.tcp_slow_start_after_idle 0
  set_kv net.ipv4.tcp_mtu_probing 1
  set_kv net.ipv4.tcp_fastopen 3
  set_kv net.ipv4.tcp_notsent_lowat 16384
  set_kv net.ipv4.tcp_abort_on_overflow 0
  set_kv fs.file-max 1048576
  set_kv fs.nr_open 1048576

  # ---- буферы и conntrack по профилю
  case "$prof" in
    tiny)
      set_kv net.core.rmem_max 8388608
      set_kv net.core.wmem_max 8388608
      set_kv net.core.rmem_default 262144
      set_kv net.core.wmem_default 262144
      set_kv net.ipv4.tcp_rmem "4096 87380 8388608"
      set_kv net.ipv4.tcp_wmem "4096 32768 8388608"
      set_kv net.ipv4.tcp_max_orphans 8192
      set_kv net.netfilter.nf_conntrack_max 65536
      set_kv vm.min_free_kbytes 32768
      set_kv vm.swappiness 30
      ;;
    *)
      set_kv net.core.rmem_max 16777216
      set_kv net.core.wmem_max 16777216
      set_kv net.core.rmem_default 524288
      set_kv net.core.wmem_default 524288
      set_kv net.ipv4.tcp_rmem "4096 87380 16777216"
      set_kv net.ipv4.tcp_wmem "4096 65536 16777216"
      set_kv net.ipv4.tcp_max_orphans 32768
      set_kv net.netfilter.nf_conntrack_max 262144
      set_kv vm.min_free_kbytes 65536
      set_kv vm.swappiness 10
      ;;
  esac
  set_kv net.netfilter.nf_conntrack_tcp_timeout_established 3600
  set_kv net.netfilter.nf_conntrack_tcp_timeout_time_wait 30

  # conntrack сам не грузится — после ребута sysctl тихо проглотит несуществующие ключи
  echo "nf_conntrack" >/etc/modules-load.d/nf_conntrack.conf
  modprobe nf_conntrack 2>/dev/null || warn "modprobe nf_conntrack не прошёл"

  # BBR: eGames его уже ставит. Трогаем, только если там что-то другое.
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  if [[ "$cc" != "bbr" ]]; then
    warn "congestion control = '$cc', ставлю bbr"
    set_kv net.core.default_qdisc fq
    set_kv net.ipv4.tcp_congestion_control bbr
  else
    dim "BBR уже включён скриптом eGames — не трогаю"
  fi

  sysctl --system >/dev/null 2>&1 && ok "sysctl применён" || warn "sysctl --system завершился с ошибками"

  [[ "$prof" == "dual" ]] && install_rps_unit

  # своп на маленьких нодах — без него OOM-killer выберет именно Xray
  if [[ "$prof" == "tiny" ]] && (( $(swap_mb) < 256 )); then
    hr
    warn "Свопа нет, а RAM $(ram_mb) MB."
    dim "Под пиком OOM-killer убьёт Xray раньше всего остального."
    dim "Если решишь добавить:"
    dim "  fallocate -l 1G /swapfile && chmod 600 /swapfile"
    dim "  mkswap /swapfile && swapon /swapfile"
    dim "  echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi

  hr
  sysctl -a 2>/dev/null | grep -E 'tcp_tw_reuse|somaxconn|tcp_timestamps|congestion_control|conntrack_max' || true
  ok "Тюнинг завершён (профиль $prof)"
}

install_rps_unit() {
  local mask cores; cores=$(cpu_cores)
  mask=$(printf '%x' $(( (1 << cores) - 1 )))

  cat >/usr/local/sbin/xray-rps.sh <<EOF
#!/bin/sh
# Раскидывает softirq по ядрам. Значения в /sys не переживают ребут.
for q in /sys/class/net/*/queues/rx-*/rps_cpus; do
  [ -w "\$q" ] && echo $mask > "\$q" 2>/dev/null
done
for q in /sys/class/net/*/queues/rx-*/rps_flow_cnt; do
  [ -w "\$q" ] && echo 4096 > "\$q" 2>/dev/null
done
[ -w /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
exit 0
EOF
  chmod +x /usr/local/sbin/xray-rps.sh

  cat >/etc/systemd/system/xray-rps.service <<'EOF'
[Unit]
Description=RPS/RFS tuning for Xray node
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xray-rps.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xray-rps.service >/dev/null 2>&1 \
    && ok "RPS/RFS включён (маска $mask, ядер $cores)" || warn "xray-rps.service не поднялся"
}

# ======================================================================
#  2. ФАЕРВОЛ
# ======================================================================

node_port() {
  local p=""
  [[ -f "$COMPOSE_DIR/.env" ]] && p=$(grep -oP '^APP_PORT=\K.*' "$COMPOSE_DIR/.env" 2>/dev/null | tr -d '"' | head -1)
  [[ -z "$p" ]] && p=$(grep -oP '^NODE_PORT=\K.*' "$COMPOSE_DIR/.env" 2>/dev/null | tr -d '"' | head -1)
  echo "${p:-2222}"
}

# Панель уже стучится на NODE_PORT — её IP видно в установленных соединениях
detect_panel_ip() {
  local np="$1" ip=""
  command -v ss >/dev/null 2>&1 || return 1
  ip=$(ss -tnH state established "sport = :$np" 2>/dev/null \
       | awk '{print $4}' | sed 's/:[0-9]*$//' | sed 's/^\[//;s/\]$//' \
       | grep -vE '^(127\.|::1)' | sort -u | head -1)
  [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
  return 1
}

do_firewall() {
  need_root
  command -v ufw >/dev/null 2>&1 || { err "ufw не найден — eGames обычно его ставит."; return 1; }

  local np; np=$(node_port)
  log "Фаервол: xHTTP $XHTTP_PORT/tcp, NODE_PORT $np"

  if [[ -z "$PANEL_IP" ]]; then
    local guess
    if guess=$(detect_panel_ip "$np"); then
      ok "Нашёл активное подключение к NODE_PORT с $guess"
      PANEL_IP=$(ask "IP панели" "$guess")
    else
      dim "Активных подключений к NODE_PORT нет — панель может быть просто не опрашивает сейчас"
      PANEL_IP=$(ask "IP панели (пусто = не трогать NODE_PORT)" "")
    fi
  fi

  if (( DRY_RUN )); then
    dim "dry-run: ufw allow ${XHTTP_PORT}/tcp"
    [[ -n "$PANEL_IP" ]] && dim "dry-run: ufw allow from ${PANEL_IP} to any port ${np} proto tcp"
    return 0
  fi

  ufw allow "${XHTTP_PORT}/tcp" comment 'xhttp inbound' >/dev/null 2>&1 \
    && ok "Открыт ${XHTTP_PORT}/tcp" || warn "не смог открыть ${XHTTP_PORT}/tcp"

  if [[ -n "$PANEL_IP" ]]; then
    ufw allow from "$PANEL_IP" to any port "$np" proto tcp comment 'remnawave panel' >/dev/null 2>&1 \
      && ok "NODE_PORT $np открыт только для $PANEL_IP" || warn "правило для NODE_PORT не прошло"

    # снять сквозной allow, если eGames открыл порт всем
    local guard=0
    while (( guard++ < 10 )) && ufw status numbered | grep -qE "\[[ 0-9]+\] ${np}(/tcp)?[[:space:]]+ALLOW IN[[:space:]]+Anywhere"; do
      local n
      n=$(ufw status numbered | grep -E "\[[ 0-9]+\] ${np}(/tcp)?[[:space:]]+ALLOW IN[[:space:]]+Anywhere" \
          | head -1 | grep -oP '\[\s*\K[0-9]+')
      [[ -z "$n" ]] && break
      yes | ufw delete "$n" >/dev/null 2>&1 && ok "Убрал открытый всем NODE_PORT (правило #$n)" || break
    done
  else
    warn "IP панели не задан — NODE_PORT остаётся как есть"
  fi

  ufw reload >/dev/null 2>&1
  hr; ufw status verbose | head -30
}

# ======================================================================
#  3. СЕРТИФИКАТЫ
# ======================================================================

find_certs_all() {
  local d="$1" base found
  base=$(echo "$d" | awk -F. '{ if (NF>2) print $(NF-1)"."$NF; else print $0 }')

  local cands=(
    "/etc/letsencrypt/live/$d" "/etc/letsencrypt/live/$base"
    "$COMPOSE_DIR/$d" "$COMPOSE_DIR/certs/$d" "/opt/remnawave/certs/$d"
  )
  for c in "${cands[@]}"; do
    [[ -f "$c/fullchain.pem" && -f "$c/privkey.pem" ]] && printf '%s|fullchain.pem|privkey.pem\n' "$c"
  done

  # Caddy кладёт .crt/.key вместо fullchain/privkey
  while IFS= read -r found; do
    [[ -n "$found" && -f "${found%.crt}.key" ]] && \
      printf '%s|%s|%s\n' "$(dirname "$found")" "$(basename "$found")" "$(basename "${found%.crt}.key")"
  done < <(find /var/lib/caddy "$COMPOSE_DIR" /opt/remnawave -type f -name "${d}.crt" 2>/dev/null)
}

resolve_certs() {
  [[ -n "$DOMAIN" ]] || DOMAIN=$(ask_valid "SelfSteal-домен ноды" "" validate_domain \
      "Похоже на домен: node.example.com")
  [[ -n "$DOMAIN" ]] || { err "Без домена дальше никак."; return 1; }

  local res
  if [[ -n "$CERT_DIR" ]]; then
    [[ -f "$CERT_DIR/fullchain.pem" ]] || { err "В $CERT_DIR нет fullchain.pem"; return 1; }
    res="$CERT_DIR|fullchain.pem|privkey.pem"
  else
    local -a found=()
    mapfile -t found < <(find_certs_all "$DOMAIN")
    if (( ${#found[@]} == 0 )); then
      err "Сертификаты для $DOMAIN не нашёл."
      dim "Искал в /etc/letsencrypt/live, $COMPOSE_DIR, /var/lib/caddy."
      dim "Задай явно: --cert-dir /путь"
      return 1
    elif (( ${#found[@]} == 1 )); then
      res="${found[0]}"
    else
      # несколько кандидатов — например letsencrypt и caddy одновременно
      local -a args=()
      for f in "${found[@]}"; do
        local dirp="${f%%|*}" rest="${f#*|}" cf="${rest%%|*}" exp
        exp=$(openssl x509 -enddate -noout -in "$dirp/$cf" 2>/dev/null | cut -d= -f2)
        args+=("$dirp/$cf  (до ${exp:-?})" "$f")
      done
      res=$(choose "Нашёл несколько сертификатов для $DOMAIN — какой использовать?" 1 "${args[@]}")
    fi
  fi

  CERT_HOST_DIR="${res%%|*}"; res="${res#*|}"
  CERT_FILE="${res%%|*}"; KEY_FILE="${res#*|}"

  local exp
  exp=$(openssl x509 -enddate -noout -in "$CERT_HOST_DIR/$CERT_FILE" 2>/dev/null | cut -d= -f2)
  ok "Сертификат: $CERT_HOST_DIR/$CERT_FILE"
  [[ -n "$exp" ]] && dim "  действителен до: $exp"

  # /etc/letsencrypt/live — симлинки в ../../archive. Монтируем корень целиком,
  # иначе внутри контейнера окажутся битые ссылки и Xray не стартует.
  if [[ "$CERT_HOST_DIR" == /etc/letsencrypt/* ]]; then
    MOUNT_SRC="/etc/letsencrypt"; MOUNT_DST="/etc/letsencrypt"
    CERT_IN_CONTAINER="$CERT_HOST_DIR/$CERT_FILE"
    KEY_IN_CONTAINER="$CERT_HOST_DIR/$KEY_FILE"
    dim "  letsencrypt → монтирую /etc/letsencrypt целиком (симлинки в archive)"
  else
    MOUNT_SRC="$CERT_HOST_DIR"; MOUNT_DST="$CONTAINER_CERT_DIR"
    CERT_IN_CONTAINER="$CONTAINER_CERT_DIR/$CERT_FILE"
    KEY_IN_CONTAINER="$CONTAINER_CERT_DIR/$KEY_FILE"
  fi
  dim "  в контейнере: $CERT_IN_CONTAINER"
  return 0
}

do_certs() {
  need_root
  resolve_certs || return 1

  local cf="$COMPOSE_DIR/docker-compose.yml"
  [[ -f "$cf" ]] || { warn "$cf не найден — пропускаю патч compose"; return 0; }

  local mount="- '${MOUNT_SRC}:${MOUNT_DST}:ro'"
  if grep -qF "${MOUNT_SRC}:${MOUNT_DST}" "$cf"; then
    ok "Volume уже смонтирован"
  elif (( DRY_RUN )); then
    dim "dry-run: добавил бы в $cf строку  $mount"
  else
    mkdir -p "$BACKUP_DIR"
    cp -a "$cf" "$BACKUP_DIR/docker-compose.yml.$(date +%Y%m%d-%H%M%S)"

    local rc=0
    awk -v m="$mount" '
      BEGIN { done=0 }
      /^[[:space:]]*volumes:[[:space:]]*$/ && !done {
        print; match($0, /^[[:space:]]*/); ind=RLENGTH
        printf "%*s%s\n", ind+2, "", m; done=1; next
      }
      { print }
      END { if (!done) exit 3 }
    ' "$cf" >"$cf.new" || rc=$?

    if (( rc != 0 )); then
      rm -f "$cf.new"
      warn "Блок volumes: в compose не нашёл. Добавь руками:"
      echo "    volumes:"; echo "      $mount"
      return 1
    fi
    mv "$cf.new" "$cf"
    ok "Volume добавлен в $cf (бэкап в $BACKUP_DIR)"
    if confirm "Перезапустить remnanode?"; then
      (cd "$COMPOSE_DIR" && docker compose down && docker compose up -d) \
        && ok "remnanode перезапущен" || warn "перезапуск не удался"
    fi
  fi

  install_cert_hook
}

# После продления серта файлы на диске новые, а Xray держит в памяти старый —
# до рестарта клиенты получают протухший сертификат.
install_cert_hook() {
  (( DRY_RUN )) && { dim "dry-run: пропускаю установку хука продления"; return 0; }

  mkdir -p "$(dirname "$CERT_STAMP")"

  cat >/usr/local/sbin/remnanode-cert-reload.sh <<EOF
#!/bin/sh
# Рестартует remnanode, если файл сертификата новее отметки.
CERT="$CERT_HOST_DIR/$CERT_FILE"
STAMP="$CERT_STAMP"
[ -f "\$CERT" ] || exit 0
if [ ! -f "\$STAMP" ] || [ "\$CERT" -nt "\$STAMP" ]; then
  cd "$COMPOSE_DIR" 2>/dev/null && docker compose restart remnanode >/dev/null 2>&1
  touch "\$STAMP"
  logger -t remna-node-kit "cert changed, remnanode restarted"
fi
exit 0
EOF
  chmod +x /usr/local/sbin/remnanode-cert-reload.sh
  touch "$CERT_STAMP"

  # certbot: хук после успешного продления
  if [[ -d /etc/letsencrypt ]]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    ln -sf /usr/local/sbin/remnanode-cert-reload.sh \
           /etc/letsencrypt/renewal-hooks/deploy/remnanode-reload.sh
    ok "Хук certbot: /etc/letsencrypt/renewal-hooks/deploy/remnanode-reload.sh"
  fi

  # На случай acme.sh / Caddy / ручного обновления — суточный таймер по mtime
  cat >/etc/systemd/system/remnanode-cert-reload.service <<'EOF'
[Unit]
Description=Restart remnanode when TLS certificate changes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/remnanode-cert-reload.sh
EOF
  cat >/etc/systemd/system/remnanode-cert-reload.timer <<'EOF'
[Unit]
Description=Daily TLS certificate change check for remnanode

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now remnanode-cert-reload.timer >/dev/null 2>&1 \
    && ok "Суточный таймер проверки серта включён" || warn "таймер не поднялся"
}

# ======================================================================
#  4. СБОРКА ИНБАУНДА
# ======================================================================

buffer_size() { local r; r=$(ram_mb); (( r < 1536 )) && echo 256 || echo 512; }
post_bytes()  { local r; r=$(ram_mb); (( r < 1536 )) && echo 65536 || echo 131072; }

port_busy() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -lntH "sport = :$1" 2>/dev/null | grep -q .
}

# ---------------------------------------------------- валидаторы ----------

validate_tag()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$ ]]; }
validate_path() { [[ "$1" =~ ^/[A-Za-z0-9._~!$\&*+,\;=:@%/-]{1,120}$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
validate_domain(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# de.example.com + 8445 -> VLESS-XHTTP-DE-8445
derive_tag() {
  local d="$1" port="$2" label
  label=$(echo "$d" | cut -d. -f1 | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9-')
  [[ -z "$label" ]] && label="NODE"
  printf 'VLESS-XHTTP-%s-%s' "$label" "$port"
}

gen_path_hex()   { printf '/%s' "$(openssl rand -hex 8)"; }
gen_path_mimic() {
  local p=("/api/v1" "/api/v2" "/api/v3" "/assets" "/static" "/cdn" "/media" "/_next/data")
  printf '%s/%s' "${p[$((RANDOM % ${#p[@]}))]}" "$(openssl rand -hex 4)"
}

# ------------------------------------------- интерактивный выбор ----------

# Тег обязан быть уникальным по всем профилям: иначе резолв tag -> uuid
# в панели даст не тот инбаунд, а патч затрёт чужую ноду.
tag_taken_elsewhere() {
  local tag="$1" own_uuid="$2"
  [[ -z "$ALL_INBOUNDS" ]] && return 1
  local owner
  owner=$(jq -r --arg t "$tag" \
    'map(select(.tag == $t)) | .[0] | (.profileUuid // .configProfileUuid // empty)' <<<"$ALL_INBOUNDS")
  [[ -n "$owner" && "$owner" != "$own_uuid" ]]
}

prompt_tag() {
  local profile_uuid="$1" suggested
  suggested=$(derive_tag "$DOMAIN" "$XHTTP_PORT")

  hr
  echo "Тег инбаунда — уникальное имя, по которому панель его находит." >&2
  echo "На каждой ноде он должен быть свой, иначе патч затрёт чужой инбаунд." >&2
  [[ -n "$ALL_INBOUNDS" ]] && {
    echo "Уже занятые теги:" >&2
    jq -r '.[] | "  · \(.tag)"' <<<"$ALL_INBOUNDS" 2>/dev/null | head -20 >&2
  }
  hr

  local t
  while :; do
    t=$(ask_valid "Тег инбаунда" "$suggested" validate_tag \
        "Только латиница, цифры, точка, дефис, подчёркивание. 2-32 символа, начинается с буквы или цифры.")
    if tag_taken_elsewhere "$t" "$profile_uuid"; then
      warn "Тег «$t» уже занят инбаундом в другом профиле — выбери другой."
      continue
    fi
    break
  done
  INBOUND_TAG="$t"
}

prompt_port() {
  local cfg="$1"
  local p
  while :; do
    p=$(ask_valid "Порт xHTTP" "${XHTTP_PORT:-$DEFAULT_PORT}" validate_port "Число 1..65535.")

    if [[ "$p" == "443" ]]; then
      warn "443 занят самим Xray под REALITY (схема eGames)."
      confirm "Всё равно взять 443?" || continue
    elif [[ "$p" == "80" ]]; then
      warn "80 обычно держит nginx/caddy под ACME."
      confirm "Всё равно взять 80?" || continue
    fi

    # столкновение с другим инбаундом в этом же профиле — Xray не забиндится
    if [[ -n "$cfg" ]]; then
      local clash
      clash=$(jq -r --arg t "$INBOUND_TAG" --argjson p "$p" \
        '.inbounds[]? | select(.tag != $t and (.port == $p)) | .tag' <<<"$cfg" 2>/dev/null | head -1)
      if [[ -n "$clash" ]]; then
        warn "Порт $p в этом профиле уже занят инбаундом «$clash» — Xray не стартует."
        continue
      fi
    fi

    if port_busy "$p"; then
      warn "Порт $p уже кто-то слушает на хосте:"
      ss -lntp "sport = :$p" 2>/dev/null | tail -n +2 >&2
      dim "Если это уже поднятый Xray с этим же инбаундом — нормально."
      confirm "Продолжить с портом $p?" || continue
    fi
    break
  done
  XHTTP_PORT="$p"
}

prompt_path() {
  [[ -n "$XHTTP_PATH" ]] && return 0

  local style="${PATH_STYLE:-}"
  if [[ -z "$style" ]]; then
    style=$(choose "Как сгенерировать path?" 1 \
      "Случайные 16 hex — /a1b2c3d4e5f6a7b8" hex \
      "Похожий на настоящий эндпоинт — /api/v2/9f8e7d6c" mimic \
      "Ввести свой" custom)
  fi

  case "$style" in
    hex)    XHTTP_PATH=$(gen_path_hex) ;;
    mimic)  XHTTP_PATH=$(gen_path_mimic) ;;
    custom) XHTTP_PATH=$(ask_valid "Path (начинается со слеша)" "/api/v2/$(openssl rand -hex 4)" \
              validate_path "Начинается с /, латиница и цифры, до 120 символов, без пробелов.") ;;
    *)      XHTTP_PATH=$(gen_path_hex) ;;
  esac
  ok "Path: $XHTTP_PATH"
}

prompt_transport() {
  # значения по умолчанию, если тонкую настройку не запрашивали
  [[ -n "$XHTTP_MODE"  ]] || XHTTP_MODE="auto"
  [[ -n "$XHTTP_ALPN"  ]] || XHTTP_ALPN="h2,http/1.1"
  [[ -n "$POST_BYTES"  ]] || POST_BYTES=$(post_bytes)
  [[ -n "$ROUTE_ONLY"  ]] || ROUTE_ONLY="true"

  if (( ! EXPERT )); then
    (( ASSUME_YES )) && return 0
    confirm "Настроить транспорт тонко (mode, ALPN, размер порции, sniffing)?" || return 0
  fi

  XHTTP_MODE=$(choose "Режим xHTTP" 1 \
    "auto — клиент решает сам, самый совместимый" auto \
    "stream-one — одно соединение на сессию, меньше оверхед" stream-one \
    "packet-up — раздельные POST, лучше проходит инспекцию" packet-up \
    "stream-up — потоковый upload" stream-up)

  XHTTP_ALPN=$(choose "ALPN" 1 \
    "h2 + http/1.1 — совместимо" "h2,http/1.1" \
    "только h2 — чище отпечаток" "h2")

  local rec; rec=$(post_bytes)
  POST_BYTES=$(choose "Размер порции upload (RAM $(ram_mb) MB, рекомендую $rec)" 1 \
    "$rec — по объёму памяти ноды" "$rec" \
    "65536 — экономно" "65536" \
    "131072 — стандарт" "131072" \
    "262144 — только если памяти в запасе" "262144")

  ROUTE_ONLY=$(choose "Sniffing на ноде" 1 \
    "routeOnly true — домен только для роутинга, коннект по исходному IP" "true" \
    "routeOnly false — подменять адрес на сниффнутый домен" "false")
}

build_inbound() {
  [[ -n "$XHTTP_PATH" ]]  || XHTTP_PATH=$(gen_path_hex)
  [[ -n "$INBOUND_TAG" ]] || INBOUND_TAG=$(derive_tag "$DOMAIN" "$XHTTP_PORT")
  [[ -n "$XHTTP_MODE" ]]  || XHTTP_MODE="auto"
  [[ -n "$XHTTP_ALPN" ]]  || XHTTP_ALPN="h2,http/1.1"
  [[ -n "$POST_BYTES" ]]  || POST_BYTES=$(post_bytes)
  [[ -n "$ROUTE_ONLY" ]]  || ROUTE_ONLY="true"

  local alpn_json
  alpn_json=$(jq -cn --arg a "$XHTTP_ALPN" '$a | split(",")')

  jq -n \
    --arg tag "$INBOUND_TAG" --argjson port "$XHTTP_PORT" \
    --arg host "$DOMAIN" --arg path "$XHTTP_PATH" --arg mode "$XHTTP_MODE" \
    --argjson alpn "$alpn_json" --argjson ro "$ROUTE_ONLY" \
    --arg cert "${CERT_IN_CONTAINER:-/etc/ssl/node/fullchain.pem}" \
    --arg key  "${KEY_IN_CONTAINER:-/etc/ssl/node/privkey.pem}" \
    --argjson post "$POST_BYTES" \
    '{
      tag: $tag, listen: "0.0.0.0", port: $port, protocol: "vless",
      settings: { clients: [], decryption: "none" },
      streamSettings: {
        network: "xhttp", security: "tls",
        tlsSettings: {
          serverName: $host, rejectUnknownSni: true, minVersion: "1.2",
          alpn: $alpn,
          certificates: [ { certificateFile: $cert, keyFile: $key, ocspStapling: 3600 } ]
        },
        xhttpSettings: {
          host: $host, path: $path, mode: $mode,
          extra: {
            scMaxEachPostBytes: $post,
            scStreamUpServerSecs: "10-20",
            xPaddingBytes: "100-300",
            noSSEHeader: false
          }
        }
      },
      sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: $ro }
    }'
}

patch_profile_config() {
  local cfg="$1" inbound="$2"
  jq --argjson inb "$inbound" --arg tag "$INBOUND_TAG" --argjson buf "$(buffer_size)" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) + [$inb]
    | .policy.levels."0".bufferSize = ((.policy.levels."0".bufferSize) // $buf)
    | .outbounds = (
        if ((.outbounds // []) | map(.tag) | index("BLOCK")) then (.outbounds // [])
        else (.outbounds // []) + [{tag:"BLOCK", protocol:"blackhole"}] end)
    | .routing.rules = (
        if (((.routing.rules // []) | map(select(.outboundTag=="BLOCK" and (((.ip // []) | index("geoip:private")) != null))) | length) > 0)
        then (.routing.rules // [])
        else [{type:"field", ip:["geoip:private"], outboundTag:"BLOCK"}] + (.routing.rules // []) end)
  ' <<<"$cfg"
}

# --- валидация до отправки: xray сам скажет, что не так --------------------
validate_config() {
  local cfg="$1"

  if (( SKIP_VALIDATE )); then dim "Валидация пропущена (--skip-validate)"; return 0; fi

  if ! have_node_container; then
    warn "Контейнер remnanode не запущен — проверить конфиг нечем, шлю как есть."
    return 0
  fi

  # Remnawave-снипеты Xray не понимает — их подставляет панель
  if grep -q '"snippet"' <<<"$cfg"; then
    warn "В профиле есть \"snippet\" — Xray его не разберёт, пропускаю валидацию."
    return 0
  fi

  log "Проверяю конфиг через xray -test в контейнере…"
  docker exec -i "$(find_node_container)" sh -c 'cat > /tmp/rnk-test.json' <<<"$cfg" 2>/dev/null || {
    warn "Не смог положить файл в контейнер, пропускаю валидацию"; return 0; }

  local out rc=0
  out=$(docker exec "$(find_node_container)" xray run -test -c /tmp/rnk-test.json 2>&1) || rc=$?
  if (( rc != 0 )); then
    out=$(docker exec "$(find_node_container)" xray -test -config /tmp/rnk-test.json 2>&1) && rc=0 || rc=$?
  fi
  docker exec "$(find_node_container)" rm -f /tmp/rnk-test.json 2>/dev/null || true

  if (( rc == 0 )); then
    ok "Конфиг валиден, сертификаты читаются"
    return 0
  fi

  hr; err "xray отбраковал конфиг:"; echo "$out" | tail -20; hr
  dim "Чаще всего это: не смонтирован каталог с сертами, опечатка в пути,"
  dim "либо тег инбаунда, на который ссылается routing, не совпадает."
  confirm "Всё равно залить в панель?" && return 0
  return 1
}

# ======================================================================
#  5. API
# ======================================================================

api() {
  local method="$1" path="$2" body="${3:-}"
  local -a h=(-H "Authorization: Bearer $PANEL_TOKEN" -H "Content-Type: application/json")
  [[ -n "$PANEL_COOKIE"  ]] && h+=(-H "Cookie: $PANEL_COOKIE")
  [[ -n "$PANEL_API_KEY" ]] && h+=(-H "X-Api-Key: $PANEL_API_KEY")

  if (( DRY_RUN )) && [[ "$method" != "GET" ]]; then
    dim "dry-run: $method $path" >&2
    [[ -n "$body" ]] && jq . <<<"$body" >&2
    echo '{"response":{"__dryrun":true}}'; return 0
  fi

  if [[ -n "$body" ]]; then
    curl -fsSL -X "$method" "${h[@]}" -d "$body" "${PANEL_URL%/}/api$path"
  else
    curl -fsSL -X "$method" "${h[@]}" "${PANEL_URL%/}/api$path"
  fi
}

api_preflight() {
  [[ -n "$PANEL_URL"   ]] || PANEL_URL=$(ask "URL панели (https://panel.example.com)" "")
  [[ -n "$PANEL_TOKEN" ]] || PANEL_TOKEN=$(ask "API-токен панели" "")
  [[ -n "$PANEL_URL" && -n "$PANEL_TOKEN" ]] || { err "Без URL и токена в API-режим не пойдём."; return 1; }

  local out
  if ! out=$(api GET /config-profiles 2>&1); then
    err "Панель не ответила на GET /api/config-profiles"; dim "$out"
    cat >&2 <<'EOT'

Что проверить:
  • токен жив и создан в Remnawave Settings → API
  • cookie-гейт eGames не закрывает /api — если закрывает,
    передай --cookie 'SECRET=SECRET' тем же значением, что в URL панели
  • панель за Caddy с ключом — тогда --api-key
EOT
    return 1
  fi
  jq -e '.response' >/dev/null 2>&1 <<<"$out" || {
    err "Ответ не похож на JSON от Remnawave — почти наверняка сработал cookie-гейт nginx."; return 1; }
  ok "Панель отвечает"
}

pick() {  # pick <json-array> <label> <value> <prompt> <preselect>
  local arr="$1" lf="$2" vf="$3" prompt="$4" pre="${5:-}"
  local n; n=$(jq 'length' <<<"$arr" 2>/dev/null) || { err "Не массив: $prompt"; return 1; }
  (( n > 0 )) || { err "Список пуст: $prompt"; return 1; }

  if [[ -n "$pre" ]]; then
    local v; v=$(jq -r --arg p "$pre" --arg lf "$lf" --arg vf "$vf" \
      'map(select(.[$lf] == $p)) | .[0][$vf] // empty' <<<"$arr")
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    warn "«$pre» не найден, выбирай из списка"
  fi

  { printf '\n  %s%s%s\n' "$C_BD$C_BL" "$prompt" "$C_N"
    jq -r --arg lf "$lf" 'to_entries[] | "\(.key+1)\t\(.value[$lf])"' <<<"$arr" \
      | while IFS=$'\t' read -r num lbl; do
          printf '   %s%s%s  %s\n' "$C_BB" "$(pad "$num" 2)" "$C_N" "$lbl"
        done
    echo
  } >&2
  local i
  while :; do
    i=$(ask "  номер" "1")
    [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= n )) && break
    echo "  Введи число 1..$n" >&2
  done
  jq -r --argjson i "$((i-1))" --arg vf "$vf" '.[$i][$vf]' <<<"$arr"
}

base_profile_config() {
  jq -n --argjson buf "$(buffer_size)" '{
    log: { loglevel: "warning" },
    dns: { servers: ["1.1.1.1", "8.8.8.8", "localhost"], queryStrategy: "UseIPv4" },
    inbounds: [],
    outbounds: [
      { tag: "DIRECT", protocol: "freedom", settings: { domainStrategy: "UseIPv4" } },
      { tag: "BLOCK", protocol: "blackhole" }
    ],
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules: [
        { type: "field", ip: ["geoip:private"], outboundTag: "BLOCK" },
        { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
      ]
    },
    policy: { levels: { "0": { bufferSize: $buf } } }
  }'
}

do_xhttp_api() {
  ensure_deps
  api_preflight || return 1

  if [[ -z "$API_SCOPE" ]]; then
    API_SCOPE=$(choose "Насколько далеко идём?" 3 \
      "только инбаунд в Config Profile" inbound \
      "инбаунд + Host" host \
      "инбаунд + Host + включить на ноде + сквад" full)
  fi

  [[ -n "$DOMAIN" ]] || DOMAIN=$(ask_valid "SelfSteal-домен ноды" "" validate_domain \
      "Похоже на домен: node.example.com")

  # список всех инбаундов панели нужен для проверки уникальности тега
  ALL_INBOUNDS=$(api GET /config-profiles/inbounds 2>/dev/null \
                 | jq '(.response.inbounds // .response)' 2>/dev/null) || ALL_INBOUNDS=""

  # ---- профиль: существующий или новый
  local profiles pu cfg
  profiles=$(api GET /config-profiles | jq '.response.configProfiles // .response')

  local pick_mode="existing"
  if [[ -z "$PROFILE_NAME" ]]; then
    hr
    echo "Один профиль на все ноды — экономно, но инбаунды в нём должны иметь разные теги." >&2
    echo "Отдельный профиль на ноду — многословнее, зато ничего не пересекается." >&2
    pick_mode=$(choose "Config Profile" 1 \
      "выбрать существующий" existing \
      "создать новый под эту ноду" new)
  fi

  if [[ "$pick_mode" == "new" ]]; then
    local pname
    pname=$(ask "Имя нового профиля" "$(echo "$DOMAIN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')-profile")
    cfg=$(base_profile_config)
    local resp
    resp=$(api POST /config-profiles "$(jq -n --arg n "$pname" --argjson c "$cfg" '{name:$n, config:$c}')") \
      || { err "Не смог создать профиль."; return 1; }
    pu=$(jq -r '.response.uuid // empty' <<<"$resp")
    [[ -z "$pu" ]] && { err "Панель не вернула uuid нового профиля."; return 1; }
    ok "Создан профиль «$pname» ($pu)"
  else
    pu=$(pick "$profiles" name uuid "Config Profile" "$PROFILE_NAME") || return 1
    ok "Профиль: $pu"
    cfg=$(api GET "/config-profiles/$pu" | jq '.response.config')
    [[ "$cfg" == "null" || -z "$cfg" ]] && { err "Не смог прочитать config профиля."; return 1; }
  fi
  LAST_PROFILE_UUID="$pu"

  # ---- порт и тег (порядок важен: тег выводится из порта)
  [[ -n "$XHTTP_PORT" ]] || XHTTP_PORT="$DEFAULT_PORT"
  if [[ -z "$INBOUND_TAG" ]] && (( ! ASSUME_YES )); then
    prompt_port "$cfg"
    prompt_tag "$pu"
  else
    [[ -n "$INBOUND_TAG" ]] || INBOUND_TAG=$(derive_tag "$DOMAIN" "$XHTTP_PORT")
    if tag_taken_elsewhere "$INBOUND_TAG" "$pu"; then
      err "Тег «$INBOUND_TAG» уже занят инбаундом в другом профиле — задай --tag явно."
      return 1
    fi
  fi

  [[ -n "$CERT_IN_CONTAINER" ]] || resolve_certs || return 1

  # ---- path: в панели он главнее локального конфига.
  # Иначе переставил ноду с нуля — path перегенерился, выданные конфиги мертвы.
  local existing
  existing=$(jq -r --arg t "$INBOUND_TAG" \
    '.inbounds[]? | select(.tag==$t) | .streamSettings.xhttpSettings.path // empty' <<<"$cfg")
  if [[ -n "$existing" ]]; then
    hr
    warn "В профиле уже есть инбаунд «$INBOUND_TAG» с path: $existing"
    dim "Если сменить path — все ранее выданные клиентам конфиги перестанут работать."
    if confirm "Оставить существующий path?"; then
      XHTTP_PATH="$existing"; ok "Переиспользую $XHTTP_PATH"
    else
      XHTTP_PATH=""; prompt_path
      warn "Клиентам понадобится новая подписка"
    fi
  else
    prompt_path
  fi

  prompt_transport

  # ---- бэкап
  mkdir -p "$BACKUP_DIR"
  local bk="$BACKUP_DIR/profile-${pu}-$(date +%Y%m%d-%H%M%S).json"
  jq . <<<"$cfg" >"$bk"; ok "Бэкап: $bk"

  # ---- патч + валидация
  local inbound newcfg
  inbound=$(build_inbound)
  newcfg=$(patch_profile_config "$cfg" "$inbound") || { err "jq не собрал конфиг."; return 1; }

  hr; echo "Инбаунд:"
  jq -r '"  tag:  \(.tag)\n  port: \(.port)\n  path: \(.streamSettings.xhttpSettings.path)\n  mode: \(.streamSettings.xhttpSettings.mode)\n  alpn: \(.streamSettings.tlsSettings.alpn | join(\",\"))\n  sni:  \(.streamSettings.tlsSettings.serverName)\n  cert: \(.streamSettings.tlsSettings.certificates[0].certificateFile)"' <<<"$inbound"
  hr

  validate_config "$newcfg" || { warn "Отменено. Профиль не тронут."; return 1; }
  confirm "Патчить профиль в панели?" || { warn "Отменено"; return 1; }

  api_write PATCH /config-profiles \
    "$(jq -n --arg u "$pu" --argjson c "$newcfg" '{uuid:$u, config:$c}')" \
    "Патч профиля" >/dev/null || { err "Откат: srus --rollback"; return 1; }

  # Панель может ответить 200 и молча выбросить тело (whitelist в DTO).
  # Поэтому не верим коду ответа — перечитываем профиль и ищем свой тег.
  if verify_in_profile "$pu" "$INBOUND_TAG"; then
    ok "Инбаунд «$INBOUND_TAG» есть в профиле"
  else
    err "PATCH прошёл, но инбаунда в профиле нет — панель отбросила тело запроса."
    dim "Так бывает, если схема config-profiles в 3.2.3 отличается."
    dim "Запусти с --dry-run и пришли вывод, поправлю поля."
    return 1
  fi

  save_conf
  [[ "$API_SCOPE" == "inbound" ]] && { do_postflight; return 0; }

  # ---- uuid инбаунда (панель присваивает его не мгновенно)
  local iu="" try
  for try in 1 2 3; do
    iu=$(api GET /config-profiles/inbounds 2>/dev/null \
         | jq -r --arg t "$INBOUND_TAG" '(.response.inbounds // .response) | map(select(.tag==$t)) | .[0].uuid // empty')
    [[ -n "$iu" ]] && break
    sleep 2
  done
  [[ -z "$iu" ]] && { err "uuid инбаунда не нашёлся — Host и ноду настрой в панели руками"; do_postflight; return 0; }
  ok "Inbound uuid: $iu"

  # ---- Host
  local host_body
  [[ -n "$HOST_REMARK" ]] || HOST_REMARK=$(ask "Название Host в панели" "${DOMAIN} xHTTP ${XHTTP_PORT}")
  host_body=$(jq -n --arg pu "$pu" --arg iu "$iu" --arg d "$DOMAIN" --arg p "$XHTTP_PATH" \
    --argjson port "$XHTTP_PORT" --arg rem "$HOST_REMARK" '
    { inbound: { configProfileUuid: $pu, configProfileInboundUuid: $iu },
      remark: $rem, address: $d, port: $port, path: $p, host: $d, sni: $d,
      alpn: "h2", fingerprint: "chrome", securityLayer: "TLS", isDisabled: false,
      xHttpExtraParams: {
        scMaxEachPostBytes: 1000000, xPaddingBytes: "100-300",
        xmux: { maxConcurrency: "2-4", hMaxRequestTimes: "600-900", hMaxReusableSecs: "1800-3000" } } }')

  api_write POST /hosts "$host_body" "Создание Host" >/dev/null && ok "Host создан" \
    || warn "Host заведи руками — тело запроса выше"

  [[ "$API_SCOPE" == "host" ]] && { do_postflight; return 0; }

  # ---- включение инбаунда на ноде
  enable_on_node "$pu" "$iu" || true

  # ---- сквад (без него инбаунд не попадёт в подписки)
  add_to_squad "$iu" || true

  do_postflight
}

# Пишущий вызов с показом ошибки. Раньше ответ уходил в /dev/null,
# и провалившийся PATCH выглядел как успешный.
api_write() {
  local method="$1" path="$2" body="$3" label="$4" out rc=0
  out=$(api "$method" "$path" "$body" 2>&1) || rc=$?
  if (( rc != 0 )); then
    err "$label — панель отклонила запрос (curl rc=$rc)"
    echo "$out" | head -c 600 >&2; echo >&2
    dim "Тело запроса:" >&2; jq . <<<"$body" >&2
    return 1
  fi
  printf '%s' "$out"
}

verify_in_profile() {
  local pu="$1" tag="$2" cfg
  (( DRY_RUN )) && return 0
  cfg=$(api GET "/config-profiles/$pu" 2>/dev/null | jq '.response.config')
  jq -e --arg t "$tag" '[.inbounds[]?.tag] | index($t) != null' >/dev/null 2>&1 <<<"$cfg"
}

node_has_inbound() {
  local nu="$1" iu="$2"
  (( DRY_RUN )) && return 0
  api GET "/nodes/$nu" 2>/dev/null \
    | jq -e --arg iu "$iu" \
      '[.response.configProfile.activeInbounds[]? | (.uuid // .)] | index($iu) != null' >/dev/null 2>&1
}

enable_on_node() {
  local pu="$1" iu="$2" nodes nu node cur node_body
  nodes=$(api GET /nodes | jq '.response.nodes // .response')
  nu=$(pick "$nodes" name uuid "Нода, на которой включить инбаунд" "$NODE_NAME") || return 1

  if node_has_inbound "$nu" "$iu"; then ok "Инбаунд уже включён на ноде"; return 0; fi

  node=$(api GET "/nodes/$nu" | jq '.response')
  cur=$(jq -r '[.configProfile.activeInbounds[]? | (.uuid // .)] | @json' <<<"$node")
  [[ -z "$cur" || "$cur" == "null" ]] && cur="[]"

  # Профиль ноды меняется целиком: если он был другой, старые инбаунды
  # к новому профилю не относятся и в список идти не должны.
  local oldpu
  oldpu=$(jq -r '.configProfile.activeConfigProfileUuid // empty' <<<"$node")
  if [[ -n "$oldpu" && "$oldpu" != "$pu" ]]; then
    warn "На ноде был профиль $oldpu, меняю на $pu — прежние инбаунды отключатся."
    confirm "Продолжить?" || return 1
    cur="[]"
  fi

  node_body=$(jq -n --arg u "$nu" --arg pu "$pu" --arg iu "$iu" --argjson cur "$cur" \
    '{uuid:$u, configProfile:{activeConfigProfileUuid:$pu, activeInbounds: (($cur + [$iu]) | unique)}}')

  api_write PATCH /nodes "$node_body" "Включение на ноде" >/dev/null || return 1

  sleep 2
  if node_has_inbound "$nu" "$iu"; then
    ok "Инбаунд включён на ноде"
  else
    err "PATCH прошёл, но в activeInbounds инбаунда нет."
    dim "Включи вручную: Nodes → нода → Change Profile → отметить инбаунд."
    return 1
  fi

  # Пуш конфига на ноду. Без него Xray продолжит крутить старую версию.
  api POST "/nodes/$nu/actions/restart" '{}' >/dev/null 2>&1 \
    && ok "Нода перезапущена" \
    || dim "Рестарт ноды не дёрнулся — панель обычно пушит конфиг сама в течение минуты"
  return 0
}

add_to_squad() {
  local iu="$1" squads su squad sinb squad_body
  squads=$(api GET /internal-squads | jq '.response.internalSquads // .response')
  su=$(pick "$squads" name uuid "Internal Squad (без него инбаунд не попадёт в подписки)" "$SQUAD_NAME") || return 1

  squad=$(api GET "/internal-squads/$su" | jq '.response')
  sinb=$(jq -r '[.inbounds[]? | (.uuid // .)] | @json' <<<"$squad")
  [[ -z "$sinb" || "$sinb" == "null" ]] && sinb="[]"

  if jq -e --arg iu "$iu" 'index($iu) != null' >/dev/null 2>&1 <<<"$sinb"; then
    ok "Инбаунд уже в скваде"; return 0
  fi

  squad_body=$(jq -n --arg u "$su" --arg iu "$iu" --argjson cur "$sinb" \
    '{uuid:$u, inbounds: (($cur + [$iu]) | unique)}')
  api_write PATCH /internal-squads "$squad_body" "Добавление в сквад" >/dev/null || return 1

  sleep 1
  if api GET "/internal-squads/$su" 2>/dev/null \
     | jq -e --arg iu "$iu" '[.response.inbounds[]? | (.uuid // .)] | index($iu) != null' >/dev/null 2>&1; then
    ok "Добавлен в сквад"
  else
    warn "Проверка не подтвердила добавление — глянь Internal Squads в панели"
  fi
  return 0
}

do_xhttp_print() {
  ensure_deps
  [[ -n "$DOMAIN" ]] || DOMAIN=$(ask "SelfSteal-домен ноды" "")
  resolve_certs || warn "Пути к сертам будут дефолтные — поправь руками"

  local inbound; inbound=$(build_inbound)
  hr; echo "Вставь в массив inbounds своего Config Profile:"; hr
  jq . <<<"$inbound"
  hr; echo "И проверь, что в профиле есть:"
  jq -n --argjson b "$(buffer_size)" '{policy:{levels:{"0":{bufferSize:$b}}}}'
  jq -n '{routing:{rules:[{type:"field",ip:["geoip:private"],outboundTag:"BLOCK"}]},outbounds:[{tag:"BLOCK",protocol:"blackhole"}]}'
  hr
  summary
}

# ======================================================================
#  6. ПОСТФЛАЙТ
# ======================================================================

do_postflight() {
  hr; log "Постфлайт"
  local fails=0

  # --- ядро поднялось?
  if have_node_container; then
    sleep 3
    local xl ct; ct=$(find_node_container)
    xl=$(docker exec "$ct" xlogs 2>/dev/null | tail -40)
    [[ -z "$xl" ]] && xl=$(docker logs --tail 60 "$ct" 2>&1)
    if grep -qiE 'SPAWN_ERROR|failed to (parse|start)|panic' <<<"$xl"; then
      err "Xray ругается:"; grep -iE 'SPAWN_ERROR|failed|panic' <<<"$xl" | tail -8; (( fails++ ))
      dim "Подробности: docker logs --tail 60 $(find_node_container)"
    else
      ok "Xray стартовал без ошибок"
    fi
  else
    warn "Контейнер remnanode не запущен"; (( fails++ ))
  fi

  # --- инбаунд реально доехал до ноды?
  if have_node_container && [[ -n "$INBOUND_TAG" ]]; then
    local ct2 live; ct2=$(find_node_container)
    live=$(docker exec "$ct2" sh -c 'cat $(ps -o args= -C xray 2>/dev/null | grep -oE "\-c[= ][^ ]+" | head -1 | sed "s/^-c[= ]//") 2>/dev/null' 2>/dev/null \
           | jq -r '[.inbounds[]?.tag] | join(", ")' 2>/dev/null)
    if [[ -n "$live" ]]; then
      dim "Инбаунды на ноде: $live"
      grep -q "$INBOUND_TAG" <<<"$live" && ok "«$INBOUND_TAG» доехал до ноды" || {
        err "«$INBOUND_TAG» на ноде отсутствует — не включён в Change Profile"; (( fails++ )); }
    fi
  fi

  # --- порт слушается?
  if port_busy "$XHTTP_PORT"; then
    ok "Порт $XHTTP_PORT слушается"
  else
    err "Порт $XHTTP_PORT никто не слушает"; (( fails++ ))
    dim "Панель могла ещё не запушить конфиг — подожди 10-15 сек и повтори --postflight"
  fi

  # --- TLS снаружи с правильным SNI
  if [[ -n "$DOMAIN" ]]; then
    local tls
    tls=$(echo | timeout 10 openssl s_client -connect "${DOMAIN}:${XHTTP_PORT}" \
          -servername "$DOMAIN" -alpn h2 2>&1)
    if grep -q 'Verify return code: 0' <<<"$tls"; then
      ok "TLS-рукопожатие прошло, цепочка валидна"
      grep -m1 'ALPN protocol' <<<"$tls" | sed 's/^/    /' || true
    elif grep -q 'CONNECTED' <<<"$tls"; then
      warn "Соединение есть, но проверка цепочки не прошла:"
      grep -m1 'Verify return code' <<<"$tls" | sed 's/^/    /'
      (( fails++ ))
    else
      err "Не достучался до ${DOMAIN}:${XHTTP_PORT} снаружи"; (( fails++ ))
      dim "Проверь UFW и что DNS A-запись указывает на эту ноду"
    fi
  fi

  # --- conntrack не забит
  local cc cm
  cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
  cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
  if (( cm > 0 )); then
    local pct=$(( cc * 100 / cm ))
    (( pct > 80 )) && warn "conntrack заполнен на ${pct}% ($cc/$cm) — клиенты будут ловить обрывы" \
                   || dim "conntrack: $cc/$cm (${pct}%)"
  fi

  hr
  (( fails == 0 )) && ok "Всё чисто" || err "Проблем: $fails"
  summary
  return $(( fails > 0 ))
}

# ======================================================================
#  7. ОТКАТ
# ======================================================================

do_rollback() {
  ensure_deps
  api_preflight || return 1

  local files
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/profile-*.json 2>/dev/null)
  (( ${#files[@]} > 0 )) || { err "Бэкапов в $BACKUP_DIR нет."; return 1; }

  hr; echo "Бэкапы профилей (свежие сверху):"
  local i=1
  for f in "${files[@]}"; do
    local u; u=$(basename "$f" | sed -E 's/^profile-(.+)-[0-9]{8}-[0-9]{6}\.json$/\1/')
    printf '  %d) %s  %s\n' "$i" "$(date -r "$f" '+%F %T')" "профиль ${u:0:8}…"
    ((i++))
  done
  hr

  local n
  while :; do
    n=$(ask "  номер" "1")
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#files[@]} )) && break
    echo "  Введи число 1..${#files[@]}" >&2
  done

  local file="${files[$((n-1))]}" uuid
  uuid=$(basename "$file" | sed -E 's/^profile-(.+)-[0-9]{8}-[0-9]{6}\.json$/\1/')
  jq -e . "$file" >/dev/null 2>&1 || { err "Файл битый: $file"; return 1; }

  hr
  echo "Откатываю профиль $uuid на состояние $(date -r "$file" '+%F %T')"
  echo "Инбаунды в бэкапе:"; jq -r '.inbounds[]? | "  · \(.tag)  :\(.port)"' "$file"
  hr

  confirm "Залить этот конфиг в панель?" || { warn "Отменено"; return 1; }

  api PATCH /config-profiles "$(jq -n --arg u "$uuid" --argjson c "$(cat "$file")" '{uuid:$u, config:$c}')" >/dev/null \
    && ok "Откат выполнен" || { err "PATCH не прошёл"; return 1; }

  sleep 3; do_postflight
}

# ======================================================================

summary() {
  local rows=(
    "домен|${DOMAIN:-—}"
    "порт|${XHTTP_PORT:-—}"
    "path|${XHTTP_PATH:-—}"
    "тег|${INBOUND_TAG:-—}"
    "транспорт|${XHTTP_MODE:-—} · ${XHTTP_ALPN:-—}"
    "сертификат|${CERT_IN_CONTAINER:-—}"
  )
  echo
  box_top
  box_rowc "$(printf '%s%s%s' "$C_BD$C_W" "ИТОГО" "$C_N")" "ИТОГО"
  box_sep
  local r k v
  for r in "${rows[@]}"; do
    k="${r%%|*}"; v="${r#*|}"
    # длинный путь к серту обрезаем с головы, хвост информативнее
    if (( ${#v} > BOX_W-16 )); then v="…${v: -$((BOX_W-17))}"; fi
    box_rowc "$(printf '%s%s%s%s' "$C_GR" "$(pad "$k" 12)" "$C_N" "$v")" "$(pad "$k" 12)$v"
  done
  box_bot
  printf '    %sлог: %s%s\n\n' "$C_GR" "$LOG" "$C_N"
}

menu() {
  while :; do
    clear 2>/dev/null || true
    local prof; prof=$(detect_tune_profile)

    echo
    box_top
    box_rowc "$(printf '%s%s%s' "$C_BD$C_W" "remnaundersettings" "$C_N")$(pad "" $((BOX_W-4-18-${#VERSION}-1)))$(printf '%s%s%s' "$C_GR" "v$VERSION" "$C_N")" \
             "remnaundersettings$(pad "" $((BOX_W-4-18-${#VERSION}-1)))v$VERSION"
    box_rowc "$(printf '%s%s%s' "$C_GR" "надстройка над eGames · Remnawave" "$C_N")" \
             "надстройка над eGames · Remnawave"
    box_sep

    local d_txt="${DOMAIN:-—}"
    box_rowc "$(dot 1 "$d_txt" "домен не задан")" "● $([[ -n "$DOMAIN" ]] && echo "$d_txt" || echo "домен не задан")"

    local net="порт ${XHTTP_PORT:-$DEFAULT_PORT} · path ${XHTTP_PATH:-—}"
    box_rowc "$(printf '%s%s%s' "$C_GR" "$net" "$C_N")" "$net"

    local hw="$(cpu_cores)C / $(ram_mb) MB · профиль $prof"
    box_rowc "$(printf '%s%s%s' "$C_GR" "$hw" "$C_N")" "$hw"

    local pan_c pan_p
    if [[ -n "$PANEL_URL" && -n "$PANEL_TOKEN" ]]; then
      pan_c="$(printf '%s✓%s панель' "$C_G" "$C_N")"; pan_p="✓ панель"
    else
      pan_c="$(printf '%s○%s панель' "$C_GR" "$C_N")"; pan_p="○ панель"
    fi
    local ck_c ck_p
    if [[ -n "$PANEL_COOKIE" ]]; then ck_c="$(printf '%s✓%s гейт' "$C_G" "$C_N")"; ck_p="✓ гейт"
    else ck_c="$(printf '%s○%s гейт' "$C_GR" "$C_N")"; ck_p="○ гейт"; fi
    box_rowc "${pan_c}   ${ck_c}" "${pan_p}   ${ck_p}"

    box_bot

    section "ХОСТ"
    item "1" "Тюнинг ядра"     "sysctl · conntrack"
    item "2" "Фаервол"         "UFW · порт панели"

    section "ИНБАУНД"
    item "3" "Сертификаты"     "поиск · volume"
    item "4" "Залить в панель" "через API"
    item "5" "Показать JSON"   "вставить руками"

    section "ПРОВЕРКА"
    item "7" "Постфлайт"       "логи · порт · TLS"
    item "8" "Откат профиля"   "из бэкапа"

    section "ПРОЧЕЕ"
    item "6" "Всё подряд"      "1 → 2 → 3 → 4"
    item "9" "Параметры"       "домен · токен"
    item "p" "Новый path"      "перегенерация"
    item "0" "Выход"           ""
    echo

    local c; c=$(ask "  выбор" "")
    echo
    case "$c" in
      1) do_tune ;;
      2) do_firewall; save_conf ;;
      3) do_certs; save_conf ;;
      4) do_xhttp_api; save_conf ;;
      5) do_xhttp_print; save_conf ;;
      6) do_tune; do_firewall; do_certs; do_xhttp_api; save_conf ;;
      7) do_postflight ;;
      8) do_rollback ;;
      9) setup_wizard ;;
      p|P) XHTTP_PATH=""; prompt_path; save_conf ;;
      0) printf '  %sПока.%s\n\n' "$C_GR" "$C_N"; exit 0 ;;
      *) warn "Не понял команду «$c»" ;;
    esac

    echo
    read -r -p "  ${C_GR}Enter — назад в меню${C_N} " _ </dev/tty
  done
}

setup_wizard() {
  DOMAIN=$(ask       "SelfSteal-домен ноды"      "$DOMAIN")
  XHTTP_PORT=$(ask   "Порт xHTTP"                "$XHTTP_PORT")
  PANEL_URL=$(ask    "URL панели"                "$PANEL_URL")
  PANEL_TOKEN=$(ask  "API-токен"                 "$PANEL_TOKEN")
  PANEL_IP=$(ask     "IP панели (для NODE_PORT)" "$PANEL_IP")
  PANEL_COOKIE=$(ask "Cookie-гейт, если есть"    "$PANEL_COOKIE")
  save_conf; ok "Сохранено в $CONF"
}

usage() {
  cat <<EOF
remnaundersettings $VERSION — надстройка над install_remnawave.sh (eGames)

  srus                   интерактивное меню
  srus --all -y --domain d.tld --panel-url … --token … --panel-ip …

Действия:
  --tune          sysctl под профиль железа (base / dual / tiny)
  --firewall      UFW: открыть xHTTP, закрыть NODE_PORT
  --certs         найти серты, смонтировать, повесить хук продления
  --xhttp         собрать инбаунд, проверить, залить в панель
  --print         собрать инбаунд и вывести JSON
  --postflight    проверить живость: логи, порт, TLS, conntrack
  --rollback      откатить профиль из бэкапа
  --all           tune + firewall + certs + xhttp

Параметры:
  --domain X      SelfSteal-домен (SNI, Host)
  --port N        порт xHTTP (по умолчанию 8445)
  --path X        зафиксировать path вместо рандома
  --tag X         тег инбаунда
  --panel-url X   https://panel.example.com
  --token X       API-токен панели
  --cookie X      'SECRET=SECRET' если /api закрыт гейтом eGames
  --api-key X     X-Api-Key, если панель за Caddy
  --panel-ip X    кому пускать на NODE_PORT (иначе определит сам)
  --profile X     имя Config Profile
  --node X        имя ноды
  --squad X       имя Internal Squad
  --scope X       inbound | host | full
  --cert-dir X    каталог с сертами, если автопоиск промахнулся
  --tune-profile  auto | base | dual | tiny
  --mode X        xHTTP mode: auto | stream-one | packet-up | stream-up
  --alpn X        'h2,http/1.1' или 'h2'
  --path-style X  hex | mimic  (стиль генерации path)
  --post-bytes N  размер порции upload (по умолчанию от RAM)
  --route-only X  true | false — sniffing на ноде
  --remark X      название Host в панели
  --expert        спрашивать тонкие параметры транспорта без лишнего вопроса
  --skip-validate не гонять xray -test перед заливкой
  --no-install    не копировать себя в /usr/local/bin и не делать ярлык srus
  --dry-run       ничего не менять, только показать
  -y, --yes       не переспрашивать
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tune) ACTIONS+=(tune) ;;
    --firewall) ACTIONS+=(firewall) ;;
    --certs) ACTIONS+=(certs) ;;
    --xhttp) ACTIONS+=(xhttp) ;;
    --print) ACTIONS+=(print) ;;
    --postflight) ACTIONS+=(postflight) ;;
    --rollback) ACTIONS+=(rollback) ;;
    --all) ACTIONS+=(tune firewall certs xhttp) ;;
    --domain) DOMAIN="$2"; shift ;;
    --port) XHTTP_PORT="$2"; shift ;;
    --path) XHTTP_PATH="$2"; shift ;;
    --tag) INBOUND_TAG="$2"; shift ;;
    --panel-url) PANEL_URL="$2"; shift ;;
    --token) PANEL_TOKEN="$2"; shift ;;
    --cookie) PANEL_COOKIE="$2"; shift ;;
    --api-key) PANEL_API_KEY="$2"; shift ;;
    --panel-ip) PANEL_IP="$2"; shift ;;
    --profile) PROFILE_NAME="$2"; shift ;;
    --node) NODE_NAME="$2"; shift ;;
    --squad) SQUAD_NAME="$2"; shift ;;
    --scope) API_SCOPE="$2"; shift ;;
    --cert-dir) CERT_DIR="$2"; shift ;;
    --tune-profile) TUNE_PROFILE="$2"; shift ;;
    --mode) XHTTP_MODE="$2"; shift ;;
    --alpn) XHTTP_ALPN="$2"; shift ;;
    --path-style) PATH_STYLE="$2"; shift ;;
    --post-bytes) POST_BYTES="$2"; shift ;;
    --route-only) ROUTE_ONLY="$2"; shift ;;
    --remark) HOST_REMARK="$2"; shift ;;
    --expert) EXPERT=1 ;;
    --skip-validate) SKIP_VALIDATE=1 ;;
    --no-install) NO_INSTALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (--help)" ;;
  esac
  shift
done

# ------------------------------------------------------------- запуск ----

# Кладёт себя в /usr/local/bin под родным именем и вешает короткий ярлык srus.
# Симлинк, а не alias: работает в любой оболочке, под sudo и в cron,
# и не требует перечитывать ~/.bashrc.
self_install() {
  (( NO_INSTALL )) && return 0
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || src=$(readlink -f "$0" 2>/dev/null)
  [[ -f "$src" ]] || return 0

  if [[ "$src" != "$SELF_PATH" ]]; then
    # через временный файл + mv: rename атомарен и не рвёт уже запущенный процесс
    if cp "$src" "$SELF_PATH.tmp" 2>/dev/null && chmod 755 "$SELF_PATH.tmp" 2>/dev/null \
       && mv -f "$SELF_PATH.tmp" "$SELF_PATH" 2>/dev/null; then
      ok "Установлен: $SELF_PATH"
    else
      rm -f "$SELF_PATH.tmp" 2>/dev/null
      return 0
    fi
  else
    chmod 755 "$SELF_PATH" 2>/dev/null
  fi

  if [[ -L "$SHORTCUT" ]]; then
    # ярлык есть — молча освежаем цель на случай переезда
    ln -sfn "$SELF_PATH" "$SHORTCUT" 2>/dev/null
  elif [[ -e "$SHORTCUT" ]]; then
    warn "$SHORTCUT занят посторонним файлом — ярлык не трогаю"
  else
    if ln -s "$SELF_PATH" "$SHORTCUT" 2>/dev/null; then
      hr
      ok "Готово. Дальше запускай откуда угодно одной командой:"
      printf '    %ssrus%s\n' "$C_G" "$C_N"
      hr
    fi
  fi
}

load_conf
need_root
touch "$LOG" 2>/dev/null; chmod 600 "$LOG" 2>/dev/null || true
self_install
_tolog "=== запуск v$VERSION: ${ACTIONS[*]:-меню} ==="

ensure_deps
if (( ${#ACTIONS[@]} == 0 )); then
  menu
else
  for a in "${ACTIONS[@]}"; do
    case "$a" in
      tune) do_tune ;;
      firewall) do_firewall ;;
      certs) do_certs ;;
      xhttp) do_xhttp_api ;;
      print) do_xhttp_print ;;
      postflight) do_postflight ;;
      rollback) do_rollback ;;
    esac
  done
  save_conf
fi

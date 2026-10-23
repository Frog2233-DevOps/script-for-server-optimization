#!/usr/bin/env bash
#
# bootstrap.sh v1.2.0 — первичная настройка свежего Ubuntu-сервера (24.04 / 26.04)
#
# Универсальная база для удобной и безопасной работы (не заточена под VPN).
# v1.2.0 — второй независимый аудит: W1-W8 исправлены, см. пометки [FIX] в коде.
#
# Требования: Ubuntu 24.04/26.04, root, systemd (в контейнере часть шагов пропускается),
#             >= 1.5 ГБ свободного места на /, рабочий DNS/доступ к зеркалам apt.
#
# Запуск от root, одна команда, без флагов — скрипт сам спросит публичный ключ.
# Для production: скачай файл, сверь sha256, запусти локально.
#
# Повторный запуск безопасен. Лог: /var/log/bootstrap.log (0600). Бэкапы: /var/backups/bootstrap/
#
set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.2.0"
LOG="/var/log/bootstrap.log"
LOCK="/run/bootstrap.lock"
BACKUP_DIR="/var/backups/bootstrap/$(date +%Y%m%d-%H%M%S)"

# ───────────────────────── настройки (env или флаги) ─────────────────────────
NEW_USER="${NEW_USER:-super}"
SSH_PORT="${SSH_PORT:-49500}"
SSH_KEYS="${SSH_KEYS:-}"
KEYS_FILE="${KEYS_FILE:-}"
GITHUB_USER="${GITHUB_USER:-}"
OPEN_PORTS="${OPEN_PORTS-}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
TIMEZONE="${TIMEZONE:-}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-0}"
BLOCK_PING="${BLOCK_PING:-0}"
SET_UMASK="${SET_UMASK:-0}"
AUTOREMOVE="${AUTOREMOVE:-0}"
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
LOCK_ROOT="${LOCK_ROOT:-1}"
DO_REBOOT="${DO_REBOOT:-0}"
FORCE="${FORCE:-0}"
ALLOW_USERS=""    # [FIX W2] заполняется в шаге 12
KEY_ARGS=()

usage() {
  cat <<EOF
bootstrap.sh v$SCRIPT_VERSION — первичная настройка Ubuntu 24.04 / 26.04 (от root)
Ключи (нужен хотя бы один источник; иначе — из /root/.ssh/authorized_keys):
  -k, --key "ssh-ed25519 AAAA..."   публичный ключ (можно несколько раз)
      --keys-file FILE              файл с ключами
      --github USER                 ключи с https://github.com/USER.keys
Основное:
  -u, --user NAME        имя пользователя (по умолчанию: super)
  -p, --ssh-port N       порт SSH (по умолчанию: 49500)
      --ports "LIST"     доп. порты ufw: "80/tcp 443/tcp 6000:6010/tcp"
                         (без протокола будет открыт ТОЛЬКО tcp — принцип наименьшего доступа)
      --swap SIZE        512M, 2G, 0 = выключить (по умолчанию 2G)
      --timezone TZ      например Europe/Moscow
      --hostname NAME    сменить hostname
      --packages "LIST"  доп. пакеты apt
Опции:
      --docker           docker.io + docker-compose-v2
      --block-ping       не отвечать на ping (только IPv4 echo-request)
      --umask            umask 0077 для пользователя
      --autoremove       apt autoremove --purge
      --no-upgrade       без apt full-upgrade
      --no-lock-root     не блокировать пароль root
      --reboot           перезагрузка через 1 минуту в конце
      --force            не падать на неподдержанной Ubuntu / системном пользователе
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    -k|--key)        KEY_ARGS+=("${2:?нужен ключ}"); shift 2 ;;
    --keys-file)     KEYS_FILE="${2:?}"; shift 2 ;;
    --github)        GITHUB_USER="${2:?}"; shift 2 ;;
    -u|--user)       NEW_USER="${2:?}"; shift 2 ;;
    -p|--ssh-port)   SSH_PORT="${2:?}"; shift 2 ;;
    --ports)         OPEN_PORTS="${2-}"; shift 2 ;;
    --swap)          SWAP_SIZE="${2:?}"; shift 2 ;;
    --timezone)      TIMEZONE="${2:?}"; shift 2 ;;
    --hostname)      NEW_HOSTNAME="${2:?}"; shift 2 ;;
    --packages)      EXTRA_PACKAGES="${2-}"; shift 2 ;;
    --docker)        INSTALL_DOCKER=1; shift ;;
    --block-ping)    BLOCK_PING=1; shift ;;
    --umask)         SET_UMASK=1; shift ;;
    --autoremove)    AUTOREMOVE=1; shift ;;
    --no-upgrade)    SKIP_UPGRADE=1; shift ;;
    --no-lock-root)  LOCK_ROOT=0; shift ;;
    --reboot)        DO_REBOOT=1; shift ;;
    --force)         FORCE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ───────────────────── root, лог, блокировка, временные файлы ─────────────────
[[ $EUID -eq 0 ]] || { echo "Запускай от root (sudo -i, потом bash bootstrap.sh ...)" >&2; exit 1; }

install -d -m 755 "$(dirname "$LOG")"
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

ts()   { date '+%F %T'; }
log()  { printf '%s [+] %s\n' "$(ts)" "$*"; }
warn() { printf '%s [!] %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s [x] %s\n' "$(ts)" "$*" >&2; exit 1; }
step() { printf '\n%s ══ %s\n' "$(ts)" "$*"; }

exec 9>"$LOCK"
flock -n 9 || die "Уже запущен другой экземпляр bootstrap.sh (lock: $LOCK)"

WORKDIR="$(mktemp -d)"

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-bootstrap.conf
SOCK_DROPIN=/etc/systemd/system/ssh.socket.d/zz-bootstrap-port.conf
SSHD_PREV="$WORKDIR/sshd-dropin.prev"; SOCK_PREV="$WORKDIR/sock-dropin.prev"
SSHD_HAD=0; SOCK_HAD=0; SSH_TXN=0; SSH_CUT=0; SOCKET_MODE=0
OLD_SSH_PORTS=()

HAS_SYSTEMD=0; [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
svc() {
  if ((HAS_SYSTEMD)); then systemctl "$@"
  else warn "systemd не запущен (chroot/контейнер) — пропускаю: systemctl $*"; fi
}

restart_ssh() {
  ((HAS_SYSTEMD)) || { warn "systemd нет — ssh не перезапускаю"; return 0; }
  systemctl daemon-reload || return 1
  if ((SOCKET_MODE)); then systemctl restart ssh.socket || return 1; fi
  systemctl reload-or-restart ssh || systemctl restart ssh || return 1
}

rollback_ssh() {
  ((SSH_TXN)) || return 0
  SSH_TXN=0
  warn "Откатываю SSH-конфиг"
  if ((SSHD_HAD)); then cp -a "$SSHD_PREV" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
  if ((SOCK_HAD)); then cp -a "$SOCK_PREV" "$SOCK_DROPIN"; else rm -f "$SOCK_DROPIN"; fi
  if ((SSH_CUT)); then
    restart_ssh || warn "ssh не перезапустился после отката — проверь вручную. В ufw открыты порты: ${OLD_SSH_PORTS[*]:-22}"
  fi
}

on_exit() {
  local rc=$?
  trap - ERR
  rollback_ssh || true
  rm -rf "$WORKDIR"
  exit "$rc"
}
trap on_exit EXIT
trap 'die "Прервано сигналом"' INT TERM
trap 'die "Упало на строке $LINENO (команда: $BASH_COMMAND). Поправь и запусти заново. Лог: $LOG"' ERR

# ───────────────────────────────── утилиты ───────────────────────────────────
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
          -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3)
apt_run() { apt-get "${APT_OPTS[@]}" "$@" </dev/null; }

apt_install() {
  local ok=() p
  for p in "$@"; do
    if apt-cache show --no-all-versions "$p" &>/dev/null; then ok+=("$p")
    else warn "пакета $p нет в этом релизе — пропускаю"; fi
  done
  if ((${#ok[@]})); then apt_run install "${ok[@]}"; fi
  return 0
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  install -d -m 700 "$BACKUP_DIR"
  cp -a "$f" "$BACKUP_DIR/$(printf '%s' "${f#/}" | tr / _)"
}

WRITE_CHANGED=0
write_file() {
  local path="$1" mode="$2" tmp
  WRITE_CHANGED=0
  tmp="$(mktemp -p "$WORKDIR")"; cat >"$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  backup_file "$path"
  install -m "$mode" -o root -g root "$tmp" "$path"; rm -f "$tmp"
  WRITE_CHANGED=1
  log "записал $path"
}

# [FIX W5] идемпотентное открытие порта ufw (ufw сам дубли не дедуплицирует)
ufw_allow() {
  local rule="$1" cmt="${2:-bootstrap}"
  if ufw status 2>/dev/null | grep -Eq "^${rule//./\\.}([[:space:]]|$)"; then
    log "ufw: $rule уже открыт — пропускаю"
  else
    ufw allow "$rule" comment "$cmt" >/dev/null && log "ufw allow $rule ($cmt)"
  fi
}

os_field() { ( . /etc/os-release; printf '%s' "${!1:-}" ); }

valid_port_num() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

port_in_array() {
  local x="$1" e; shift
  for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done
  return 1
}

detect_ssh_ports() {
  local c=""
  mkdir -p /run/sshd
  {
    if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '$1=="port"{print $2}'; fi
    if ((HAS_SYSTEMD)); then
      systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | tr -dc '0-9\n'
    fi
    c="${SSH_CONNECTION:-}"
    if [[ -n "$c" ]]; then echo "${c##* }"; fi
  } | grep -E '^[0-9]+$' | sort -un || true
}

# ───────────────────────────── проверка окружения ────────────────────────────
step "0/12 Проверки"
[[ -r /etc/os-release ]] || die "нет /etc/os-release"
OS_ID="$(os_field ID)"; OS_VER="$(os_field VERSION_ID)"; OS_CODENAME="$(os_field VERSION_CODENAME)"
[[ "$OS_ID" == ubuntu ]] || die "Это не Ubuntu (ID=${OS_ID:-?})"
case "$OS_VER" in
  24.04|26.04) log "Ubuntu $OS_VER (${OS_CODENAME:-?}) — поддерживается" ;;
  *) if ((FORCE)); then warn "Ubuntu ${OS_VER:-?} не тестировалась, продолжаю (--force)"
     else die "Поддерживаются 24.04 и 26.04, у тебя ${OS_VER:-?}. Можно --force на свой риск."; fi ;;
esac

[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Некорректное имя пользователя: $NEW_USER"
[[ "$NEW_USER" != root ]] || die "Пользователь не должен быть root"
valid_port_num "$SSH_PORT" || die "Некорректный SSH-порт: $SSH_PORT"
SSH_PORT=$((10#$SSH_PORT))
[[ "$SWAP_SIZE" =~ ^(0|[1-9][0-9]*[MG])$ ]] || die "SWAP_SIZE должен быть 0, 512M, 2G и т.п."
read -r -a OPEN_ARR <<<"$OPEN_PORTS"
for p in "${OPEN_ARR[@]}"; do
  if [[ "$p" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]]; then
    valid_port_num "${BASH_REMATCH[1]}" || die "Некорректный порт в --ports: $p"
  elif [[ "$p" =~ ^([0-9]{1,5}):([0-9]{1,5})/(tcp|udp)$ ]]; then
    pa="${BASH_REMATCH[1]}"; pb="${BASH_REMATCH[2]}"
    if ! { valid_port_num "$pa" && valid_port_num "$pb" && ((10#$pa <= 10#$pb)); }; then
      die "Некорректный диапазон в --ports: $p"
    fi
  else
    die "Некорректный порт в --ports: $p (диапазон допустим только с /tcp или /udp)"
  fi
done
if [[ -n "$TIMEZONE" && ! -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then die "Нет такой таймзоны: $TIMEZONE"; fi
if [[ -n "$NEW_HOSTNAME" ]] && ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,60}[a-zA-Z0-9])?$ ]]; then
  die "Некорректный hostname: $NEW_HOSTNAME"
fi

if id "$NEW_USER" &>/dev/null; then
  U_UID="$(id -u "$NEW_USER")"; U_SHELL="$(getent passwd "$NEW_USER" | cut -d: -f7)"
  if ((U_UID < 1000)) && ! ((FORCE)); then die "$NEW_USER — системный аккаунт (UID $U_UID). Выбери другое имя (или --force)."; fi
  case "$U_SHELL" in
    */nologin|*/false) if ! ((FORCE)); then die "У $NEW_USER shell=$U_SHELL — войти нельзя. Выбери другое имя (или --force)."; fi ;;
  esac
fi

VIRT="$(systemd-detect-virt -c 2>/dev/null || true)"; [[ "$VIRT" == none ]] && VIRT=""
if [[ -n "$VIRT" ]]; then warn "Контейнер ($VIRT): swap и часть sysctl будут пропущены"; fi

FREE_ROOT_MB="$(df -Pk / | awk 'NR==2{print int($4/1024)}')"
((FREE_ROOT_MB >= 1536)) || die "Мало места на / (${FREE_ROOT_MB}M, нужно >= 1536M)"
getent hosts archive.ubuntu.com >/dev/null 2>&1 || warn "archive.ubuntu.com не резолвится — apt может упасть (проверь DNS)"

if ! command -v ss >/dev/null 2>&1; then log "ставлю iproute2 (нужен ss)"; apt_run update; apt_run install iproute2; fi
if ((HAS_SYSTEMD)) && systemctl is-enabled ssh.socket &>/dev/null; then SOCKET_MODE=1; fi
mapfile -t OLD_SSH_PORTS < <(detect_ssh_ports)
if ! port_in_array "$SSH_PORT" "${OLD_SSH_PORTS[@]}" && ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
  die "Порт $SSH_PORT уже занят другим сервисом — выбери другой (--ssh-port)"
fi
log "текущие порты SSH: ${OLD_SSH_PORTS[*]:-не определены (будет 22)}; новый: $SSH_PORT"

# ───────────────────────────────── SSH-ключи ─────────────────────────────────
step "1/12 Собираю SSH-ключи"
KEYS_TMP="$(mktemp -p "$WORKDIR")"

if ! command -v ssh-keygen >/dev/null 2>&1; then
  log "ставлю openssh-client для проверки ключей"; apt_run update; apt_run install openssh-client
fi

prompt_for_key() {
  { : </dev/tty; } 2>/dev/null || return 1
  local line one tries=0
  {
    printf '\n┌─ Вставь свой ПУБЛИЧНЫЙ SSH-ключ (одна строка из .pub: ssh-ed25519 AAAA... ) и нажми Enter.\n'
    printf '└─ Пустой ввод — взять ключи из /root/.ssh/authorized_keys (если они есть).\n'
  } >/dev/tty
  while ((tries < 3)); do
    printf '> ' >/dev/tty
    IFS= read -r line </dev/tty || return 1
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && return 1
    if [[ "$line" == *"PRIVATE KEY"* ]]; then
      warn "Это ПРИВАТНЫЙ ключ! Нужен публичный (файл .pub) — приватный никому и никуда не вставляй."
      tries=$((tries+1)); continue
    fi
    one="$(mktemp -p "$WORKDIR")"; printf '%s\n' "$line" >"$one"
    if ssh-keygen -l -f "$one" >/dev/null 2>&1; then
      rm -f "$one"; printf '%s\n' "$line" >>"$KEYS_TMP"; return 0
    fi
    rm -f "$one"; warn "Не похоже на публичный ключ, попробуй ещё раз"
    tries=$((tries+1))
  done
  return 1
}
KEYTYPE_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$'

if [[ -n "$SSH_KEYS" ]]; then printf '%s\n' "$SSH_KEYS" >>"$KEYS_TMP"; fi
for k in "${KEY_ARGS[@]}"; do printf '%s\n' "$k" >>"$KEYS_TMP"; done
if [[ -n "$KEYS_FILE" ]]; then
  [[ -r "$KEYS_FILE" ]] || die "Не могу прочитать $KEYS_FILE"
  cat "$KEYS_FILE" >>"$KEYS_TMP"; echo >>"$KEYS_TMP"
fi
if [[ -n "$GITHUB_USER" ]]; then
  [[ "$GITHUB_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "Некорректное имя GitHub-пользователя"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 20 "https://github.com/${GITHUB_USER}.keys" >>"$KEYS_TMP" \
    || die "Не смог скачать ключи github.com/$GITHUB_USER"
  echo >>"$KEYS_TMP"
  # [FIX W9] жёсткое предупреждение: аккаунт GitHub = потенциальный root на сервере
  warn "Добавлены ключи с github.com/$GITHUB_USER. Кто контролирует этот аккаунт — тот получает root."
  warn "ОБЯЗАТЕЛЬНО сверь отпечатки ниже с ssh-keygen -lf твоего .pub и со страницей github.com/$GITHUB_USER.keys!"
fi
grep -Eq '^\s*[^#[:space:]]' "$KEYS_TMP" || prompt_for_key || true

if ! grep -Eq '^\s*[^#[:space:]]' "$KEYS_TMP" && [[ -s /root/.ssh/authorized_keys ]]; then
  warn "Ключи не переданы — беру из /root/.ssh/authorized_keys. Сверь отпечатки ниже!"
  # [FIX W1] срезаем ТОЛЬКО опасные обёртки (command=, environment=);
  #          from= и прочие ограничения СОХРАНЯЕМ — иначе ключ root начнёт работать с любого IP
  awk -v re="$KEYTYPE_RE" '
    /^[[:space:]]*(#|$)/ {next}
    {
      n=split($0, f, /[[:space:]]+/)
      ki=0
      for (i=1;i<=n;i++) if (f[i] ~ re) {ki=i; break}
      if (!ki) next
      opts=""
      for (i=1;i<ki;i++) {
        if (f[i] ~ /^(command|environment)=/) continue
        opts = opts (opts=="" ? "" : " ") f[i]
      }
      s=""
      for (i=ki;i<=n;i++) s = s (s=="" ? "" : " ") f[i]
      print (opts=="" ? s : opts " " s)
    }' /root/.ssh/authorized_keys >>"$KEYS_TMP"
fi

if grep -q 'PRIVATE KEY' "$KEYS_TMP"; then die "В ключах лежит ПРИВАТНЫЙ ключ. Нужен публичный (.pub)!"; fi
CLEAN_KEYS="$(mktemp -p "$WORKDIR")"
grep -Ev '^\s*(#|$)' "$KEYS_TMP" | sed 's/\r$//' | awk '!seen[$0]++' >"$CLEAN_KEYS" || true

N_KEYS=0
while IFS= read -r line; do
  one="$(mktemp -p "$WORKDIR")"; printf '%s\n' "$line" >"$one"
  ssh-keygen -l -f "$one" >/dev/null 2>&1 || { rm -f "$one"; die "Невалидный публичный ключ: ${line:0:60}..."; }
  rm -f "$one"; N_KEYS=$((N_KEYS+1))
done <"$CLEAN_KEYS"
((N_KEYS > 0)) || die "Нет ни одного ключа. Запусти заново и вставь ключ (или дай --key / --github / --keys-file)."
log "Валидных ключей: $N_KEYS. Отпечатки (проверь, что это ТВОИ ключи):"
{ ssh-keygen -l -f "$CLEAN_KEYS" 2>/dev/null || true; } | while IFS= read -r fp; do log "  $fp"; done

# ──────────────────────────── обновление и пакеты ────────────────────────────
step "2/12 Обновление системы"
# [FIX W7] жёсткий обрыв (SIGKILL/питание) посреди прошлого apt оставляет
#          полунастроенный dpkg — Lock::Timeout этого не лечит
if dpkg --audit 2>/dev/null | grep -q .; then
  warn "найдены недонастроенные пакеты — выполняю dpkg --configure -a"
  dpkg --configure -a || die "dpkg --configure -a не справился — почини пакеты вручную"
fi
apt_run update
if ((SKIP_UPGRADE)); then log "full-upgrade пропущен (--no-upgrade)"; else apt_run full-upgrade; fi
if ((AUTOREMOVE)); then apt_run autoremove --purge; else log "autoremove пропущен (включается --autoremove)"; fi

step "3/12 Базовые пакеты"
apt_run install sudo iproute2 openssh-server ufw fail2ban python3-systemd unattended-upgrades ca-certificates curl
# shellcheck disable=SC2086
apt_install wget gnupg git jq unzip zip nano vim tmux htop net-tools dnsutils lsof $EXTRA_PACKAGES

write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if [[ -f /etc/default/motd-news ]]; then backup_file /etc/default/motd-news; sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news; fi
if command -v pro >/dev/null 2>&1; then pro config set apt_news=false >/dev/null 2>&1 || true; fi

# ───────────────────────── hostname / timezone ─────────────────────────────
step "4/12 Hostname и время"
if [[ -n "$NEW_HOSTNAME" ]]; then
  if ((HAS_SYSTEMD)); then hostnamectl set-hostname "$NEW_HOSTNAME"; else hostname "$NEW_HOSTNAME"; echo "$NEW_HOSTNAME" >/etc/hostname; fi
  log "hostname = $NEW_HOSTNAME"
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    write_file /etc/cloud/cloud.cfg.d/99-bootstrap-hostname.cfg 0644 <<'EOF'
preserve_hostname: true
EOF
  fi
fi
HN="$(hostname)"
if ! grep -Eq "(^|[[:space:]])${HN//./\\.}([[:space:]]|$)" /etc/hosts; then
  backup_file /etc/hosts
  # [FIX W6] заменяем старую строку 127.0.1.1 вместо бесконечного дописывания
  if grep -Eq '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s|^127\.0\.1\.1[[:space:]]+.*|127.0.1.1 $HN|" /etc/hosts
  else
    echo "127.0.1.1 $HN" >>/etc/hosts
  fi
  log "127.0.1.1 $HN в /etc/hosts"
fi
if [[ -n "$TIMEZONE" ]]; then
  if ((HAS_SYSTEMD)); then timedatectl set-timezone "$TIMEZONE"; else ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; fi
  log "таймзона = $TIMEZONE"
fi
if ((HAS_SYSTEMD)); then
  timedatectl set-ntp true 2>/dev/null || warn "не удалось включить NTP — проверь время: timedatectl"
fi

# ───────────────────────── пользователь, ключи, sudo ─────────────────────────
step "5/12 Пользователь $NEW_USER"
if id "$NEW_USER" &>/dev/null; then
  log "пользователь $NEW_USER уже есть"; usermod -aG sudo "$NEW_USER"
else
  useradd -m -s /bin/bash -G sudo "$NEW_USER"; log "создан $NEW_USER"
fi
U_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
U_GRP="$(id -gn "$NEW_USER")"
[[ "$U_HOME" == /* && -d "$U_HOME" ]] || die "Домашний каталог $NEW_USER некорректен: '$U_HOME'"
chmod go-w "$U_HOME"
install -d -m 700 -o "$NEW_USER" -g "$U_GRP" "$U_HOME/.ssh"

AK="$U_HOME/.ssh/authorized_keys"
MERGED="$(mktemp -p "$WORKDIR")"
{ if [[ -f "$AK" ]]; then cat "$AK"; fi; cat "$CLEAN_KEYS"; } | awk '!seen[$0]++' >"$MERGED"
install -m 600 -o "$NEW_USER" -g "$U_GRP" "$MERGED" "$AK"
rm -f "$MERGED" "$KEYS_TMP" "$CLEAN_KEYS"
log "authorized_keys: $(grep -c . "$AK") ключ(ей)"

SUDOERS_FILE="/etc/sudoers.d/90-bootstrap-$NEW_USER"
SUDOERS_TMP="$(mktemp -p "$WORKDIR")"
echo "$NEW_USER ALL=(ALL:ALL) NOPASSWD:ALL" >"$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null || die "sudoers-правило не прошло visudo -c"
install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"; rm -f "$SUDOERS_TMP"
if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  warn "в /etc/sudoers нет includedir — добавляю"; backup_file /etc/sudoers
  echo '@includedir /etc/sudoers.d' >>/etc/sudoers
fi
if ! visudo -c >/dev/null; then rm -f "$SUDOERS_FILE"; die "visudo -c ругается на итоговую конфигурацию — правило удалено"; fi
log "sudo NOPASSWD для $NEW_USER настроен"

if ((LOCK_ROOT)); then passwd -l root >/dev/null 2>&1 || warn "passwd -l root не удался"; fi

if ((SET_UMASK)) && ! grep -q '^umask 0077' "$U_HOME/.bashrc" 2>/dev/null; then
  echo 'umask 0077' >>"$U_HOME/.bashrc"; chown "$NEW_USER:$U_GRP" "$U_HOME/.bashrc"; log "umask 0077 добавлен"
fi

# ───────────────────────────────── firewall ──────────────────────────────────
step "6/12 UFW"
mapfile -t OLD_SSH_PORTS < <(detect_ssh_ports)
if ((${#OLD_SSH_PORTS[@]} == 0)); then OLD_SSH_PORTS=(22); fi

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw_allow "${SSH_PORT}/tcp" 'SSH'
for p in "${OLD_SSH_PORTS[@]}"; do
  if [[ "$p" != "$SSH_PORT" ]]; then
    ufw_allow "${p}/tcp" 'SSH-transition'; log "прежний порт SSH ${p} открыт — закрой после проверки"
  fi
done
for p in "${OPEN_ARR[@]}"; do
  # [FIX W8] порт без протокола — открываем ТОЛЬКО tcp (принцип наименьшего доступа)
  if [[ "$p" != */* ]]; then warn "порту '$p' не указан протокол — открываю только tcp"; p="${p}/tcp"; fi
  ufw_allow "$p" 'bootstrap'
done
if ((BLOCK_PING)) && [[ -f /etc/ufw/before.rules ]]; then
  [[ -e /etc/ufw/before.rules.bootstrap.bak ]] || cp /etc/ufw/before.rules /etc/ufw/before.rules.bootstrap.bak
  sed -i -E 's/^(-A ufw-before-input -p icmp --icmp-type echo-request) -j ACCEPT/\1 -j DROP/' /etc/ufw/before.rules
  log "ping (IPv4 echo-request) закрыт; остальной ICMP не трогаю — иначе ломается PMTUD"
fi
if ufw --force enable >/dev/null 2>&1; then log "ufw включён"
else warn "ufw не включился (нет netfilter в ядре/контейнере?) — проверь вручную!"; fi
ufw reload >/dev/null 2>&1 || true

# ───────────────────────────────── fail2ban ──────────────────────────────────
step "7/12 fail2ban"
IGNORE="127.0.0.1/8 ::1"
CLIENT_IP="${SSH_CONNECTION:-${SSH_CLIENT:-}}"; CLIENT_IP="${CLIENT_IP%% *}"
if [[ "${CLIENT_IP:-}" =~ ^[0-9a-fA-F:.]+$ ]]; then IGNORE="$IGNORE $CLIENT_IP"; fi
# [FIX W4] баним перебор и на переходных портах, пока они открыты
F2B_PORTS="$SSH_PORT"
for p in "${OLD_SSH_PORTS[@]}"; do [[ "$p" != "$SSH_PORT" ]] && F2B_PORTS="$F2B_PORTS,$p"; done
write_file /etc/fail2ban/jail.d/10-bootstrap.local 0644 <<EOF
[DEFAULT]
ignoreip = $IGNORE
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
port = $F2B_PORTS
maxretry = 5
findtime = 10m
bantime = 1h
EOF
fail2ban-client -t >/dev/null 2>&1 || { fail2ban-client -t || true; die "конфиг fail2ban невалиден"; }
svc enable fail2ban >/dev/null 2>&1 || true
svc restart fail2ban || true
if ((HAS_SYSTEMD)); then
  sleep 3
  if systemctl is-active --quiet fail2ban && fail2ban-client ping >/dev/null 2>&1; then log "fail2ban работает"
  else warn "fail2ban НЕ запустился — смотри: journalctl -u fail2ban -n 30"; fi
fi

# ─────────────────────── sysctl: BBR и сетевая оптимизация ───────────────────
step "8/12 sysctl (BBR + сеть)"
BBR_LINES=""
if [[ -z "$VIRT" ]]; then
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    BBR_LINES=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
    echo tcp_bbr | write_file /etc/modules-load.d/bbr.conf 0644
  else
    warn "BBR недоступен в этом ядре — оставляю дефолтный congestion control"
  fi
fi
RESERVED_LINE=""
if ((SSH_PORT >= 32768 && SSH_PORT <= 60999)); then
  CUR_RES="$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)"; NEW_RES="$SSH_PORT"
  if [[ -n "$CUR_RES" ]]; then
    case ",$CUR_RES," in *",$SSH_PORT,"*) NEW_RES="$CUR_RES" ;; *) NEW_RES="$CUR_RES,$SSH_PORT" ;; esac
  fi
  RESERVED_LINE="net.ipv4.ip_local_reserved_ports = $NEW_RES"
fi
write_file /etc/sysctl.d/99-bootstrap.conf 0644 <<EOF
# Managed by bootstrap.sh. Консервативный набор из Linux-Optimizer.
# W10: kernel.panic=10 — авто-перезагрузка через 10с после паники.
# На железном проде без kdump повторяющаяся паника даст boot loop — рассмотри kdump.
$BBR_LINES
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 10
kernel.panic = 10
$RESERVED_LINE
EOF
sysctl -q -p /etc/sysctl.d/99-bootstrap.conf || warn "часть sysctl не применилась (контейнер/старое ядро) — не критично"

# ───────────────────────── лимиты, журналы, ротация ──────────────────────────
step "9/12 Лимиты, journald, logrotate"
write_file /etc/security/limits.d/99-bootstrap.conf 0644 <<'EOF'
*    soft nofile 65536
*    hard nofile 1048576
root soft nofile 65536
root hard nofile 1048576
EOF
write_file /etc/systemd/system.conf.d/99-bootstrap.conf 0644 <<'EOF'
[Manager]
DefaultLimitNOFILE=1024:1048576
EOF
if ((WRITE_CHANGED)); then svc daemon-reexec 2>/dev/null || true; fi

write_file /etc/systemd/journald.conf.d/99-bootstrap.conf 0644 <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF
if ((WRITE_CHANGED)); then svc restart systemd-journald || true; fi

write_file /etc/logrotate.d/bootstrap 0644 <<'EOF'
/var/log/bootstrap.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF

# ────────────────────────────────── swap ─────────────────────────────────────
step "10/12 Swap"
if [[ "$SWAP_SIZE" == 0 ]]; then log "swap отключён флагом"
elif [[ -n "$VIRT" ]]; then log "контейнер — swap пропускаю"
elif [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then log "swap уже есть — не трогаю"
elif [[ -e /swapfile ]]; then warn "/swapfile существует, но не подключён — не трогаю"
else
  MB="${SWAP_SIZE%[MG]}"
  if [[ "$SWAP_SIZE" == *G ]]; then MB=$((MB*1024)); fi
  FREE_MB="$(df -Pk / | awk 'NR==2{print int($4/1024)}')"
  if ((FREE_MB < MB + 2048)); then warn "мало места (${FREE_MB}M) — swap пропускаю"
  else
    SWAP_TMP=/swapfile.bootstrap
    rm -f "$SWAP_TMP"
    if ( umask 077; fallocate -l "${MB}M" "$SWAP_TMP" 2>/dev/null || dd if=/dev/zero of="$SWAP_TMP" bs=1M count="$MB" status=none ) \
       && chmod 600 "$SWAP_TMP" && mkswap "$SWAP_TMP" >/dev/null && mv "$SWAP_TMP" /swapfile; then
      if swapon /swapfile 2>/dev/null; then
        if ! grep -q '^/swapfile ' /etc/fstab; then backup_file /etc/fstab; echo '/swapfile none swap sw 0 0' >>/etc/fstab; fi
        log "swap ${SWAP_SIZE} создан"
      else warn "swapon не удался — удаляю файл"; rm -f /swapfile; fi
    else
      rm -f "$SWAP_TMP"; warn "не удалось создать swap — пропускаю, не критично"
    fi
  fi
fi

# ─────────────────────────────── docker (опция) ──────────────────────────────
step "11/12 Docker"
if ((INSTALL_DOCKER)); then
  DOCKER_WAS_ACTIVE=0; DOCKER_CFG_CHANGED=0
  if ((HAS_SYSTEMD)) && systemctl is-active --quiet docker 2>/dev/null; then DOCKER_WAS_ACTIVE=1; fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    DOCKER_CFG_CHANGED=$WRITE_CHANGED
  fi
  apt_run install docker.io
  apt_install docker-compose-v2
  usermod -aG docker "$NEW_USER" || warn "не удалось добавить $NEW_USER в группу docker"
  svc enable --now docker || warn "docker не стартовал"
  if ((DOCKER_CFG_CHANGED && DOCKER_WAS_ACTIVE)); then warn "docker работал — перезапускаю для daemon.json"; svc restart docker || true; fi
  warn "Docker обходит ufw для опубликованных портов (-p 8080:80 открыт всем!). Биндись на 127.0.0.1."
  warn "Группа docker применится $NEW_USER только после перелогина."
else log "пропущено (включается флагом --docker)"; fi

# ───────────────────────── SSH hardening — в самом конце ─────────────────────
step "12/12 Харденинг SSH"
# [FIX W2] не отрезаем других живых администраторов: собираем всех
#          человеческих пользователей (UID>=1000) с ключами и рабочим shell
ALLOW_USERS="$NEW_USER"
while IFS=: read -r u _ uid _ _ home shell; do
  ((uid >= 1000 && uid < 65534)) || continue
  [[ "$u" == "$NEW_USER" ]] && continue
  case "$shell" in */nologin|*/false) continue ;; esac
  if [[ -s "$home/.ssh/authorized_keys" ]]; then
    warn "найден другой пользователь с ключами: $u — добавляю в AllowUsers, иначе потеряет SSH-доступ"
    ALLOW_USERS="$ALLOW_USERS $u"
  fi
done < /etc/passwd

mkdir -p /run/sshd /etc/ssh/sshd_config.d
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  warn "в sshd_config нет Include sshd_config.d — добавляю в начало"
  backup_file /etc/ssh/sshd_config
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

if [[ -f "$SSHD_DROPIN" ]]; then cp -a "$SSHD_DROPIN" "$SSHD_PREV"; SSHD_HAD=1; fi
if [[ -f "$SOCK_DROPIN" ]]; then cp -a "$SOCK_DROPIN" "$SOCK_PREV"; SOCK_HAD=1; fi
SSH_TXN=1

PORT_LINE=""; if ((SSH_PORT != 22)); then PORT_LINE="Port $SSH_PORT"; fi
cat >"$SSHD_DROPIN" <<EOF
# Managed by bootstrap.sh
$PORT_LINE
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $ALLOW_USERS
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
ClientAliveInterval 60
ClientAliveCountMax 5
LogLevel VERBOSE
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
EOF
chmod 644 "$SSHD_DROPIN"

sshd -t || die "sshd -t не прошёл, конфиг откатывается"
EFF="$(sshd -T 2>/dev/null)"
for want in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin no' 'pubkeyauthentication yes' \
            'authenticationmethods publickey' "allowusers $ALLOW_USERS" "port $SSH_PORT"; do
  grep -qx "$want" <<<"$EFF" || die "Эффективный конфиг sshd не содержит '$want' — откат"
done
N_ALLOW="$(grep -c '^allowusers ' <<<"$EFF" || true)"
((N_ALLOW == 1)) || die "В эффективном конфиге sshd $N_ALLOW строк AllowUsers — откат"
[[ -s "$AK" ]] || die "authorized_keys пуст — не закрываю вход по паролю"
log "sshd -t ок, эффективный конфиг проверен; AllowUsers: $ALLOW_USERS"

SSH_CUT=1
if ((HAS_SYSTEMD && SOCKET_MODE)); then
  if ((SSH_PORT != 22)); then
    mkdir -p "$(dirname "$SOCK_DROPIN")"
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" >"$SOCK_DROPIN"
  else
    rm -f "$SOCK_DROPIN"
  fi
fi
restart_ssh || die "не удалось перезапустить ssh — конфиг откатывается"

if ((HAS_SYSTEMD)); then
  LISTEN_OK=0
  for _ in $(seq 1 15); do
    if ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then LISTEN_OK=1; break; fi
    sleep 1
  done
  ((LISTEN_OK)) || die "sshd не слушает порт $SSH_PORT за 15 секунд — откат"
  log "sshd слушает порт $SSH_PORT"
fi
SSH_TXN=0

# [R1] не копим снапшоты бэкапов бесконечно — оставляем последние 10
ls -1dt /var/backups/bootstrap/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf

# ───────────────────────────────────── итог ──────────────────────────────────
printf '\n%s ════════════════ ГОТОВО ════════════════\n' "$(ts)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo "SSH:       ssh -p $SSH_PORT $NEW_USER@${IP:-<ip>}"
echo "sshd:      $(sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|allowusers) ' | tr '\n' ';' || true)"
echo "BBR:       $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
echo "swap:      $(swapon --show --noheadings 2>/dev/null | awk '{print $1" "$3}' | tr '\n' ' ' || true)"
echo "ufw:       $(ufw status 2>/dev/null | head -1 || true)"
if ((HAS_SYSTEMD)) && command -v fail2ban-client >/dev/null; then
  echo "fail2ban:  $(systemctl is-active fail2ban 2>/dev/null || true) ($(fail2ban-client status 2>/dev/null | grep -i 'jail list' | sed 's/.*://;s/\s//g' || true))"
fi
# [FIX W3] скрипт не может проверить, что ключ подходит к твоей приватной паре —
#          поэтому перед тестом обязателен запасной доступ к серверу
warn "ПЕРЕД ТЕСТОМ убедись, что есть доступ к консоли/rescue-режиму провайдера!"
warn "НЕ закрывай эту сессию, пока в НОВОМ окне не проверишь: ssh -p $SSH_PORT $NEW_USER@${IP:-<ip>} && sudo -n true"
for p in "${OLD_SSH_PORTS[@]}"; do
  if [[ "$p" != "$SSH_PORT" ]]; then warn "После проверки закрой прежний порт: sudo ufw delete allow ${p}/tcp"; fi
done
if [[ -f /var/run/reboot-required ]]; then warn "Нужна перезагрузка (новое ядро): sudo reboot"; fi
if ((DO_REBOOT)); then
  warn "Перезагрузка через 1 минуту (--reboot). Отмена: shutdown -c"
  shutdown -r +1 "bootstrap.sh: плановая перезагрузка" || warn "shutdown не удался — перезагрузи вручную"
fi

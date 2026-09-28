#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================================
# INTERACTIVE DOCKER MAIL + LDAP LAB INSTALLER
# WSL Ubuntu / Docker Engine / OpenLDAP / Docker Mailserver / phpLDAPadmin
# / Roundcube
#
# Design goals:
#   - Safe interactive workflow; no destructive action before explicit review.
#   - Correct current configuration for docker-mailserver LDAP provisioning.
#   - Correct bootstrap handling for vegardit/openldap.
#   - Correct phpLDAPadmin v2 and Roundcube container paths/ports.
#   - Robust host-port detection including Docker-published ports.
#   - Localhost-only exposure by default for WSL lab use.
#   - Optional LDAP host publication and LAN exposure.
#   - Exact image digests/versions recorded after installation.
#   - Human-readable SETUP_SUMMARY.txt and CONFIGURATION_TABLE.md.
#
# Image policy:
#   Moving :latest tags are used by default and their resolved digest/version
#   is recorded after the pull. Pinning to explicit tags can be added later.
# ============================================================================

SCRIPT_VERSION="9.4-interactive-fixed-all-issues"
DMS_IMAGE="${DMS_IMAGE:-ghcr.io/docker-mailserver/docker-mailserver:latest}"
OPENLDAP_IMAGE="${OPENLDAP_IMAGE:-vegardit/openldap:latest}"
PHPLDAP_IMAGE="${PHPLDAP_IMAGE:-phpldapadmin/phpldapadmin:latest}"
ROUNDCUBE_IMAGE="${ROUNDCUBE_IMAGE:-roundcube/roundcubemail:latest}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

TMP_DIR="$(mktemp -d)"
DC=(docker)
DOCKER_MANUAL_MODE=0
RECREATE_PROJECT=0
HOST_BIND_ADDRESS="127.0.0.1"
PUBLISH_LDAP="0"

PROJECT_NAME=""
PROJECT_SLUG=""
PROJECT_ROOT=""
DMS_DIR=""
LDAP_DIR=""
PLA_DIR=""
ROUNDCUBE_DIR=""
SECRETS_DIR=""
DMS_ENV=""
PLA_ENV=""
LDAP_INIT_SCRIPT=""
COMPOSE_FILE=""
NETWORK_NAME=""

DOMAIN=""
MAIL_HOSTNAME=""
LDAP_ORG=""
LDAP_BASE_DN=""
LDAP_ADMIN_DN=""
LDAP_ADMIN_PASSWORD=""
POSTMASTER_EMAIL=""

ROUNDCUBE_HOST_PORT=""
PHPLDAP_HOST_PORT=""
LDAP_HOST_PORT=""
SMTP_HOST_PORT=""
IMAP_HOST_PORT=""
SMTPS_HOST_PORT=""
SUBMISSION_HOST_PORT=""
IMAPS_HOST_PORT=""

ENABLE_RSPAMD="1"
ENABLE_CLAMAV="0"
ENABLE_FAIL2BAN="1"
ENABLE_GREYLISTING="0"
ENABLE_OPENDKIM="1"
ENABLE_OPENDMARC="0"
ENABLE_POLICYD_SPF="1"
ENABLE_AMAVIS="0"
ENABLE_POSTGREY="0"
RSPAMD_GREYLISTING="0"
MOVE_SPAM_TO_JUNK="1"

LDAP_PPOLICY_MIN_LENGTH="0"
LDAP_PPOLICY_MAX_FAILURES="5"
LDAP_PPOLICY_LOCKOUT_DURATION="900"
# No character-class requirements and no disallowed characters.
LDAP_PPOLICY_PQCHECKER_RULE="0|00000000"

LDAP_CONTAINER=""
DMS_CONTAINER=""
PLA_CONTAINER=""
ROUNDCUBE_CONTAINER=""

ACCOUNTS=()
ACCOUNT_PASSWORDS=()
ACCOUNT_NAMES=()
ACCOUNT_ROLES=()
ACCOUNT_DNS=()

declare -A USED_HOST_PORTS=()

trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

on_interrupt() {
  echo
  error "Interrupted. No automatic cleanup of existing project data was performed."
  exit 130
}
trap on_interrupt INT TERM

usage() {
  cat <<'EOF_USAGE'
Usage: setup_fixed_v6.sh [--help|--version]

Interactive installer for a WSL Ubuntu mail + LDAP lab using Docker Mailserver,
vegardit/openldap, phpLDAPadmin v2, and Roundcube.

The installer intentionally remains interactive; there is no unattended mode.
EOF_USAGE
}

info()    { echo -e "${CYAN}  [i] $*${NC}"; }
success() { echo -e "${GREEN}  [OK] $*${NC}"; }
warn()    { echo -e "${YELLOW}  [!] $*${NC}"; }
error()   { echo -e "${RED}  [X] $*${NC}"; }
step()    { echo -e "\n${BOLD}${BLUE}[$1] $2${NC}"; }
divider() { echo -e "${DIM}  ----------------------------------------------------------------${NC}"; }
blank()   { echo; }

die() {
  error "$*"
  blank
  error "Setup FAILED. Existing project data was not automatically deleted after this point."
  error "Review the commands/logs above, fix the problem, and rerun the installer."
  exit 1
}

ask_default() {
  local prompt="$1" default="$2" answer
  read -r -p "  ${prompt} [${default}]: " answer
  printf '%s' "${answer:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="${2:-Y}" answer suffix
  if [[ "$default" == "Y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  while true; do
    read -r -p "  ${prompt} ${suffix}: " answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

ask_password() {
  local label="$1" p1 p2
  while true; do
    IFS= read -r -s -p "  ${label} (hidden): " p1
    echo
    [[ -n "$p1" ]] || { warn "Password cannot be empty."; continue; }
    [[ "$p1" != *$'\n'* && "$p1" != *$'\r'* ]] || { warn "Password cannot contain a line break."; continue; }
    IFS= read -r -s -p "  Confirm ${label}: " p2
    echo
    [[ "$p1" == "$p2" ]] || { warn "Passwords do not match. Try again."; continue; }
    REPLY="$p1"
    unset p2
    return 0
  done
}

confirm_phrase() {
  local prompt="$1" phrase="$2" answer
  read -r -p "  ${prompt} (type ${phrase} exactly): " answer
  [[ "$answer" == "$phrase" ]]
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\.[A-Za-z]{2,63}$ ]]
}

valid_hostname() {
  valid_domain "$1"
}

valid_mailbox_localpart() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

safe_text() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wsl_systemd_active() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == "systemd" ]]
}

container_state() {
  local name="$1"
  ${DC[@]} inspect --format '{{.State.Status}}' "$name" 2>/dev/null || printf '%s' "missing"
}

container_health() {
  local name="$1"
  ${DC[@]} inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$name" 2>/dev/null || printf '%s' "missing"
}

docker_port_holder() {
  local p="$1" line name ports
  while IFS=$'\t' read -r name ports; do
    [[ -n "$name" ]] || continue
    if printf '%s\n' "$ports" | grep -Eq "(^|[[:space:],])${HOST_BIND_ADDRESS}:${p}->"; then
      printf '%s\t%s' "$name" "$ports"
      return 0
    fi
    if printf '%s\n' "$ports" | grep -Eq "(^|[[:space:],])0\.0\.0\.0:${p}->"; then
      printf '%s\t%s' "$name" "$ports"
      return 0
    fi
    if printf '%s\n' "$ports" | grep -Eq "(^|[[:space:],]):::${p}->"; then
      printf '%s\t%s' "$name" "$ports"
      return 0
    fi
  done < <(${DC[@]} ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)
  return 1
}

project_container_holds_port() {
  local p="$1" cname line
  for cname in \
    "${LDAP_CONTAINER:-}" "${DMS_CONTAINER:-}" "${PLA_CONTAINER:-}" "${ROUNDCUBE_CONTAINER:-}"; do
    [[ -n "$cname" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if printf '%s\n' "$line" | grep -Eq "(^|[[:space:],])(127\.0\.0\.1|0\.0\.0\.0|::):${p}->"; then
        return 0
      fi
    done < <(${DC[@]} port "$cname" 2>/dev/null || true)
  done
  return 1
}

host_tcp_listening() {
  local p="$1"
  # Use a direct parse of the local LISTEN table instead of an ss expression.
  # This avoids false positives caused by ss filter parsing differences.
  ss -H -ltn 2>/dev/null | awk -v p="$p" '
    $1 == "LISTEN" {
      addr=$4
      sub(/^.*:/, "", addr)
      if (addr == p) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

port_is_already_selected() {
  local p="$1"
  [[ -n "${USED_HOST_PORTS[$p]:-}" ]]
}

port_in_use() {
  local p="$1" holder

  # An exact old project being intentionally recreated will be removed before
  # the new files are written, so reuse its ports.
  if (( RECREATE_PROJECT == 1 )) && project_container_holds_port "$p"; then
    return 1
  fi

  port_is_already_selected "$p" && return 0

  # First check real local LISTEN sockets.
  host_tcp_listening "$p" && return 0

  # Then check Docker-published ports. Docker may use kernel/NAT rules rather
  # than a userspace listener, so lsof alone is not sufficient for this check.
  holder="$(docker_port_holder "$p" || true)"
  [[ -n "$holder" ]] && return 0

  return 1
}

describe_port_conflict() {
  local p="$1" holder
  if host_tcp_listening "$p"; then
    echo "  [i] Port $p has a local TCP LISTEN socket."
    return 0
  fi
  holder="$(docker_port_holder "$p" || true)"
  if [[ -n "$holder" ]]; then
    echo "  [i] Docker is publishing port $p:"
    printf '      %s\n' "$holder"
    return 0
  fi
  echo "  [i] No Linux LISTEN socket or running Docker published-port mapping was found for $p."
}

find_free_port() {
  local start="$1" p
  p="$start"
  while (( p <= 65535 )); do
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
    ((p++))
  done
  return 1
}

choose_port() {
  local label="$1" standard="$2" fallback="$3"
  local value suggested

  value="$(ask_default "$label" "$standard")"

  while true; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
      warn "Enter a numeric TCP port." >&2
      value="$(ask_default "$label" "$standard")"
      continue
    }
    (( value >= 1 && value <= 65535 )) || {
      warn "TCP port must be between 1 and 65535." >&2
      value="$(ask_default "$label" "$standard")"
      continue
    }

    if port_in_use "$value"; then
      suggested="$(find_free_port "$fallback")" || die "No free TCP port was found."
      warn "Host TCP port $value is already in use." >&2
      describe_port_conflict "$value" >&2
      warn "Suggested free port: $suggested" >&2
      value="$(ask_default "$label" "$suggested")"
      continue
    fi

    USED_HOST_PORTS["$value"]="$label"
    printf '%s' "$value"
    return 0
  done
}

image_label_version() {
  local image="$1" out=""
  out="$(${DC[@]} image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
  [[ -n "$out" && "$out" != "<no value>" ]] && printf '%s' "$out" || printf '%s' "unknown"
}

image_digest() {
  local image="$1" out=""
  out="$(${DC[@]} image inspect "$image" \
    --format '{{join .RepoDigests "\n"}}' 2>/dev/null | head -n 1 || true)"
  [[ -n "$out" ]] && printf '%s' "$out" || printf '%s' "unknown"
}

show_banner() {
  clear 2>/dev/null || true
  echo -e "${BOLD}${BLUE}"
  echo "  +====================================================================+"
  echo "  |          INTERACTIVE DOCKER MAIL + LDAP LAB INSTALLER             |"
  echo "  |       WSL Ubuntu / Docker / OpenLDAP / DMS / PLA / Roundcube      |"
  echo "  +====================================================================+"
  echo -e "${NC}"
  echo -e "  ${DIM}Installer version : ${SCRIPT_VERSION}${NC}"
  echo -e "  ${DIM}DMS image         : ${DMS_IMAGE}${NC}"
  echo -e "  ${DIM}OpenLDAP image    : ${OPENLDAP_IMAGE}${NC}"
  echo -e "  ${DIM}phpLDAPadmin      : ${PHPLDAP_IMAGE}${NC}"
  echo -e "  ${DIM}Roundcube image   : ${ROUNDCUBE_IMAGE}${NC}"
  echo
  echo -e "  ${DIM}Safe default exposure: localhost only.${NC}"
  echo -e "  ${DIM}Port checks use local LISTEN sockets plus Docker published ports.${NC}"
  echo -e "  ${DIM}Published image versions/digests are recorded after installation.${NC}"
  blank
}

ensure_prerequisites() {
  step "1/10" "Preflight checks and Docker Engine"
  divider

  [[ -t 0 && -t 1 ]] || die "This installer requires an interactive terminal."

  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This installer expects Ubuntu; detected ${ID:-unknown}."

  sudo -v

  if grep -qi microsoft /proc/version 2>/dev/null; then
    success "WSL detected."
  else
    warn "This shell does not appear to be WSL; continuing because Ubuntu was detected."
  fi

  local missing=()
  for cmd in curl ca-certificates openssl ss awk sed ps; do
    if [[ "$cmd" == "ca-certificates" ]]; then
      dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null |
        grep -q "install ok installed" || missing+=("ca-certificates")
    else
      command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    info "Installing required host packages: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl openssl iproute2 gawk sed procps
  fi

  require_cmd sudo
  require_cmd curl
  require_cmd openssl
  require_cmd ss
  require_cmd awk
  require_cmd sed
  require_cmd ps

  if ! command -v docker >/dev/null 2>&1; then
    info "Docker CLI is not installed. Installing Docker Engine from Docker's official Ubuntu repository..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    success "Docker Engine packages installed."
  else
    success "Docker CLI detected: $(docker --version)"
  fi

  if wsl_systemd_active; then
    info "systemd is active. Enabling and starting Docker..."
    sudo systemctl enable docker >/dev/null 2>&1 || true
    sudo systemctl start docker
  else
    if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
      warn "systemd is not active in this WSL session."
      if ask_yes_no "Write /etc/wsl.conf to enable systemd for future WSL sessions?" Y; then
        sudo tee /etc/wsl.conf >/dev/null <<'EOF_WSL'
[boot]
systemd=true
EOF_WSL
        warn "WSL systemd was enabled in /etc/wsl.conf. A future `wsl --shutdown` is required for it to take effect."
      fi

      ask_yes_no "Start dockerd manually for this installation now?" Y ||
        die "Docker daemon is required."

      mkdir -p "$HOME/.docker-wsl"
      sudo nohup dockerd >"$HOME/.docker-wsl/dockerd.log" 2>&1 </dev/null &
      DOCKER_MANUAL_MODE=1
    fi
  fi

  info "Waiting for Docker daemon..."
  local ready=0
  for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  ((ready == 1)) || {
    [[ -f "$HOME/.docker-wsl/dockerd.log" ]] && tail -n 80 "$HOME/.docker-wsl/dockerd.log" || true
    die "Docker daemon did not become reachable."
  }

  if docker info >/dev/null 2>&1; then
    DC=(docker)
  else
    DC=(sudo docker)
  fi

  require_cmd docker
  if ! ${DC[@]} compose version >/dev/null 2>&1; then
    warn "Docker Compose v2 plugin is not available."
    ask_yes_no "Install docker-compose-plugin now?" Y ||
      die "Docker Compose v2 plugin is required."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
  fi
  ${DC[@]} compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 plugin is still unavailable."

  info "Docker version : $(${DC[@]} --version)"
  info "Compose version: $(${DC[@]} compose version)"
  success "Docker Engine and Docker Compose are available."
}

collect_project_and_network() {
  step "2/10" "Project, domain, LDAP identity, and network exposure"
  divider

  PROJECT_NAME="$(ask_default "Project name" "Mail + LDAP Lab")"
  [[ -n "$PROJECT_NAME" ]] || die "Project name cannot be empty."
  [[ "$PROJECT_NAME" != *$'\n'* && "$PROJECT_NAME" != *$'\r'* ]] || die "Project name cannot contain line breaks."
  printf '%s\n' "$PROJECT_NAME" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._+/-]{0,79}$' ||
    die "Project name may contain only letters, numbers, spaces, dot, underscore, and hyphen."

  PROJECT_SLUG="$(slugify "$PROJECT_NAME")"
  [[ -n "$PROJECT_SLUG" ]] || die "Could not create a safe Docker project slug."
  (( ${#PROJECT_SLUG} <= 40 )) ||
    die "Project slug is too long (${#PROJECT_SLUG} chars); shorten the project name."

  PROJECT_ROOT="$HOME/docker/$PROJECT_SLUG"
  DMS_DIR="$PROJECT_ROOT/dms"
  LDAP_DIR="$PROJECT_ROOT/ldap"
  PLA_DIR="$PROJECT_ROOT/phpldapadmin"
  ROUNDCUBE_DIR="$PROJECT_ROOT/roundcube"
  SECRETS_DIR="$PROJECT_ROOT/secrets"
  DMS_ENV="$DMS_DIR/dms.env"
  PLA_ENV="$PLA_DIR/pla.env"
  LDAP_INIT_SCRIPT="$LDAP_DIR/ldap-init.sh"
  COMPOSE_FILE="$PROJECT_ROOT/compose.yaml"
  NETWORK_NAME="${PROJECT_SLUG}-net"

  LDAP_CONTAINER="${PROJECT_SLUG}-openldap"
  DMS_CONTAINER="${PROJECT_SLUG}-mailserver"
  PLA_CONTAINER="${PROJECT_SLUG}-phpldapadmin"
  ROUNDCUBE_CONTAINER="${PROJECT_SLUG}-roundcube"

  DOMAIN="$(ask_default "Mail domain" "example.test")"
  DOMAIN="${DOMAIN,,}"
  valid_domain "$DOMAIN" || die "Invalid mail domain: $DOMAIN"
  [[ "$DOMAIN" == *.local ]] &&
    warn ".local is local/LAN oriented and is not a normal public Internet mail namespace."
  [[ "$DOMAIN" == *.test ]] &&
    info ".test is reserved for testing and is suitable for a local lab."

  MAIL_HOSTNAME="$(ask_default "Mail hostname" "mail.$DOMAIN")"
  MAIL_HOSTNAME="${MAIL_HOSTNAME,,}"
  valid_hostname "$MAIL_HOSTNAME" || die "Invalid mail hostname: $MAIL_HOSTNAME"

  LDAP_ORG="$(ask_default "LDAP organization" "Example Organization")"
  safe_text "$LDAP_ORG" || die "LDAP organization contains a line break."
  printf '%s\n' "$LDAP_ORG" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._&(),/_-]{0,119}$' ||
    die "LDAP organization contains unsupported characters."

  local admin_cn
  admin_cn="$(ask_default "LDAP admin username" "admin")"
  [[ "$admin_cn" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "LDAP admin username may only contain letters, numbers, dot, underscore, and hyphen."

  LDAP_BASE_DN=""
  local IFS='.' part
  read -r -a parts <<< "$DOMAIN"
  for part in "${parts[@]}"; do
    [[ -n "$LDAP_BASE_DN" ]] && LDAP_BASE_DN+=","
    LDAP_BASE_DN+="dc=$part"
  done
  LDAP_ADMIN_DN="uid=$admin_cn,$LDAP_BASE_DN"

  info "LDAP base DN : $LDAP_BASE_DN"
  info "LDAP admin DN: $LDAP_ADMIN_DN"
  if [[ -d "$PROJECT_ROOT" ]] ||
     ${DC[@]} network inspect "$NETWORK_NAME" >/dev/null 2>&1 ||
     ${DC[@]} container inspect "$LDAP_CONTAINER" >/dev/null 2>&1 ||
     ${DC[@]} container inspect "$DMS_CONTAINER" >/dev/null 2>&1 ||
     ${DC[@]} container inspect "$PLA_CONTAINER" >/dev/null 2>&1 ||
     ${DC[@]} container inspect "$ROUNDCUBE_CONTAINER" >/dev/null 2>&1; then

    blank
    warn "An existing project with this slug was found:"
    echo "    Path   : $PROJECT_ROOT"
    echo "    Network: $NETWORK_NAME"
    echo "    Containers: $LDAP_CONTAINER, $DMS_CONTAINER, $PLA_CONTAINER, $ROUNDCUBE_CONTAINER"
    warn "Recreate removes only these exact project containers/network and the project directory."

    confirm_phrase "Continue with destructive project replacement" "RECREATE" ||
      die "Existing project was preserved. Choose a new project name or rerun with RECREATE."
    RECREATE_PROJECT=1
  fi

  blank
  echo "  LDAP admin password: no complexity requirements; any non-empty single-line password is accepted."
  ask_password "LDAP admin password"
  LDAP_ADMIN_PASSWORD="$REPLY"
  unset REPLY

  blank
  echo -e "  ${BOLD}Network exposure${NC}"
  echo "    The secure lab default binds published ports to localhost (127.0.0.1)."
  echo "    Choose all interfaces only when you intentionally need LAN access."
  if ask_yes_no "Bind published services to all host interfaces (0.0.0.0)?" N; then
    HOST_BIND_ADDRESS="0.0.0.0"
    warn "Mail/web/LDAP ports may now be reachable from the LAN if the host firewall permits them."
  else
    HOST_BIND_ADDRESS="127.0.0.1"
  fi
}

collect_ports_and_security() {
  step "3/10" "Host ports and mail security features"
  divider

  echo "  Host port defaults:"
  echo "    SMTP        25"
  echo "    IMAP        143"
  echo "    SMTPS       465"
  echo "    Submission  587"
  echo "    IMAPS       993"
  echo "    Roundcube   8080"
  echo "    phpLDAPadmin 8081"
  echo "    LDAP        disabled by default; 1389 when published"
  blank

  ROUNDCUBE_HOST_PORT="$(choose_port "Roundcube host port" "8080" "8082")"
  PHPLDAP_HOST_PORT="$(choose_port "phpLDAPadmin host port" "8081" "8083")"

  if ask_yes_no "Publish LDAP port on the host for external ldapsearch/tools?" N; then
    PUBLISH_LDAP="1"
    LDAP_HOST_PORT="$(choose_port "LDAP host port" "1389" "13890")"
  else
    PUBLISH_LDAP="0"
    LDAP_HOST_PORT=""
  fi

  SMTP_HOST_PORT="$(choose_port "SMTP host port" "25" "2525")"
  IMAP_HOST_PORT="$(choose_port "IMAP host port" "143" "1143")"
  SMTPS_HOST_PORT="$(choose_port "SMTPS host port" "465" "5465")"
  SUBMISSION_HOST_PORT="$(choose_port "Submission host port" "587" "5587")"
  IMAPS_HOST_PORT="$(choose_port "IMAPS host port" "993" "1993")"

  # Ensure Roundcube and phpLDAPadmin ports are different
  if [[ "$ROUNDCUBE_HOST_PORT" == "$PHPLDAP_HOST_PORT" ]]; then
    warn "Roundcube and phpLDAPadmin cannot share the same host port." >&2
    PHPLDAP_HOST_PORT="$(choose_port "phpLDAPadmin host port (different from Roundcube)" "$PHPLDAP_HOST_PORT" "$(find_free_port 8083)")"
  fi

  blank
  echo -e "  ${BOLD}Mail security${NC}"
  echo "    Rspamd: spam filtering plus SPF/DKIM/DMARC checks and DKIM signing."
  echo "    ClamAV: antivirus scanning of mail; uses noticeably more RAM/CPU."
  echo "    Fail2Ban: temporarily blocks IPs that repeatedly fail authentication."
  echo "    Greylisting: temporarily delays some first-time mail senders to reduce spam."
  blank

  if ask_yes_no "Enable Rspamd? [spam + SPF/DKIM/DMARC checks]" Y; then
    ENABLE_RSPAMD="1"
  else
    ENABLE_RSPAMD="0"
  fi

  if ask_yes_no "Enable ClamAV? [antivirus; higher RAM/CPU]" N; then
    ENABLE_CLAMAV="1"
  else
    ENABLE_CLAMAV="0"
  fi

  if ask_yes_no "Enable Fail2Ban? [blocks repeated failed logins]" Y; then
    ENABLE_FAIL2BAN="1"
  else
    ENABLE_FAIL2BAN="0"
  fi

  if ask_yes_no "Enable greylisting? [temporarily delays suspicious first-time senders]" N; then
    ENABLE_GREYLISTING="1"
  else
    ENABLE_GREYLISTING="0"
  fi

  if (( ENABLE_RSPAMD == 1 )); then
    ENABLE_OPENDKIM="0"
    ENABLE_OPENDMARC="0"
    ENABLE_POLICYD_SPF="0"
    ENABLE_AMAVIS="0"
    RSPAMD_GREYLISTING="$ENABLE_GREYLISTING"
    ENABLE_POSTGREY="0"
  else
    ENABLE_OPENDKIM="1"
    ENABLE_OPENDMARC="1"
    ENABLE_POLICYD_SPF="1"
    if (( ENABLE_CLAMAV == 1 )); then
      ENABLE_AMAVIS="1"
    else
      ENABLE_AMAVIS="0"
    fi
    ENABLE_POSTGREY="$ENABLE_GREYLISTING"
    RSPAMD_GREYLISTING="0"
  fi
}

collect_accounts_and_postmaster() {
  step "4/10" "Interactive LDAP mailboxes, names, roles, and passwords"
  divider

  echo "  Roles are descriptive LDAP metadata only; they do not grant privileges."
  echo "  Password policy: no complexity requirements; any non-empty single-line password is accepted."
  blank

  local count email localpart name role password uid_num i
  while true; do
    read -r -p "  Number of email accounts [2]: " count
    count="${count:-2}"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 50 )) && break
    warn "Enter a number from 1 to 50."
  done

  ACCOUNTS=()
  ACCOUNT_PASSWORDS=()
  ACCOUNT_NAMES=()
  ACCOUNT_ROLES=()
  ACCOUNT_DNS=()

  for ((i=1; i<=count; i++)); do
    echo
    echo -e "  ${BOLD}${MAGENTA}Mailbox $i / $count${NC}"
    divider

    while true; do
      if [[ "$i" -eq 1 ]]; then
        email="$(ask_default "Email ID" "admin@$DOMAIN")"
      elif [[ "$i" -eq 2 ]]; then
        email="$(ask_default "Email ID" "manager@$DOMAIN")"
      else
        read -r -p "  Email ID (example: alice@$DOMAIN): " email
      fi

      email="${email,,}"
      valid_email "$email" || {
        warn "Use a simple valid email address."
        continue
      }
      [[ "$email" == *@$DOMAIN ]] || {
        warn "Mailbox must use the configured domain @$DOMAIN."
        continue
      }

      localpart="${email%@*}"
      valid_mailbox_localpart "$localpart" || {
        warn "Unsupported mailbox local-part. Allowed: letters, numbers, dot, underscore, hyphen."
        continue
      }

      if ((${#ACCOUNTS[@]} > 0)) &&
         printf '%s\n' "${ACCOUNTS[@]}" | grep -Fxq "$email"; then
        warn "That mailbox already exists in this wizard."
        continue
      fi
      break
    done

    name="$(ask_default "Display name" "${localpart//[._-]/ }")"
    safe_text "$name" || die "Display name contains an invalid line break."
    [[ -n "$name" ]] || die "Display name cannot be empty."

    while true; do
      role="$(ask_default "Role (User/Admin/Manager/Staff)" "User")"
      case "${role,,}" in
        user) role="User"; break ;;
        admin) role="Admin"; break ;;
        manager) role="Manager"; break ;;
        staff) role="Staff"; break ;;
        *) warn "Choose User, Admin, Manager, or Staff." ;;
      esac
    done

    ask_password "Mailbox password for $email"
    password="$REPLY"
    uid_num=$((10001+i))

    ACCOUNTS+=("$email")
    ACCOUNT_PASSWORDS+=("$password")
    ACCOUNT_NAMES+=("$name")
    ACCOUNT_ROLES+=("$role")
    ACCOUNT_DNS+=("uid=$localpart,ou=Users,$LDAP_BASE_DN")
    unset password
    success "Added $email."
  done

  POSTMASTER_EMAIL="$(ask_default "Postmaster address" "postmaster@$DOMAIN")"
  POSTMASTER_EMAIL="${POSTMASTER_EMAIL,,}"
  valid_email "$POSTMASTER_EMAIL" || die "Invalid postmaster email."
  [[ "$POSTMASTER_EMAIL" == *@$DOMAIN ]] ||
    die "Postmaster email must use the configured domain."
}

review_config() {
  step "5/10" "Final configuration review"
  divider

  echo -e "  ${BOLD}PROJECT / NETWORK${NC}"
  printf '    %-28s %s\n' "Project name" "$PROJECT_NAME"
  printf '    %-28s %s\n' "Project slug" "$PROJECT_SLUG"
  printf '    %-28s %s\n' "Project root" "$PROJECT_ROOT"
  printf '    %-28s %s\n' "Docker network" "$NETWORK_NAME"
  printf '    %-28s %s\n' "Host bind address" "$HOST_BIND_ADDRESS"
  blank

  echo -e "  ${BOLD}MAIL / LDAP${NC}"
  printf '    %-28s %s\n' "Mail domain" "$DOMAIN"
  printf '    %-28s %s\n' "Mail hostname" "$MAIL_HOSTNAME"
  printf '    %-28s %s\n' "LDAP organization" "$LDAP_ORG"
  printf '    %-28s %s\n' "LDAP base DN" "$LDAP_BASE_DN"
  printf '    %-28s %s\n' "LDAP admin DN" "$LDAP_ADMIN_DN"
  printf '    %-28s %s\n' "Postmaster" "$POSTMASTER_EMAIL"
  blank

  echo -e "  ${BOLD}PORT MAP${NC}"
  printf '    %-14s host %-7s -> container %s\n' "SMTP" "$SMTP_HOST_PORT" "25"
  printf '    %-14s host %-7s -> container %s\n' "IMAP" "$IMAP_HOST_PORT" "143"
  printf '    %-14s host %-7s -> container %s\n' "SMTPS" "$SMTPS_HOST_PORT" "465"
  printf '    %-14s host %-7s -> container %s\n' "Submission" "$SUBMISSION_HOST_PORT" "587"
  printf '    %-14s host %-7s -> container %s\n' "IMAPS" "$IMAPS_HOST_PORT" "993"
  printf '    %-14s host %-7s -> container %s\n' "Roundcube" "$ROUNDCUBE_HOST_PORT" "80"
  printf '    %-14s host %-7s -> container %s\n' "phpLDAPadmin" "$PHPLDAP_HOST_PORT" "8080"
  if (( PUBLISH_LDAP == 1 )); then
    printf '    %-14s host %-7s -> container %s\n' "LDAP" "$LDAP_HOST_PORT" "389"
  else
    printf '    %-14s %s\n' "LDAP" "not published; internal Docker access only"
  fi
  blank

  echo -e "  ${BOLD}SECURITY${NC}"
  printf '    %-28s %s\n' "Rspamd" "$ENABLE_RSPAMD"
  printf '    %-28s %s\n' "ClamAV" "$ENABLE_CLAMAV"
  printf '    %-28s %s\n' "Fail2Ban" "$ENABLE_FAIL2BAN"
  printf '    %-28s %s\n' "Greylisting requested" "$ENABLE_GREYLISTING"
  printf '    %-28s %s\n' "OpenDKIM" "$ENABLE_OPENDKIM"
  printf '    %-28s %s\n' "OpenDMARC" "$ENABLE_OPENDMARC"
  printf '    %-28s %s\n' "policyd-spf" "$ENABLE_POLICYD_SPF"
  printf '    %-28s %s\n' "Amavis" "$ENABLE_AMAVIS"
  printf '    %-28s %s\n' "Postgrey" "$ENABLE_POSTGREY"
  printf '    %-28s %s\n' "Rspamd greylisting" "$RSPAMD_GREYLISTING"
  printf '    %-28s %s\n' "Move spam to Junk" "$MOVE_SPAM_TO_JUNK"
  printf '    %-28s %s\n' "LDAP password policy" "No complexity requirements; non-empty single-line passwords"
  blank

  echo -e "  ${BOLD}MAILBOXES${NC}"
  local i
  for ((i=0; i<${#ACCOUNTS[@]}; i++)); do
    printf '    %-40s role=%-8s DN=%s\n' \
      "${ACCOUNTS[$i]}" "${ACCOUNT_ROLES[$i]}" "${ACCOUNT_DNS[$i]}"
  done

  blank
  echo -e "  ${YELLOW}Passwords are never printed or written to SETUP_SUMMARY.txt.${NC}"
  echo -e "  ${YELLOW}The PLA environment file contains the LDAP bind password and is mode 600.${NC}"
  blank

  ask_yes_no "Proceed with this exact configuration?" N ||
    { warn "Setup cancelled. No project files were deleted or created."; exit 0; }
}

pull_images() {
  step "6/10" "Pull container images and render configuration"
  divider

  info "Pulling selected images before project data is changed..."
  ${DC[@]} pull "$DMS_IMAGE"
  ${DC[@]} pull "$OPENLDAP_IMAGE"
  ${DC[@]} pull "$PHPLDAP_IMAGE"
  ${DC[@]} pull "$ROUNDCUBE_IMAGE"

  local img version digest
  for img in "$DMS_IMAGE" "$OPENLDAP_IMAGE" "$PHPLDAP_IMAGE" "$ROUNDCUBE_IMAGE"; do
    version="$(image_label_version "$img")"
    digest="$(image_digest "$img")"
    echo "    $(printf '%-58s' "$img") version=$version"
    echo "      digest: $digest"
  done

  render_project_files
  validate_compose
}

remove_old_project() {
  info "Removing exact project containers/network after explicit RECREATE confirmation..."

  local cname
  for cname in "$LDAP_CONTAINER" "$DMS_CONTAINER" "$PLA_CONTAINER" "$ROUNDCUBE_CONTAINER"; do
    if ${DC[@]} container inspect "$cname" >/dev/null 2>&1; then
      ${DC[@]} rm -f "$cname" >/dev/null 2>&1 || true
    fi
  done

  if ${DC[@]} network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    local others
    others="$(${DC[@]} network inspect "$NETWORK_NAME" \
      --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    if echo "$others" | grep -vE "^($LDAP_CONTAINER|$DMS_CONTAINER|$PLA_CONTAINER|$ROUNDCUBE_CONTAINER)$" |
       grep -q .; then
      echo "$others"
      die "The exact project network is shared with another container; refusing to remove it."
    fi
    ${DC[@]} network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi

  if [[ -d "$PROJECT_ROOT" ]]; then
    # LDAP/DMS bind mounts are often populated by root inside the container.
    # The project was explicitly confirmed for RECREATE, so remove this exact
    # project directory with sudo rather than failing on root-owned files.
    sudo rm -rf -- "$PROJECT_ROOT"
  fi
}

render_project_files() {
  if (( RECREATE_PROJECT == 1 )); then
    remove_old_project
  fi

  mkdir -p \
    "$DMS_DIR/data" "$DMS_DIR/state" "$DMS_DIR/logs" "$DMS_DIR/config" \
    "$LDAP_DIR/data" "$LDAP_DIR/config" "$LDAP_DIR/backups" \
    "$PLA_DIR/storage" "$PLA_DIR/logs" \
    "$ROUNDCUBE_DIR/db" "$ROUNDCUBE_DIR/config" "$SECRETS_DIR"
  chmod 700 "$PROJECT_ROOT" "$SECRETS_DIR"
  # phpLDAPadmin (Laravel) needs to write sessions and logs into these dirs.
  chmod 777 "$PLA_DIR/storage" "$PLA_DIR/logs"

  printf '%s' "$LDAP_ADMIN_PASSWORD" >"$SECRETS_DIR/ldap-admin-password"
  chmod 600 "$SECRETS_DIR/ldap-admin-password"

  # DMS SSL_TYPE=self-signed requires cert files to be pre-placed in the config
  # directory.  Generate a self-signed certificate for the mail hostname now so
  # the mailserver container starts successfully on first boot.
  local ssl_dir="$DMS_DIR/config/ssl"
  mkdir -p "$ssl_dir/demoCA"
  info "Generating self-signed TLS certificate for $MAIL_HOSTNAME..."
  openssl req -newkey rsa:4096 -x509 -days 3650 -nodes \
    -subj "/CN=$MAIL_HOSTNAME/O=$LDAP_ORG/C=XX" \
    -addext "subjectAltName=DNS:$MAIL_HOSTNAME,DNS:$DOMAIN" \
    -keyout "$ssl_dir/$MAIL_HOSTNAME-key.pem" \
    -out  "$ssl_dir/$MAIL_HOSTNAME-cert.pem" \
    2>/dev/null || die "Failed to generate self-signed TLS certificate."
  cp "$ssl_dir/$MAIL_HOSTNAME-cert.pem" "$ssl_dir/demoCA/cacert.pem"
  chmod 600 "$ssl_dir/$MAIL_HOSTNAME-key.pem"
  success "Self-signed TLS certificate written to $ssl_dir/"

  # vegardit/openldap documents LDAP_INIT_ROOT_USER_PW as the bootstrap
  # password variable and INIT_SH_FILE as a sourced initialization hook.
  # Keep the password in a dedicated read-only file on the host and let the
  # init hook load that exact value into LDAP_INIT_ROOT_USER_PW.  This avoids
  # putting the plaintext password in the Compose environment.
  cat >"$LDAP_INIT_SCRIPT" <<'EOF_LDAP_INIT'
#!/bin/sh
set -eu
PW_FILE="/run/openldap-bootstrap/ldap-admin-password"

if [ ! -r "$PW_FILE" ]; then
  echo "OpenLDAP bootstrap password file is missing or unreadable: $PW_FILE" >&2
  exit 1
fi

LDAP_INIT_ROOT_USER_PW="$(cat "$PW_FILE")"

[ -n "$LDAP_INIT_ROOT_USER_PW" ] || {
  echo "OpenLDAP bootstrap password file is empty: $PW_FILE" >&2
  exit 1
}

# Check for carriage return.  Note: $(printf '\n') is an empty string after
# command-substitution stripping, so we must NOT use it in a case pattern
# (it would produce *""* which matches every string).  Use printf + head
# instead to detect embedded newlines safely.
case "$LDAP_INIT_ROOT_USER_PW" in
  *"$(printf '\r')"*)
    echo "OpenLDAP bootstrap password contains a carriage return; this is not supported." >&2
    exit 1
    ;;
esac
_pw_check="${LDAP_INIT_ROOT_USER_PW}SENTINEL"
_pw_first=$(printf '%s' "$_pw_check" | head -n 1)
if [ "$_pw_first" != "$_pw_check" ]; then
  echo "OpenLDAP bootstrap password contains a line break; this is not supported." >&2
  exit 1
fi
unset _pw_check _pw_first

export LDAP_INIT_ROOT_USER_PW
EOF_LDAP_INIT
  chmod 700 "$LDAP_INIT_SCRIPT"

  cat >"$DMS_ENV" <<EOF_DMS
OVERRIDE_HOSTNAME=$MAIL_HOSTNAME
POSTMASTER_ADDRESS=$POSTMASTER_EMAIL

ACCOUNT_PROVISIONER=LDAP
LDAP_SERVER_HOST=ldap://openldap:389
LDAP_SEARCH_BASE=ou=Users,$LDAP_BASE_DN
LDAP_BIND_DN=$LDAP_ADMIN_DN
LDAP_BIND_PW__FILE=/run/secrets/ldap-admin-password

LDAP_QUERY_FILTER_DOMAIN=(mail=*@%s)
LDAP_QUERY_FILTER_USER=(&(objectClass=inetOrgPerson)(mail=%s))
LDAP_QUERY_FILTER_ALIAS=(|)
LDAP_QUERY_FILTER_GROUP=(|)
LDAP_QUERY_FILTER_SENDERS=(&(objectClass=inetOrgPerson)(mail=%s))
SPOOF_PROTECTION=1

DOVECOT_URIS=ldap://openldap:389
DOVECOT_BASE=ou=Users,$LDAP_BASE_DN
DOVECOT_DN=$LDAP_ADMIN_DN
DOVECOT_DNPASS__FILE=/run/secrets/ldap-admin-password
DOVECOT_LDAP_VERSION=3
DOVECOT_AUTH_BIND=yes
DOVECOT_USER_FILTER=(&(objectClass=inetOrgPerson)(mail=%{user}))
DOVECOT_PASS_FILTER=(&(objectClass=inetOrgPerson)(mail=%{user}))
DOVECOT_PASS_ATTRS=uid=user,userPassword=password
DOVECOT_USER_ATTRS==uid=5000,=gid=5000,=home=/var/mail/%{ldap:uid},=mail=maildir:~/Maildir

ENABLE_SASLAUTHD=1
SASLAUTHD_MECHANISMS=rimap
SASLAUTHD_MECH_OPTIONS=127.0.0.1

POSTFIX_INET_PROTOCOLS=ipv4
DOVECOT_INET_PROTOCOLS=ipv4
DOVECOT_DISABLE_PLAINTEXT_AUTH=no

POSTFIX_MAILBOX_SIZE_LIMIT=0
POSTFIX_MESSAGE_SIZE_LIMIT=52428800
ONE_DIR=1
TLS_LEVEL=modern
SSL_TYPE=self-signed

ENABLE_OPENDKIM=$ENABLE_OPENDKIM
ENABLE_OPENDMARC=$ENABLE_OPENDMARC
ENABLE_POLICYD_SPF=$ENABLE_POLICYD_SPF
ENABLE_RSPAMD=$ENABLE_RSPAMD
ENABLE_CLAMAV=$ENABLE_CLAMAV
ENABLE_AMAVIS=$ENABLE_AMAVIS
ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN
ENABLE_POSTGREY=$ENABLE_POSTGREY
RSPAMD_GREYLISTING=$RSPAMD_GREYLISTING
ENABLE_SPAMASSASSIN=0
ENABLE_QUOTAS=0

MOVE_SPAM_TO_JUNK=$MOVE_SPAM_TO_JUNK
PERMIT_DOCKER=none

LOG_LEVEL=info
SUPERVISOR_LOGLEVEL=warn
EOF_DMS
  chmod 600 "$DMS_ENV"

  local pla_key
  pla_key="base64:$(openssl rand -base64 32 | tr -d '\n')"
  cat >"$PLA_ENV" <<EOF_PLA
APP_KEY=$pla_key
APP_URL=http://localhost:$PHPLDAP_HOST_PORT
APP_ENV=production
APP_DEBUG=false
APP_TIMEZONE=Asia/Kolkata
LOG_CHANNEL=stderr
CACHE_DRIVER=file
SESSION_DRIVER=file
SESSION_LIFETIME=120

LDAP_HOST=openldap
LDAP_PORT=389
LDAP_CONNECTION=ldap
LDAP_BASE_DN=$LDAP_BASE_DN
LDAP_USERNAME=$LDAP_ADMIN_DN
LDAP_PASSWORD=$LDAP_ADMIN_PASSWORD
LDAP_CACHE=false
LDAP_ALLOW_GUEST=false
LDAP_ALERT_ROOTDN=false
LDAP_LOGIN_ATTR=mail
LDAP_LOGIN_ATTR_DESC=Email
LDAP_LOGIN_OBJECTCLASS=inetOrgPerson,posixAccount
LDAP_NAME=LDAP Server ($PROJECT_NAME)
EOF_PLA
  chmod 600 "$PLA_ENV"

  # Custom Roundcube config is read from /var/roundcube/config by the official
  # image. It is deliberately read-only because the image writes its own root
  # config into the application docroot during startup.
  cat >"$ROUNDCUBE_DIR/config/zz-self-signed.inc.php" <<'EOF_RC'
<?php
$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];

$config['smtp_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];

$config['product_name'] = 'Mail + LDAP Lab';
EOF_RC
  chmod 644 "$ROUNDCUBE_DIR/config/zz-self-signed.inc.php"

  cat >"$PROJECT_ROOT/.gitignore" <<'EOF_GITIGNORE'
secrets/
*.env
dms/data/
dms/state/
dms/logs/
ldap/data/
ldap/config/
ldap/backups/
phpldapadmin/storage/
phpldapadmin/logs/
roundcube/db/
EOF_GITIGNORE
  chmod 600 "$PROJECT_ROOT/.gitignore"

  local ldap_ports_yaml=""
  if (( PUBLISH_LDAP == 1 )); then
    ldap_ports_yaml="$(printf 'ports:\n      - \"%s:%s:389\"' "$HOST_BIND_ADDRESS" "$LDAP_HOST_PORT")"
  fi

  cat >"$COMPOSE_FILE" <<EOF_COMPOSE
services:
  openldap:
    image: $OPENLDAP_IMAGE
    container_name: $LDAP_CONTAINER
    hostname: ldap.$DOMAIN
    restart: unless-stopped
    environment:
      LDAP_INIT_ORG_DN: "$LDAP_BASE_DN"
      LDAP_INIT_ORG_NAME: "$LDAP_ORG"
      LDAP_INIT_ROOT_USER_DN: "$LDAP_ADMIN_DN"
      INIT_SH_FILE: "/mnt/ldap-init.sh"
      LDAP_INIT_RFC2307BIS_SCHEMA: "0"
      LDAP_INIT_ALLOW_CONFIG_ACCESS: "false"
      LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE: "false"
      LDAP_INIT_PPOLICY_PW_MIN_LENGTH: "$LDAP_PPOLICY_MIN_LENGTH"
      LDAP_INIT_PPOLICY_MAX_FAILURES: "$LDAP_PPOLICY_MAX_FAILURES"
      LDAP_INIT_PPOLICY_LOCKOUT_DURATION: "$LDAP_PPOLICY_LOCKOUT_DURATION"
      LDAP_PPOLICY_PQCHECKER_RULE: "$LDAP_PPOLICY_PQCHECKER_RULE"
      LDAP_BACKUP_TIME: "02:00"
      LDAP_BACKUP_FILE: "/var/lib/ldap/data.ldif"
    volumes:
      - ./ldap/data:/var/lib/ldap
      - ./ldap/config:/etc/ldap/slapd.d
      - ./ldap/backups:/var/lib/ldap-backups
      - ./secrets/ldap-admin-password:/run/openldap-bootstrap/ldap-admin-password:ro
      - ./ldap/ldap-init.sh:/mnt/ldap-init.sh:ro
      - /etc/localtime:/etc/localtime:ro
    $ldap_ports_yaml
    healthcheck:
      # Health means slapd is accepting LDAP TCP connections.  Administrator
      # credentials are verified explicitly after the service is healthy,
      # so a password mismatch cannot masquerade as a service-start failure.
      test:
        - CMD-SHELL
        - >-
          bash -c 'exec 3<>/dev/tcp/127.0.0.1/389; exec 3>&-; exec 3<&-'
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 15s
    networks:
      - mailnet

  mailserver:
    image: $DMS_IMAGE
    container_name: $DMS_CONTAINER
    hostname: $MAIL_HOSTNAME
    restart: unless-stopped
    env_file:
      - ./dms/dms.env
    secrets:
      - ldap-admin-password
    depends_on:
      openldap:
        condition: service_healthy
    ports:
      - "${HOST_BIND_ADDRESS}:${SMTP_HOST_PORT}:25"
      - "${HOST_BIND_ADDRESS}:${IMAP_HOST_PORT}:143"
      - "${HOST_BIND_ADDRESS}:${SMTPS_HOST_PORT}:465"
      - "${HOST_BIND_ADDRESS}:${SUBMISSION_HOST_PORT}:587"
      - "${HOST_BIND_ADDRESS}:${IMAPS_HOST_PORT}:993"
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    security_opt:
      - no-new-privileges:false
    volumes:
      - ./dms/data:/var/mail
      - ./dms/state:/var/mail-state
      - ./dms/logs:/var/log/mail
      - ./dms/config:/tmp/docker-mailserver
      - /etc/localtime:/etc/localtime:ro
    networks:
      mailnet:
        aliases:
          - $MAIL_HOSTNAME

  phpldapadmin:
    image: $PHPLDAP_IMAGE
    container_name: $PLA_CONTAINER
    restart: unless-stopped
    user: "33:33"
    env_file:
      - ./phpldapadmin/pla.env
    ports:
      - "${HOST_BIND_ADDRESS}:${PHPLDAP_HOST_PORT}:8080"
    volumes:
      - ./phpldapadmin/storage:/app/storage/framework/sessions
      - ./phpldapadmin/logs:/app/storage/logs
      - /etc/localtime:/etc/localtime:ro
    networks:
      - mailnet

  roundcube:
    image: $ROUNDCUBE_IMAGE
    container_name: $ROUNDCUBE_CONTAINER
    restart: unless-stopped
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: "ssl://$MAIL_HOSTNAME"
      ROUNDCUBEMAIL_DEFAULT_PORT: "993"
      ROUNDCUBEMAIL_SMTP_SERVER: "tls://$MAIL_HOSTNAME"
      ROUNDCUBEMAIL_SMTP_PORT: "587"
      ROUNDCUBEMAIL_USERNAME_DOMAIN: "$DOMAIN"
      ROUNDCUBEMAIL_SKIN: "elastic"
      ROUNDCUBEMAIL_PLUGINS: "archive,zipdownload"
      ROUNDCUBEMAIL_DB_TYPE: "sqlite"
    ports:
      - "${HOST_BIND_ADDRESS}:${ROUNDCUBE_HOST_PORT}:80"
    volumes:
      - ./roundcube/db:/var/roundcube/db
      - ./roundcube/config:/var/roundcube/config:ro
      - /etc/localtime:/etc/localtime:ro
    networks:
      - mailnet

secrets:
  ldap-admin-password:
    file: ./secrets/ldap-admin-password

networks:
  mailnet:
    name: $NETWORK_NAME
    driver: bridge
EOF_COMPOSE

  # Rebuild the summary tables after files are rendered.
  write_configuration_table
}

validate_compose() {
  local err="$TMP_DIR/compose-validation.err"
  if ! ${DC[@]} compose -f "$COMPOSE_FILE" config -q 2>"$err"; then
    error "Docker Compose configuration validation failed."
    sed -n '1,160p' "$err" || true
    die "Fix the configuration validation error above."
  fi
  success "Docker Compose configuration validated."

  [[ -s "$SECRETS_DIR/ldap-admin-password" ]] ||
    die "OpenLDAP bootstrap password file is missing or empty: $SECRETS_DIR/ldap-admin-password"

  grep -q 'INIT_SH_FILE: "/mnt/ldap-init.sh"' "$COMPOSE_FILE" ||
    die "OpenLDAP initialization hook is missing INIT_SH_FILE."
  grep -q './secrets/ldap-admin-password:/run/openldap-bootstrap/ldap-admin-password:ro' "$COMPOSE_FILE" ||
    die "OpenLDAP bootstrap password file is not mounted at the expected container path."
  grep -q 'LDAP_PPOLICY_PQCHECKER_RULE: "0|00000000"' "$COMPOSE_FILE" ||
    die "OpenLDAP password-quality checker rule is not configured for unrestricted passwords."
  grep -q 'LDAP_INIT_PPOLICY_PW_MIN_LENGTH: "0"' "$COMPOSE_FILE" ||
    die "OpenLDAP minimum password length is not configured as 0."

  success "OpenLDAP bootstrap hook and unrestricted password policy are configured."

wait_for_ldap() {
  local state health
  for _ in $(seq 1 90); do
    state="$(container_state "$LDAP_CONTAINER")"
    health="$(container_health "$LDAP_CONTAINER")"
    if [[ "$state" == "running" && "$health" == "healthy" ]]; then
      break
    fi
    [[ "$state" == "exited" || "$state" == "dead" ]] && return 1
    sleep 2
  done

  info "Waiting for OpenLDAP initialization to complete..."
  for _ in $(seq 1 60); do
    if ${DC[@]} exec -T "$LDAP_CONTAINER" sh -c 'ldapwhoami -x -H ldap://127.0.0.1:389 -D "$1" -y /run/openldap-bootstrap/ldap-admin-password' sh "$LDAP_ADMIN_DN" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}


  if ! wait_for_ldap; then
    ${DC[@]} logs --tail 180 "$LDAP_CONTAINER" || true
    die "OpenLDAP did not become healthy."
  fi
  success "OpenLDAP is healthy."

  cat >"$ous" <<EOF_OU
dn: ou=Users,$LDAP_BASE_DN
objectClass: top
objectClass: organizationalUnit
ou: Users

dn: ou=Groups,$LDAP_BASE_DN
objectClass: top
objectClass: organizationalUnit
ou: Groups
EOF_OU

  ${DC[@]} cp "$ous" "$LDAP_CONTAINER:/tmp/mail-ous.ldif"

  local out rc=0
  out="$(${DC[@]} exec -T "$LDAP_CONTAINER" sh -c \
    'ldapadd -x -H ldap://127.0.0.1:389 -D "$1" -y /run/secrets/ldap-admin-password -f /tmp/mail-ous.ldif' \
    sh "$LDAP_ADMIN_DN" 2>&1)" || rc=$?

  if [[ "$rc" -ne 0 ]] && ! echo "$out" | grep -qi 'Already exists'; then
    echo "$out"
    die "Could not create LDAP Users/Groups organizational units."
  fi
  success "LDAP Users and Groups OUs are ready."

  local ldif="$TMP_DIR/mailboxes.ldif"
  : >"$ldif"

  cat >>"$ldif" <<EOF_GROUP
dn: cn=mailusers,ou=Groups,$LDAP_BASE_DN
objectClass: top
objectClass: posixGroup
cn: mailusers
gidNumber: 5000
EOF_GROUP

  local i email uid name role uid_num dn given sn hash
  for ((i=0; i<${#ACCOUNTS[@]}; i++)); do
    email="${ACCOUNTS[$i]}"
    uid="${email%@*}"
    name="${ACCOUNT_NAMES[$i]}"
    role="${ACCOUNT_ROLES[$i]}"
    uid_num=$((10001+i))
    dn="${ACCOUNT_DNS[$i]}"
    given="${name%% *}"
    sn="${name##* }"
    [[ -n "$given" ]] || given="$uid"
    [[ -n "$sn" ]] || sn="$uid"

    info "Hashing mailbox password inside the LDAP container: $email"
    hash="$(${DC[@]} exec -T "$LDAP_CONTAINER" \
      slappasswd -h '{SSHA}' -s "${ACCOUNT_PASSWORDS[$i]}" 2>/dev/null)" ||
      die "Could not generate LDAP password hash for $email."
    [[ -n "$hash" ]] || die "LDAP password hash is empty for $email."

    cat >>"$ldif" <<EOF_USER

dn: $dn
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
objectClass: posixAccount
cn: $name
sn: $sn
givenName: $given
displayName: $name
uid: $uid
uidNumber: $uid_num
gidNumber: 5000
homeDirectory: /var/mail/$uid
loginShell: /usr/sbin/nologin
mail: $email
employeeType: $role
description: Mailbox role: $role
userPassword: $hash
EOF_USER
  done

  ${DC[@]} cp "$ldif" "$LDAP_CONTAINER:/tmp/mailboxes.ldif"
  info "Adding LDAP mailbox entries..."

  out="$(${DC[@]} exec -T "$LDAP_CONTAINER" sh -c \
    'ldapadd -x -H ldap://127.0.0.1:389 -D "$1" -y /run/secrets/ldap-admin-password -f /tmp/mailboxes.ldif' \
    sh "$LDAP_ADMIN_DN" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "$out"
    die "LDAP mailbox creation failed."
  fi
  success "LDAP mailbox entries created."

  local members="$TMP_DIR/mailusers-members.ldif"
  {
    echo "dn: cn=mailusers,ou=Groups,$LDAP_BASE_DN"
    echo "changetype: modify"
    echo "add: memberUid"
    for ((i=0; i<${#ACCOUNTS[@]}; i++)); do
      echo "memberUid: ${ACCOUNTS[$i]%%@*}"
    done
  } >"$members"

  ${DC[@]} cp "$members" "$LDAP_CONTAINER:/tmp/mailusers-members.ldif"
  ${DC[@]} exec -T "$LDAP_CONTAINER" sh -c \
    'ldapmodify -x -H ldap://127.0.0.1:389 -D "$1" -y /run/secrets/ldap-admin-password -f /tmp/mailusers-members.ldif' \
    sh "$LDAP_ADMIN_DN" >/dev/null 2>&1 || true

  info "LDAP mailbox list:"
  ${DC[@]} exec -T "$LDAP_CONTAINER" sh -c \
    'ldapsearch -x -LLL -H ldap://127.0.0.1:389 -D "$1" -y /run/secrets/ldap-admin-password -b "$2" "(objectClass=inetOrgPerson)" uid mail employeeType dn' \
    sh "$LDAP_ADMIN_DN" "ou=Users,$LDAP_BASE_DN" 2>/dev/null |
    grep -E '^(dn|uid|mail|employeeType):' | sed 's/^/    /' || true

  success "LDAP provisioning complete."
}

wait_for_running() {
  local cname="$1" seconds="${2:-120}" state elapsed=0
  while (( elapsed < seconds )); do
    state="$(container_state "$cname")"
    [[ "$state" == "running" ]] && return 0
    [[ "$state" == "exited" || "$state" == "dead" ]] && return 1
    sleep 2
    elapsed=$((elapsed+2))
  done
  return 1
}

start_mail_and_web() {
  step "8/10" "Start Docker Mailserver, generate DKIM, and start web interfaces"
  divider

  info "Starting Docker Mailserver..."
  ${DC[@]} compose -f "$COMPOSE_FILE" up -d mailserver

  if ! wait_for_running "$DMS_CONTAINER" 180; then
    ${DC[@]} logs --tail 220 "$DMS_CONTAINER" || true
    die "Docker Mailserver did not remain running."
  fi
  success "Docker Mailserver container is running."

  info "Generating DMS DKIM key for $DOMAIN..."
  ${DC[@]} exec -T "$DMS_CONTAINER" setup config dkim domain "$DOMAIN" \
    >/dev/null 2>"$TMP_DIR/dkim.err" || {
      cat "$TMP_DIR/dkim.err" || true
      ${DC[@]} logs --tail 120 "$DMS_CONTAINER" || true
      die "DMS DKIM key generation failed."
    }

  ${DC[@]} compose -f "$COMPOSE_FILE" restart mailserver >/dev/null
  sleep 10
  [[ "$(container_state "$DMS_CONTAINER")" == "running" ]] ||
    die "DMS failed after DKIM restart."
  success "DMS DKIM key generated and mailserver restarted."

  info "Starting phpLDAPadmin and Roundcube..."
  ${DC[@]} compose -f "$COMPOSE_FILE" up -d phpldapadmin roundcube

  wait_for_running "$PLA_CONTAINER" 120 || {
    ${DC[@]} logs --tail 160 "$PLA_CONTAINER" || true
    die "phpLDAPadmin did not start."
  }
  wait_for_running "$ROUNDCUBE_CONTAINER" 120 || {
    ${DC[@]} logs --tail 160 "$ROUNDCUBE_CONTAINER" || true
    die "Roundcube did not start."
  }

  success "phpLDAPadmin and Roundcube containers are running."
}

tcp_port_test() {
  local p="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}

http_test() {
  local port="$1" code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

verify_stack() {
  step "9/10" "Verify LDAP, Dovecot authentication, web UIs, and published ports"
  divider

  local i email password auth_output auth_ok=0

  for ((i=0; i<${#ACCOUNTS[@]}; i++)); do
    email="${ACCOUNTS[$i]}"
    password="${ACCOUNT_PASSWORDS[$i]}"
    auth_output="$(${DC[@]} exec -T "$DMS_CONTAINER" \
      doveadm auth test "$email" "$password" 2>&1 || true)"
    if echo "$auth_output" | grep -qi 'auth succeeded'; then
      echo -e "    ${GREEN}[OK]${NC} Dovecot LDAP authentication: $email"
      auth_ok=$((auth_ok+1))
    else
      echo -e "    ${YELLOW}[--]${NC} Authentication not confirmed for $email"
      echo "        $auth_output"
    fi
  done

  if ${DC[@]} exec -T "$DMS_CONTAINER" doveadm user "${ACCOUNTS[0]}" >/dev/null 2>&1; then
    success "Dovecot LDAP userdb lookup succeeded."
  else
    warn "Dovecot LDAP userdb lookup was not confirmed."
  fi

  echo
  echo -e "  ${BOLD}HTTP checks${NC}"
  if http_test "$ROUNDCUBE_HOST_PORT"; then
    success "Roundcube HTTP endpoint responds on http://127.0.0.1:$ROUNDCUBE_HOST_PORT/"
  else
    warn "Roundcube HTTP check did not return a 2xx/3xx status."
  fi

  if http_test "$PHPLDAP_HOST_PORT"; then
    success "phpLDAPadmin HTTP endpoint responds on http://127.0.0.1:$PHPLDAP_HOST_PORT/"
  else
    warn "phpLDAPadmin HTTP check did not return a 2xx/3xx status."
  fi

  echo
  echo -e "  ${BOLD}Published TCP ports${NC}"
  local p label
  local entry port label
  for entry in \
    "$SMTP_HOST_PORT SMTP" \
    "$IMAP_HOST_PORT IMAP" \
    "$SMTPS_HOST_PORT SMTPS" \
    "$SUBMISSION_HOST_PORT Submission" \
    "$IMAPS_HOST_PORT IMAPS" \
    "$ROUNDCUBE_HOST_PORT Roundcube" \
    "$PHPLDAP_HOST_PORT phpLDAPadmin"; do
    port="${entry%% *}"
    label="${entry#* }"
    if tcp_port_test "$port"; then
      echo -e "    ${GREEN}[OK]${NC} $label host port $port"
    else
      echo -e "    ${YELLOW}[--]${NC} $label host port $port did not accept TCP"
    fi
  done

  if (( PUBLISH_LDAP == 1 )); then
    if tcp_port_test "$LDAP_HOST_PORT"; then
      echo -e "    ${GREEN}[OK]${NC} LDAP host port $LDAP_HOST_PORT"
      exec 3<&- 2>/dev/null || true
    else
      echo -e "    ${YELLOW}[--]${NC} LDAP host port $LDAP_HOST_PORT did not accept TCP"
    fi
  fi

  echo
  echo -e "  ${BOLD}Container status${NC}"
  ${DC[@]} compose -f "$COMPOSE_FILE" ps

  local dkim_pub="$DMS_DIR/config/opendkim/keys/$DOMAIN/mail.txt"
  [[ -f "$dkim_pub" ]] && success "DKIM DNS TXT material exists: $dkim_pub" ||
    warn "Expected DKIM DNS TXT file was not found: $dkim_pub"

  echo
  echo -e "  ${BOLD}Authentication result:${NC} $auth_ok / ${#ACCOUNTS[@]} mailbox passwords confirmed by Dovecot"
}

write_configuration_table() {
  local table="$PROJECT_ROOT/CONFIGURATION_TABLE.md"
  cat >"$table" <<EOF_TABLE
# Mail + LDAP Lab Configuration

Generated: $(date --iso-8601=seconds)

## Core configuration

| Feature | Value |
|---|---|
| Installer | $SCRIPT_VERSION |
| Project | $PROJECT_NAME |
| Slug | $PROJECT_SLUG |
| Project root | $PROJECT_ROOT |
| Docker network | $NETWORK_NAME |
| Host bind address | $HOST_BIND_ADDRESS |
| Mail domain | $DOMAIN |
| Mail hostname | $MAIL_HOSTNAME |
| Postmaster | $POSTMASTER_EMAIL |
| LDAP organization | $LDAP_ORG |
| LDAP base DN | $LDAP_BASE_DN |
| LDAP admin DN | $LDAP_ADMIN_DN |
| Mailbox base DN | ou=Users,$LDAP_BASE_DN |
| LDAP groups OU | ou=Groups,$LDAP_BASE_DN |

## Host ports

| Service | Host address | Host port | Container port | Purpose |
|---|---|---:|---:|---|
| SMTP | $HOST_BIND_ADDRESS | $SMTP_HOST_PORT | 25 | SMTP server-to-server |
| IMAP | $HOST_BIND_ADDRESS | $IMAP_HOST_PORT | 143 | IMAP |
| SMTPS | $HOST_BIND_ADDRESS | $SMTPS_HOST_PORT | 465 | SMTP over TLS |
| Submission | $HOST_BIND_ADDRESS | $SUBMISSION_HOST_PORT | 587 | Authenticated SMTP submission |
| IMAPS | $HOST_BIND_ADDRESS | $IMAPS_HOST_PORT | 993 | IMAP over TLS |
| Roundcube | $HOST_BIND_ADDRESS | $ROUNDCUBE_HOST_PORT | 80 | Webmail |
| phpLDAPadmin | $HOST_BIND_ADDRESS | $PHPLDAP_HOST_PORT | 8080 | LDAP web admin |
| LDAP | $HOST_BIND_ADDRESS | ${LDAP_HOST_PORT:-not-published} | 389 | LDAP client access (optional) |

## Images

| Component | Image | Resolved version | Image digest/reference |
|---|---|---|---|
| Docker Mailserver | $DMS_IMAGE | $(image_label_version "$DMS_IMAGE") | $(image_digest "$DMS_IMAGE") |
| OpenLDAP | $OPENLDAP_IMAGE | $(image_label_version "$OPENLDAP_IMAGE") | $(image_digest "$OPENLDAP_IMAGE") |
| phpLDAPadmin | $PHPLDAP_IMAGE | $(image_label_version "$PHPLDAP_IMAGE") | $(image_digest "$PHPLDAP_IMAGE") |
| Roundcube | $ROUNDCUBE_IMAGE | $(image_label_version "$ROUNDCUBE_IMAGE") | $(image_digest "$ROUNDCUBE_IMAGE") |

## Security / filtering

| Feature | Setting | Effective behavior |
|---|---|---|
| Rspamd | $ENABLE_RSPAMD | Spam filtering plus SPF/DKIM/DMARC checks and DKIM signing |
| ClamAV | $ENABLE_CLAMAV | Antivirus scanning when enabled |
| Fail2Ban | $ENABLE_FAIL2BAN | Temporary bans for repeated authentication abuse |
| Greylisting | $ENABLE_GREYLISTING | Uses Rspamd greylisting when Rspamd=1; otherwise Postgrey |
| OpenDKIM | $ENABLE_OPENDKIM | Legacy DKIM milter; disabled when Rspamd is enabled |
| OpenDMARC | $ENABLE_OPENDMARC | Legacy DMARC milter when Rspamd is disabled |
| policyd-spf | $ENABLE_POLICYD_SPF | Legacy SPF service when Rspamd is disabled |
| Amavis | $ENABLE_AMAVIS | Enabled for ClamAV without Rspamd |
| Postgrey | $ENABLE_POSTGREY | Legacy greylisting when Rspamd is disabled |
| Rspamd greylisting | $RSPAMD_GREYLISTING | Greylisting inside Rspamd |
| Move spam to Junk | $MOVE_SPAM_TO_JUNK | Route detected spam to Junk |
| Spoof protection | 1 | Sender identity restricted to authenticated mailbox |
| PERMIT_DOCKER | none | Docker network is not trusted as an unauthenticated relay |
| LDAP password minimum length | $LDAP_PPOLICY_MIN_LENGTH | No minimum-length requirement |
| LDAP pqChecker rule | $LDAP_PPOLICY_PQCHECKER_RULE | No uppercase/lowercase/digit/special requirements; no disallowed characters |

## LDAP / Dovecot integration

| Setting | Value |
|---|---|
| ACCOUNT_PROVISIONER | LDAP |
| LDAP server URI | ldap://openldap:389 |
| LDAP search base | ou=Users,$LDAP_BASE_DN |
| LDAP bind DN | $LDAP_ADMIN_DN |
| Dovecot LDAP URI | ldap://openldap:389 |
| Dovecot base | ou=Users,$LDAP_BASE_DN |
| Dovecot user filter | (&(objectClass=inetOrgPerson)(mail=%{user})) |
| Dovecot password verification | LDAP authentication bind |
| Dovecot mailbox UID | 5000 |
| Dovecot mailbox GID | 5000 |
| Mail storage | /var/mail/\<uid\>/Maildir |

## Web access

| Interface | Local URL | Login identity |
|---|---|---|
| Roundcube | http://localhost:$ROUNDCUBE_HOST_PORT/ | Mailbox email + mailbox password |
| phpLDAPadmin | http://localhost:$PHPLDAP_HOST_PORT/ | LDAP login attribute: mail |

## TLS

| Service | Configuration |
|---|---|
| DMS TLS | self-signed |
| Roundcube IMAP | SSL/TLS to $MAIL_HOSTNAME:993 |
| Roundcube SMTP | STARTTLS to $MAIL_HOSTNAME:587 |
| Roundcube certificate validation | Disabled for this local self-signed lab |
| Public production TLS | Use a real certificate instead of this lab setting |

## Files

| Purpose | Path |
|---|---|
| Compose | $COMPOSE_FILE |
| DMS env | $DMS_ENV |
| phpLDAPadmin env | $PLA_ENV |
| LDAP bootstrap | INIT_SH_FILE loads LDAP_INIT_ROOT_USER_PW from the read-only bootstrap file |
| LDAP admin secret | $SECRETS_DIR/ldap-admin-password |
| DMS config directory | $DMS_DIR/config/ |
| Mail data | $DMS_DIR/data/ |
| Mail state | $DMS_DIR/state/ |
| Mail logs | $DMS_DIR/logs/ |
| LDAP data | $LDAP_DIR/data/ |
| LDAP config | $LDAP_DIR/config/ |
| LDAP backups | $LDAP_DIR/backups/ |
| Roundcube DB | $ROUNDCUBE_DIR/db/ |
| Roundcube custom config | $ROUNDCUBE_DIR/config/zz-self-signed.inc.php |
| Deployment summary | $PROJECT_ROOT/SETUP_SUMMARY.txt |

## Common commands

    cd "$PROJECT_ROOT"
    ${DC[*]} compose ps
    ${DC[*]} compose logs --tail 100 mailserver
    ${DC[*]} compose logs --tail 100 openldap
    ${DC[*]} compose logs --tail 100 roundcube
    ${DC[*]} compose logs --tail 100 phpldapadmin
    ${DC[*]} compose restart mailserver
    ${DC[*]} exec "$DMS_CONTAINER" doveadm auth test <mailbox> <password>
    ${DC[*]} exec "$LDAP_CONTAINER" ldapsearch -x -LLL -H ldap://127.0.0.1:389 -D "$LDAP_ADMIN_DN" -W -b "ou=Users,$LDAP_BASE_DN"
    ${DC[*]} exec "$DMS_CONTAINER" setup config dkim

## DNS when using a real public domain

| Record | Example |
|---|---|
| A/AAAA | mail.$DOMAIN -> public mail server IP |
| MX | $DOMAIN -> mail.$DOMAIN |
| SPF | v=spf1 mx -all |
| DKIM | mail._domainkey.$DOMAIN from $DMS_DIR/config/opendkim/keys/$DOMAIN/mail.txt |
| DMARC | _dmarc.$DOMAIN with your chosen DMARC policy |

## Backup targets

Back up these paths together:

- $DMS_DIR/data
- $DMS_DIR/state
- $DMS_DIR/config
- $LDAP_DIR/data
- $LDAP_DIR/config
- $LDAP_DIR/backups
- $ROUNDCUBE_DIR/db
- $SECRETS_DIR

> This is a lab-oriented deployment. The self-signed TLS, local/test domains, and localhost-first network policy are not a substitute for a production mail deployment.
EOF_TABLE
  chmod 600 "$table"
}

write_summary() {
  step "10/10" "Write deployment summary and feature-use tables"
  divider

  local summary="$PROJECT_ROOT/SETUP_SUMMARY.txt"
  local dms_version dms_digest dms_release i
  dms_version="$(image_label_version "$DMS_IMAGE")"
  dms_digest="$(image_digest "$DMS_IMAGE")"
  dms_release="$(${DC[@]} exec -T "$DMS_CONTAINER" sh -c 'printf "%s" "${DMS_RELEASE:-unknown}"' 2>/dev/null || true)"
  [[ -n "$dms_release" ]] || dms_release="unknown"

  cat >"$summary" <<EOF_SUMMARY
MAIL + LDAP DEPLOYMENT SUMMARY
==============================
Generated        : $(date --iso-8601=seconds)
Installer        : $SCRIPT_VERSION
DMS_RELEASE      : $dms_release

PROJECT
-------
Project name     : $PROJECT_NAME
Project slug     : $PROJECT_SLUG
Project root     : $PROJECT_ROOT
Docker network   : $NETWORK_NAME
Host bind address: $HOST_BIND_ADDRESS

MAIL
----
Mail domain      : $DOMAIN
Mail hostname    : $MAIL_HOSTNAME
Postmaster       : $POSTMASTER_EMAIL
Provisioner      : LDAP

LDAP
----
LDAP image       : $OPENLDAP_IMAGE
Base DN          : $LDAP_BASE_DN
Admin DN         : $LDAP_ADMIN_DN
Users OU         : ou=Users,$LDAP_BASE_DN
Groups OU        : ou=Groups,$LDAP_BASE_DN
Host port        : ${LDAP_HOST_PORT:-not published}
Config access    : disabled
Anonymous Root DSE: disabled
Daily backup     : 02:00 -> $LDAP_DIR/data/data.ldif
Password policy  : unrestricted complexity; non-empty single-line passwords

MAILBOXES
---------
EOF_SUMMARY

  for ((i=0; i<${#ACCOUNTS[@]}; i++)); do
    cat >>"$summary" <<EOF_ACCOUNT
$i. Email         : ${ACCOUNTS[$i]}
   Display name  : ${ACCOUNT_NAMES[$i]}
   Role          : ${ACCOUNT_ROLES[$i]} (descriptive metadata only)
   LDAP DN       : ${ACCOUNT_DNS[$i]}
   Password      : set during installer; not saved in this file
EOF_ACCOUNT
  done

  cat >>"$summary" <<EOF_SERVICES

CONTAINERS
----------
OpenLDAP        : $LDAP_CONTAINER
Mailserver      : $DMS_CONTAINER
phpLDAPadmin    : $PLA_CONTAINER
Roundcube       : $ROUNDCUBE_CONTAINER

IMAGES
------
Docker Mailserver: $DMS_IMAGE
  version        : $dms_version
  DMS_RELEASE    : $dms_release
  digest         : $dms_digest
OpenLDAP          : $OPENLDAP_IMAGE
  version        : $(image_label_version "$OPENLDAP_IMAGE")
  digest         : $(image_digest "$OPENLDAP_IMAGE")
phpLDAPadmin      : $PHPLDAP_IMAGE
  version        : $(image_label_version "$PHPLDAP_IMAGE")
  digest         : $(image_digest "$PHPLDAP_IMAGE")
Roundcube         : $ROUNDCUBE_IMAGE
  version        : $(image_label_version "$ROUNDCUBE_IMAGE")
  digest         : $(image_digest "$ROUNDCUBE_IMAGE")

PORT MAP
--------
SMTP         : $HOST_BIND_ADDRESS:$SMTP_HOST_PORT -> container 25
IMAP         : $HOST_BIND_ADDRESS:$IMAP_HOST_PORT -> container 143
SMTPS        : $HOST_BIND_ADDRESS:$SMTPS_HOST_PORT -> container 465
Submission   : $HOST_BIND_ADDRESS:$SUBMISSION_HOST_PORT -> container 587
IMAPS        : $HOST_BIND_ADDRESS:$IMAPS_HOST_PORT -> container 993
Roundcube    : $HOST_BIND_ADDRESS:$ROUNDCUBE_HOST_PORT -> container 80
phpLDAPadmin : $HOST_BIND_ADDRESS:$PHPLDAP_HOST_PORT -> container 8080
LDAP         : $(if (( PUBLISH_LDAP == 1 )); then printf '%s:%s -> container 389' "$HOST_BIND_ADDRESS" "$LDAP_HOST_PORT"; else printf '%s' "internal Docker network only"; fi)

AUTHENTICATION
--------------
Postfix account lookup : LDAP
Dovecot user lookup    : LDAP
Dovecot password check : LDAP authentication bind
SMTP AUTH              : saslauthd -> rimap -> Dovecot
Roundcube IMAP         : SSL/TLS to $MAIL_HOSTNAME:993
Roundcube SMTP         : STARTTLS to $MAIL_HOSTNAME:587
Dovecot UID/GID        : 5000/5000

SECURITY / FEATURES
-------------------
Rspamd             : $ENABLE_RSPAMD
ClamAV             : $ENABLE_CLAMAV
Fail2Ban            : $ENABLE_FAIL2BAN
Greylisting         : $ENABLE_GREYLISTING
OpenDKIM            : $ENABLE_OPENDKIM
OpenDMARC           : $ENABLE_OPENDMARC
policyd-spf         : $ENABLE_POLICYD_SPF
Amavis             : $ENABLE_AMAVIS
Postgrey            : $ENABLE_POSTGREY
Rspamd greylisting  : $RSPAMD_GREYLISTING
Move spam to Junk  : $MOVE_SPAM_TO_JUNK
Spoof protection   : enabled
PERMIT_DOCKER      : none
TLS                : self-signed for local/lab use
Roundcube DB       : SQLite

WEB ACCESS
----------
Roundcube      : http://localhost:$ROUNDCUBE_HOST_PORT/
phpLDAPadmin   : http://localhost:$PHPLDAP_HOST_PORT/

DKIM DNS
--------
Selector         : mail
TXT material     : $DMS_DIR/config/opendkim/keys/$DOMAIN/mail.txt

FILES
-----
Compose          : $COMPOSE_FILE
DMS env          : $DMS_ENV
PLA env          : $PLA_ENV
LDAP bootstrap   : INIT_SH_FILE loads LDAP_INIT_ROOT_USER_PW from the read-only bootstrap file
LDAP bootstrap   : $SECRETS_DIR/ldap-admin-password
DMS config       : $DMS_DIR/config/
Mail data        : $DMS_DIR/data/
Mail state       : $DMS_DIR/state/
Mail logs        : $DMS_DIR/logs/
LDAP data        : $LDAP_DIR/data/
LDAP config      : $LDAP_DIR/config/
LDAP backups     : $LDAP_DIR/backups/
Roundcube DB     : $ROUNDCUBE_DIR/db/
Feature table    : $PROJECT_ROOT/CONFIGURATION_TABLE.md

NOTES
-----
1. Passwords are not saved in this file.
2. The LDAP admin password is stored in a protected bootstrap file and is also supplied as a Compose secret to services that need it.
3. The OpenLDAP image evaluates LDAP_INIT_* bootstrap variables on first initialization only.
4. The OpenLDAP bootstrap uses the documented LDAP_INIT_ROOT_USER_PW variable loaded by INIT_SH_FILE from the protected bootstrap file.
5. LDAP password policy is deliberately unrestricted for this lab: minimum length 0 and pqChecker rule 0|00000000. Blank passwords are still rejected by the installer.
6. Rspamd mode intentionally disables the legacy DKIM/DMARC/SPF/Amavis path to avoid overlapping filters.
7. Quotas remain disabled because DMS documents LDAP provisioning as incompatible with ENABLE_QUOTAS.
8. Self-signed TLS and .test/.local domains are for lab/local use. Public mail requires real DNS, firewall policy, certificates, and Internet-reachable standard mail ports.
9. The exact image digests above identify what was actually pulled for this installation.

BACKUP
------
Back up:
  $DMS_DIR/data
  $DMS_DIR/state
  $DMS_DIR/config
  $LDAP_DIR/data
  $LDAP_DIR/config
  $LDAP_DIR/backups
  $ROUNDCUBE_DIR/db
  $SECRETS_DIR

USEFUL COMMANDS
---------------
cd "$PROJECT_ROOT"
${DC[*]} compose ps
${DC[*]} compose logs --tail 100 mailserver
${DC[*]} compose logs --tail 100 openldap
${DC[*]} compose logs --tail 100 roundcube
${DC[*]} compose logs --tail 100 phpldapadmin
${DC[*]} compose restart mailserver
${DC[*]} exec "$DMS_CONTAINER" doveadm auth test <mailbox> '<password>'
${DC[*]} exec "$LDAP_CONTAINER" ldapsearch -x -LLL -H ldap://127.0.0.1:389 -D "$LDAP_ADMIN_DN" -W -b "ou=Users,$LDAP_BASE_DN"
${DC[*]} exec "$DMS_CONTAINER" setup config dkim

END
EOF_SERVICES

  chmod 600 "$summary"
  write_configuration_table
  success "Summary written: $summary"
  success "Feature configuration table: $PROJECT_ROOT/CONFIGURATION_TABLE.md"
}

final_screen() {
  local i host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host_ip="${host_ip:-127.0.0.1}"

  blank
  echo -e "${BOLD}${BLUE}"
  echo "  +====================================================================+"
  echo "  |                         SETUP COMPLETE                             |"
  echo "  +====================================================================+"
  echo -e "${NC}"
  echo -e "  ${BOLD}Project${NC} : $PROJECT_NAME"
  echo -e "  ${BOLD}Domain${NC}  : $DOMAIN"
  echo -e "  ${BOLD}Path${NC}    : $PROJECT_ROOT"
  blank

  # Configuration summary table
  echo -e "  ${BOLD}${CYAN}Configuration Summary${NC}"
  echo -e "  ${DIM}┌────────────────────────┬──────────────────────────────────────────────┐${NC}"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Project Name" "$PROJECT_NAME"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Project Slug" "$PROJECT_SLUG"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Mail Domain" "$DOMAIN"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Mail Hostname" "$MAIL_HOSTNAME"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "LDAP Base DN" "$LDAP_BASE_DN"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "LDAP Admin DN" "$LDAP_ADMIN_DN"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Network Bind" "$HOST_BIND_ADDRESS"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Docker Network" "$NETWORK_NAME"
  echo -e "  ${DIM}├────────────────────────┼──────────────────────────────────────────────┤${NC}"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "SMTP" "$HOST_BIND_ADDRESS:$SMTP_HOST_PORT → 25"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "IMAP" "$HOST_BIND_ADDRESS:$IMAP_HOST_PORT → 143"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "SMTPS" "$HOST_BIND_ADDRESS:$SMTPS_HOST_PORT → 465"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Submission" "$HOST_BIND_ADDRESS:$SUBMISSION_HOST_PORT → 587"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "IMAPS" "$HOST_BIND_ADDRESS:$IMAPS_HOST_PORT → 993"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "Roundcube" "$HOST_BIND_ADDRESS:$ROUNDCUBE_HOST_PORT → 80"
  printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "phpLDAPadmin" "$HOST_BIND_ADDRESS:$PHPLDAP_HOST_PORT → 8080"
  if (( PUBLISH_LDAP == 1 )); then
    printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "LDAP" "$HOST_BIND_ADDRESS:$LDAP_HOST_PORT → 389"
  else
    printf '  ${DIM}│${NC} %-22s ${DIM}│${NC} %-46s ${DIM}│${NC}\n' "LDAP" "internal only"
  fi
  echo -e "  ${DIM}└────────────────────────┴──────────────────────────────────────────────┘${NC}"
  blank

  # Mailbox accounts table
  echo -e "  ${BOLD}${CYAN}Mailbox Accounts${NC}"
  echo -e "  ${DIM}┌────────────────────────────────────────┬──────────┐${NC}"
  printf '  ${DIM}│${NC} %-38s ${DIM}│${NC} %-8s ${DIM}│${NC}\n' "Email" "Role"
  echo -e "  ${DIM}├────────────────────────────────────────┼──────────┤${NC}"
  for ((i=0; i<${#ACCOUNTS[@]}; i++)); do
    printf '  ${DIM}│${NC} %-38s ${DIM}│${NC} %-8s ${DIM}│${NC}\n' "${ACCOUNTS[$i]}" "${ACCOUNT_ROLES[$i]}"
  done
  echo -e "  ${DIM}└────────────────────────────────────────┴──────────┘${NC}"
  blank

  # Web access URLs
  echo -e "  ${BOLD}${CYAN}Web Access${NC}"
  echo -e "  ${GREEN}Roundcube (Webmail):${NC}       http://localhost:$ROUNDCUBE_HOST_PORT"
  echo -e "  ${GREEN}phpLDAPadmin (LDAP UI):${NC}    http://localhost:$PHPLDAP_HOST_PORT"
  if [[ "$HOST_BIND_ADDRESS" == "0.0.0.0" ]]; then
    echo -e "  ${GREEN}LAN Roundcube:${NC}             http://$host_ip:$ROUNDCUBE_HOST_PORT"
    echo -e "  ${GREEN}LAN phpLDAPadmin:${NC}          http://$host_ip:$PHPLDAP_HOST_PORT"
  fi
  blank

  # Common commands with explanations
  echo -e "  ${BOLD}${CYAN}Common Commands${NC}"
  echo -e "  ${DIM}┌──────────────────────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}│${NC} ${BOLD}Command${NC}                                                           ${DIM}│${NC}"
  echo -e "  ${DIM}├──────────────────────────────────────────────────────────────────────┤${NC}"
  echo -e "  ${DIM}│${NC} cd $PROJECT_ROOT                                                    ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose ps                          # Show container status                 ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose logs -f mailserver          # Follow mailserver logs                ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose logs -f openldap            # Follow OpenLDAP logs                  ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose logs -f roundcube           # Follow Roundcube logs                 ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose logs -f phpldapadmin        # Follow phpLDAPadmin logs              ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose restart mailserver          # Restart mailserver after config change ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} exec $DMS_CONTAINER doveadm auth test <email> <password>                ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC}   # Test LDAP/Dovecot authentication for a mailbox                 ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} exec $LDAP_CONTAINER ldapsearch -x -LLL -H ldap://127.0.0.1:389             ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC}   -D \"$LDAP_ADMIN_DN\" -W -b \"ou=Users,$LDAP_BASE_DN\"                 ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC}   # Query LDAP for all mailbox entries                              ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} exec $DMS_CONTAINER setup config dkim                             ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC}   # Generate DKIM keys for the domain                                 ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose down                        # Stop all containers                    ${DIM}│${NC}"
  echo -e "  ${DIM}│${NC} ${DC[*]} compose up -d                       # Start all containers                   ${DIM}│${NC}"
  echo -e "  ${DIM}└──────────────────────────────────────────────────────────────────────┘${NC}"
  blank

  echo -e "  ${YELLOW}Passwords are never printed.${NC}"
  echo -e "  ${BOLD}Full summary:${NC}            $PROJECT_ROOT/SETUP_SUMMARY.txt"
  echo -e "  ${BOLD}Feature tables:${NC}          $PROJECT_ROOT/CONFIGURATION_TABLE.md"
  echo -e "  ${BOLD}Compose file:${NC}            $COMPOSE_FILE"

  blank
  if [[ "$DOCKER_MANUAL_MODE" -eq 1 ]]; then
    warn "Docker was started manually for this WSL session. Systemd is recommended for automatic startup."
  fi

  warn "For public Internet mail, use a real domain, DNS/MX/SPF/DKIM/DMARC, trusted TLS certificates, firewall rules, and standard public mail ports."
}
main() {
  show_banner
  ensure_prerequisites
  collect_project_and_network
  collect_ports_and_security
  collect_accounts_and_postmaster
  review_config
  pull_images
  ldap_seed_users
  start_mail_and_web
  verify_stack
  write_summary

  # Clear plaintext passwords from shell memory before final output.
  unset LDAP_ADMIN_PASSWORD
  unset ACCOUNT_PASSWORDS
  final_screen
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --version|-V) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    "") main "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
fi

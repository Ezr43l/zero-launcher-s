#!/usr/bin/env bash
#
# Zero Launcher - Instalador asistido de aplicaciones en alta disponibilidad
# Copyright 2026 Ezrael
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROGRAM_NAME="Zero Launcher"
readonly PROGRAM_VERSION="1.0.1"
readonly DEFAULT_TARGET_DIR="/boot/config/plugins/dockerMan/templates-user"
readonly DEFAULT_BACKUP_DIR="/boot/config/zero-launcher/backups/templates"
readonly DEFAULT_LOG_DIR="/mnt/user/appdata/zero-launcher"
readonly PUBLIC_OWNER="Ezr43l"
readonly PUBLIC_NAMESPACE="ezr43l"
readonly SUPPORT_URL="https://discord.gg/8MAT6ZGJTW"

declare -ar APP_IDS=(
  "local-registry"
  "keepalived"
  "rtfm"
  "npm-guardian"
  "vault-guardian"
)

declare -ar INSTALLABLE_APP_IDS=(
  "keepalived"
  "rtfm"
  "npm-guardian"
  "vault-guardian"
)

DRY_RUN=false
SIMULATION_MODE=false
COLOR_ENABLED=false
WORK_DIR=""
SESSION_LOG=""
SESSION_LOGGER_PID=""
SESSION_LOG_ACTIVE=false
SESSION_LOG_SAVED=false
SAVED_LOG_PATH=""
ALL_APPS_SELECTED=false
SELECTED_APPS=()
LOCAL_REGISTRY_CONTAINER=""
LOCAL_REGISTRY_PREFIX=""
LOCAL_REGISTRY_SCHEME="http"
LOCAL_REGISTRY_BOOTSTRAP=false
INSTALL_MODE=""
PROMPT_RESULT=""
TARGET_DIR="${ZERO_LAUNCHER_TARGET_DIR:-$DEFAULT_TARGET_DIR}"
BACKUP_DIR="${ZERO_LAUNCHER_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
TEMPLATE_SOURCE_DIR="${ZERO_LAUNCHER_TEMPLATE_SOURCE_DIR:-}"
LOG_DIR="${ZERO_LAUNCHER_LOG_DIR:-$DEFAULT_LOG_DIR}"
PLATFORM="unsupported"
SYSTEM_LABEL="Sistema no identificado"
SYSTEM_ID=""
SYSTEM_VERSION=""
SYSTEM_CODENAME=""
DOCKER_DISTRO=""
MACHINE_ARCH=""
DATA_ROOT="/mnt/user/appdata"
COMPOSE_DIR="${ZERO_LAUNCHER_COMPOSE_DIR:-/opt/zero-launcher}"

declare -A APP_MODES=()
declare -A APP_CHANNELS=()
declare -A APP_ACTIONS=()
declare -A APP_STATES=()
declare -A APP_IMAGES=()
declare -A APP_TEMPLATE_PATHS=()
declare -A EXECUTED_APPS=()
declare -A RESERVED_PORTS=()
declare -A APP_MARKS=()

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  COLOR_ENABLED=true
fi

if $COLOR_ENABLED; then
  readonly C_RESET=$'\033[0m'
  readonly C_CYAN=$'\033[1;36m'
  readonly C_BLUE=$'\033[1;34m'
  readonly C_GREEN=$'\033[1;32m'
  readonly C_YELLOW=$'\033[1;33m'
  readonly C_RED=$'\033[1;31m'
  readonly C_DIM=$'\033[2m'
  readonly C_BOLD=$'\033[1m'
else
  readonly C_RESET=""
  readonly C_CYAN=""
  readonly C_BLUE=""
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_RED=""
  readonly C_DIM=""
  readonly C_BOLD=""
fi

cleanup_work_dir() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

cleanup() {
  local exit_status=$?
  cleanup_work_dir
  if [[ "$SESSION_LOG_ACTIVE" == "true" ]]; then
    stop_session_log
  fi
  if [[ -n "$SESSION_LOG" && -f "$SESSION_LOG" ]]; then
    if [[ "$SESSION_LOG_SAVED" == "true" ]]; then
      rm -f -- "$SESSION_LOG"
    else
      printf '[!] La ejecución terminó antes de guardar el registro. Se conserva temporalmente en %s\n' \
        "$SESSION_LOG" >&2
    fi
  fi
  return "$exit_status"
}

if [[ "${ZERO_LAUNCHER_SOURCE_ONLY:-false}" != "true" ]]; then
  trap cleanup EXIT
fi

info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
success() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

terminal_only_printf() {
  if [[ "$SESSION_LOG_ACTIVE" == "true" ]]; then
    printf "$@" >&8
  else
    printf "$@"
  fi
}

terminal_output_is_tty() {
  if [[ "$SESSION_LOG_ACTIVE" == "true" ]]; then
    [[ -t 8 ]]
  else
    [[ -t 1 ]]
  fi
}

start_session_log() {
  [[ -z "$SESSION_LOG" ]] || return 0
  SESSION_LOG=$(mktemp /tmp/zero-launcher-session.XXXXXX.log)
  exec 8>&1 9>&2
  exec > >(tee -a "$SESSION_LOG") 2>&1
  SESSION_LOGGER_PID=$!
  SESSION_LOG_ACTIVE=true
}

stop_session_log() {
  [[ "$SESSION_LOG_ACTIVE" == "true" ]] || return 0
  exec 1>&8 2>&9
  exec 8>&- 9>&-
  SESSION_LOG_ACTIVE=false
  if [[ -n "$SESSION_LOGGER_PID" ]]; then
    wait "$SESSION_LOGGER_PID" 2>/dev/null || true
  fi
  SESSION_LOGGER_PID=""
}

write_clean_log() {
  local source=$1 destination=$2
  LC_ALL=C sed $'s/\033\\[[0-9;?]*[A-Za-z]//g' "$source" | tr -d '\r' >"$destination"
  chmod 0600 "$destination" 2>/dev/null || true
}

save_session_log() {
  local destination reply filename

  printf '\n%sRegistro de ejecución%s\n' "$C_BOLD" "$C_RESET"
  printf 'Se guardará una copia de esta sesión para poder revisar o compartir cualquier problema.\n'
  while true; do
    read -r -p "Carpeta [$LOG_DIR]: " reply || return 1
    destination=${reply:-$LOG_DIR}
    if [[ "$destination" != /* || "$destination" == "/" ]]; then
      warn "Introduce una ruta absoluta y concreta."
      continue
    fi
    if ! mkdir -p -- "$destination" 2>/dev/null || [[ ! -d "$destination" || ! -w "$destination" ]]; then
      warn "No se puede escribir en $destination. Indica otra carpeta."
      continue
    fi
    break
  done

  filename="zero-launcher-$(date '+%Y%m%d-%H%M%S').log"
  SAVED_LOG_PATH="$destination/$filename"
  printf '\nHasta pronto.\n'
  stop_session_log
  if write_clean_log "$SESSION_LOG" "$SAVED_LOG_PATH"; then
    SESSION_LOG_SAVED=true
    success "Registro guardado en $SAVED_LOG_PATH"
    printf 'Puedes compartir este archivo si necesitas ayuda en Unraides.\n'
    return 0
  fi
  error "No se pudo guardar el registro. La copia temporal sigue en $SESSION_LOG"
  SAVED_LOG_PATH=""
  return 1
}

clear_screen() {
  if terminal_output_is_tty && [[ "${TERM:-dumb}" != "dumb" ]]; then
    terminal_only_printf '\033[2J\033[H'
  fi
}

banner() {
  printf '%s' "$C_CYAN"
  printf '%s\n' '  +--------------------------------------------------------+'
  printf '%s\n' '  |                     ZERO LAUNCHER                      |'
  printf '%s\n' '  |      Instalador asistido de aplicaciones en alta       |'
  printf '%s\n' '  |                     disponibilidad                     |'
  printf '%s\n' '  |                                                        |'
  printf '%s\n' '  |                Copyright © 2026 Ezrael                 |'
  printf '%s\n' '  +--------------------------------------------------------+'
  printf '%s' "$C_RESET"
  printf '  Versión %s\n\n' "$PROGRAM_VERSION"
  printf '  Entorno: %s\n\n' "$SYSTEM_LABEL"
}

pause() {
  if [[ -t 0 ]]; then
    printf '\nPulsa Intro para continuar...'
    read -r _
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "No se encuentra el comando requerido: $1"
}

ensure_work_dir() {
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR=$(mktemp -d /tmp/zero-launcher.XXXXXX)
  fi
}

os_release_value() {
  local file=$1 key=$2
  awk -v key="$key" 'index($0,key "=")==1 {
    value=substr($0,length(key)+2); gsub(/^"|"$/, "", value); print value; exit
  }' "$file"
}

set_platform_defaults() {
  if [[ "$PLATFORM" == "unraid" ]]; then
    DATA_ROOT="/mnt/user/appdata"
    LOG_DIR="${ZERO_LAUNCHER_LOG_DIR:-$DEFAULT_LOG_DIR}"
  else
    DATA_ROOT="/srv/appdata"
    LOG_DIR="${ZERO_LAUNCHER_LOG_DIR:-/var/log/zero-launcher}"
  fi
}

detect_platform() {
  local release_file=${1:-/etc/os-release} kernel=${2:-$(uname -s)}
  MACHINE_ARCH=${3:-$(uname -m)}
  SYSTEM_ID=""; SYSTEM_VERSION=""; SYSTEM_CODENAME=""; DOCKER_DISTRO=""
  PLATFORM="unsupported"; SYSTEM_LABEL="$kernel ($MACHINE_ARCH)"
  if [[ "$kernel" != "Linux" ]]; then
    set_platform_defaults
    return 0
  fi
  if [[ "$release_file" == "/etc/os-release" && ( -f /etc/unraid-version || -d /usr/local/emhttp ) ]]; then
    PLATFORM="unraid"; SYSTEM_LABEL="Unraid ($MACHINE_ARCH)"
  else
    PLATFORM="linux"
    if [[ -f "$release_file" ]]; then
      SYSTEM_ID=$(os_release_value "$release_file" ID)
      SYSTEM_VERSION=$(os_release_value "$release_file" VERSION_ID)
      SYSTEM_CODENAME=$(os_release_value "$release_file" VERSION_CODENAME)
      SYSTEM_LABEL="$(os_release_value "$release_file" PRETTY_NAME) ($MACHINE_ARCH)"
    fi
    case "$SYSTEM_ID:$SYSTEM_VERSION" in
      ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) DOCKER_DISTRO="ubuntu" ;;
      debian:12|debian:13) DOCKER_DISTRO="debian" ;;
      raspbian:12|raspbian:13) DOCKER_DISTRO="debian" ;;
    esac
    if [[ -f /proc/device-tree/model ]] && grep -q 'Raspberry Pi' /proc/device-tree/model; then
      SYSTEM_LABEL="Raspberry Pi · $SYSTEM_LABEL"
    fi
  fi
  set_platform_defaults
}

choose_simulation_platform() {
  local reply
  printf '\n¿Qué equipo quieres simular?\n\n'
  printf '  1. Unraid\n  2. Debian Linux\n  3. Ubuntu Linux\n  4. Raspberry Pi OS de 64 bits\n\n'
  while true; do
    read -r -p 'Selección [1]: ' reply || return 1
    case "${reply:-1}" in
      1) PLATFORM="unraid"; MACHINE_ARCH="x86_64"; SYSTEM_LABEL="Unraid nuevo (simulado)" ;;
      2) PLATFORM="linux"; MACHINE_ARCH="x86_64"; SYSTEM_LABEL="Debian nuevo (simulado)" ;;
      3) PLATFORM="linux"; MACHINE_ARCH="x86_64"; SYSTEM_LABEL="Ubuntu nuevo (simulado)" ;;
      4) PLATFORM="linux"; MACHINE_ARCH="aarch64"; SYSTEM_LABEL="Raspberry Pi OS de 64 bits (simulado)" ;;
      *) warn "Selección no válida."; continue ;;
    esac
    set_platform_defaults
    return 0
  done
}

install_download_tools() {
  command -v curl >/dev/null 2>&1 && return 0
  local reply
  if [[ "$PLATFORM" != "linux" || -z "$DOCKER_DISTRO" || $(id -u) -ne 0 || "$DRY_RUN" == "true" ]]; then
    error "Falta curl para descargar las plantillas. Instálalo antes de continuar."
    return 1
  fi
  read -r -p 'Falta curl. ¿Instalar curl y los certificados del sistema? [s/N]: ' reply || return 1
  [[ "$reply" =~ ^[Ss]$ ]] || return 1
  apt-get update && apt-get install -y curl ca-certificates
}

install_docker_dependencies() {
  local engine_missing=$1 reply package arch codename
  local -a packages=(docker-compose-plugin)
  if [[ -z "$DOCKER_DISTRO" ]]; then
    error "La instalación automática de Docker está disponible para Debian 12/13, Ubuntu 22.04/24.04/26.04 y Raspberry Pi OS de 64 bits."
    error "En otros Linux instala Docker y su complemento Compose y vuelve al asistente."
    return 1
  fi
  if [[ "$engine_missing" != "true" ]] && dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q 'install ok installed'; then
    error "Tu Docker procede de los paquetes de la distribución. Instala su complemento Compose sin sustituir ese Docker."
    return 1
  fi
  if [[ "$engine_missing" == "true" ]]; then
    for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
      if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
        error "Ya existe el paquete $package. No se eliminará ni sustituirá automáticamente."
        error "Prepara Docker y Compose siguiendo la documentación de Docker y vuelve al asistente."
        return 1
      fi
    done
    packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  fi
  printf '\nSe añadirá el repositorio oficial de Docker y se instalará: %s\n' "${packages[*]}"
  printf 'No se eliminarán paquetes, contenedores ni datos existentes.\n'
  printf 'Los puertos Docker pueden eludir reglas del cortafuegos; limita el acceso a tu red de confianza.\n'
  read -r -p '¿Autorizar esta instalación en el sistema? [s/N]: ' reply || return 1
  [[ "$reply" =~ ^[Ss]$ ]] || return 1
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Simulación: no se instalarán paquetes."
    return 1
  fi
  arch=$(dpkg --print-architecture)
  case "$SYSTEM_CODENAME:$SYSTEM_VERSION:$DOCKER_DISTRO" in
    :12:debian) codename="bookworm" ;;
    :13:debian) codename="trixie" ;;
    *) codename=$SYSTEM_CODENAME ;;
  esac
  [[ "$codename" =~ ^[a-z]+$ && "$arch" =~ ^(amd64|arm64)$ ]] || {
    error "No se ha podido identificar la versión de los paquetes Docker."
    return 1
  }
  apt-get update || return 1
  apt-get install -y ca-certificates curl || return 1
  install -m 0755 -d /etc/apt/keyrings || return 1
  curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc || return 1
  chmod a+r /etc/apt/keyrings/docker.asc || return 1
  printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
    "$DOCKER_DISTRO" "$codename" "$arch" | tee /etc/apt/sources.list.d/docker.sources >/dev/null || return 1
  apt-get update && apt-get install -y "${packages[@]}"
}

preflight_platform() {
  local allow_install=${1:-true} reply
  basic_preflight
  [[ "$PLATFORM" != "unsupported" ]] || {
    error "La instalación real necesita Unraid o Linux. En este equipo puedes usar el simulador."
    return 1
  }
  case "$MACHINE_ARCH" in
    x86_64|amd64|aarch64|arm64) ;;
    *) error "Se necesita un sistema de 64 bits: Intel/AMD o ARM. En Raspberry Pi utiliza un sistema operativo de 64 bits (Pi 3 o posterior)."; return 1 ;;
  esac
  [[ $(id -u) -eq 0 ]] || { error "Para instalar, ejecuta sudo bash zero-launcher.sh; en Unraid usa su terminal como root."; return 1; }
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$PLATFORM" != "linux" || "$allow_install" != "true" ]]; then
      error "Docker no está instalado o no está disponible."
      return 1
    fi
    install_docker_dependencies true || return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    if [[ "$PLATFORM" != "linux" || "$allow_install" != "true" || "$DRY_RUN" == "true" ]]; then
      error "Docker no responde. Inicia su servicio y vuelve a intentarlo."
      return 1
    fi
    read -r -p 'Docker está instalado pero no responde. ¿Intentar arrancar su servicio? [s/N]: ' reply || return 1
    [[ "$reply" =~ ^[Ss]$ ]] || return 1
    systemctl start docker || return 1
    docker info >/dev/null 2>&1 || { error "Docker sigue sin responder."; return 1; }
  fi
  if [[ "$PLATFORM" == "linux" && "$allow_install" == "true" ]]; then
    if ! docker compose version >/dev/null 2>&1; then
      install_docker_dependencies false || return 1
      docker compose version >/dev/null 2>&1 || return 1
    fi
  fi
  if [[ "$PLATFORM" == "unraid" && "$TARGET_DIR" != "$DEFAULT_TARGET_DIR" && "${ZERO_LAUNCHER_TESTING:-false}" != "true" ]]; then
    error "La ruta de plantillas de Unraid no es la esperada: $TARGET_DIR"
    return 1
  fi
}

app_label() {
  case "$1" in
    local-registry) printf '%s' "Local Registry" ;;
    keepalived) printf '%s' "Keepalived" ;;
    rtfm) printf '%s' "RTFM" ;;
    npm-guardian) printf '%s' "NPM Guardian" ;;
    vault-guardian) printf '%s' "Vault Guardian" ;;
    *) return 1 ;;
  esac
}

app_container() {
  case "$1" in
    local-registry) printf '%s' "Local-Registry" ;;
    keepalived) printf '%s' "Keepalived" ;;
    rtfm) printf '%s' "RTFM" ;;
    npm-guardian) printf '%s' "NPM-Guardian" ;;
    vault-guardian) printf '%s' "Vault-Guardian" ;;
    *) return 1 ;;
  esac
}

app_repo_slug() {
  case "$1" in
    local-registry) printf '%s' "local-registry-s" ;;
    keepalived) printf '%s' "keepalived-s" ;;
    rtfm) printf '%s' "rtfm-s" ;;
    npm-guardian) printf '%s' "npm-guardian-s" ;;
    vault-guardian) printf '%s' "vault-guardian-s" ;;
    *) return 1 ;;
  esac
}

app_template_file() {
  case "$1" in
    local-registry) printf '%s' "my-Local-Registry.xml" ;;
    keepalived) printf '%s' "my-Keepalived.xml" ;;
    rtfm) printf '%s' "my-RTFM.xml" ;;
    npm-guardian) printf '%s' "my-NPM-Guardian.xml" ;;
    vault-guardian) printf '%s' "my-Vault-Guardian.xml" ;;
    *) return 1 ;;
  esac
}

public_image() {
  printf 'ghcr.io/%s/%s:%s' "$PUBLIC_NAMESPACE" "$(app_repo_slug "$1")" "$2"
}

local_image() {
  if [[ "$1" == "local-registry" ]]; then
    public_image "$1" "$2"
  else
    printf '%s/%s:%s' "$3" "$(app_repo_slug "$1")" "$2"
  fi
}

template_url() {
  printf 'https://raw.githubusercontent.com/%s/%s/main/unraid/%s' \
    "$PUBLIC_OWNER" "$(app_repo_slug "$1")" "$(app_template_file "$1")"
}

validate_registry_prefix() {
  local value=$1
  [[ "$value" != *"://"* ]] || return 1
  [[ "$value" != /* && "$value" != */ ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9._:-]+(/[A-Za-z0-9._-]+)*$ ]]
}

xml_tag_value() {
  local file=$1
  local tag=$2
  awk -v open_tag="<$tag>" -v close_tag="</$tag>" '
    index($0, open_tag) && index($0, close_tag) {
      value=$0
      sub(".*" open_tag, "", value)
      sub(close_tag ".*", "", value)
      print value
      exit
    }
  ' "$file"
}

xml_attr() {
  printf '%s\n' "$1" | sed -n "s/.* $2=\"\([^\"]*\)\".*/\1/p"
}

xml_config_value() {
  local value=${1#*>}
  printf '%s' "${value%%</Config>*}"
}

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g'
}

xml_unescape() {
  printf '%s' "$1" | sed \
    -e 's/&lt;/</g' \
    -e 's/&gt;/>/g' \
    -e 's/&quot;/"/g' \
    -e "s/&apos;/'/g" \
    -e 's/&amp;/\&/g'
}

fetch_template() {
  local app_id=$1
  local destination=$2
  local local_source

  if [[ -n "$TEMPLATE_SOURCE_DIR" ]]; then
    local_source="$TEMPLATE_SOURCE_DIR/$(app_template_file "$app_id")"
    [[ -f "$local_source" ]] || {
      error "No existe la plantilla local de prueba: $local_source"
      return 1
    }
    cp -- "$local_source" "$destination"
    return 0
  fi

  info "Descargando la plantilla de $(app_label "$app_id")..."
  curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 1 --connect-timeout 10 \
    --output "$destination" "$(template_url "$app_id")"
}

validate_template() {
  local template=$1
  local app_id=$2
  local expected_name
  local tag
  expected_name=$(app_container "$app_id")

  [[ -s "$template" ]] || {
    error "La plantilla de $(app_label "$app_id") está vacía."
    return 1
  }
  [[ $(grep -c '<Container[ >]' "$template" || true) -eq 1 ]] || {
    error "La plantilla de $(app_label "$app_id") no contiene un único Container."
    return 1
  }
  grep -Fq "<Name>$expected_name</Name>" "$template" || {
    error "El nombre del contenedor no coincide en la plantilla de $(app_label "$app_id")."
    return 1
  }
  for tag in Repository Network WebUI Icon Project ExtraParams; do
    grep -Eq "<$tag>.*</$tag>" "$template" || {
      error "La plantilla de $(app_label "$app_id") no declara $tag."
      return 1
    }
  done
}

render_template() {
  local source=$1
  local destination=$2
  local app_id=$3
  local channel=$4
  local install_mode=$5
  local registry_prefix=${6:-}
  local registry_scheme=${7:-http}
  local image
  local registry_url=""
  local local_variant=false

  if [[ "$install_mode" == "local" && "$app_id" != "local-registry" ]]; then
    image=$(local_image "$app_id" "$channel" "$registry_prefix")
    registry_url="${registry_scheme}://${registry_prefix%%/*}"
    local_variant=true
  else
    image=$(public_image "$app_id" "$channel")
  fi

  awk -v image="$image" -v registry_url="$registry_url" -v local_variant="$local_variant" '
    BEGIN { repository_done=0; registry_done=0; template_url_done=0 }
    repository_done == 0 && /<Repository>[^<]*<\/Repository>/ {
      sub(/<Repository>[^<]*<\/Repository>/, "<Repository>" image "</Repository>")
      repository_done=1
    }
    local_variant == "true" && registry_done == 0 && /<Registry>[^<]*<\/Registry>/ {
      sub(/<Registry>[^<]*<\/Registry>/, "<Registry>" registry_url "</Registry>")
      registry_done=1
    }
    local_variant == "true" && template_url_done == 0 && /<TemplateURL>[^<]*<\/TemplateURL>/ {
      sub(/<TemplateURL>[^<]*<\/TemplateURL>/, "<TemplateURL/>")
      template_url_done=1
    }
    { print }
    END { if (repository_done == 0) exit 41 }
  ' "$source" >"$destination"
}

validate_rendered_template() {
  grep -Fq "<Repository>$2</Repository>" "$1" || {
    error "La imagen esperada no aparece en la plantilla generada."
    return 1
  }
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ((10#$1 >= 1 && 10#$1 <= 65535))
}

port_in_use() {
  local port=$1
  [[ "$SIMULATION_MODE" != "true" ]] || return 1
  if docker ps -a --filter "publish=$port" --format '{{.ID}}' 2>/dev/null | grep -q .; then
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -H -lnt 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$" {found=1} END {exit !found}'
    return
  fi
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(^|:)$port->|0\.0\.0\.0:$port->|\[::\]:$port->"
}

prompt_value() {
  local name=$1
  local description=$2
  local default=$3
  local required=$4
  local masked=$5
  local example=${6:-}
  local default_is_example=${7:-false}
  local reply

  printf '\n%s%s%s\n' "$C_BOLD" "$name" "$C_RESET"
  [[ -z "$description" ]] || printf '  %s\n' "$description"
  if [[ -n "$default" ]]; then
    if [[ "$default_is_example" == "true" ]]; then
      printf '  Valor de ejemplo para la simulación: %s\n' "$default"
    else
      printf '  Valor predeterminado: %s\n' "$default"
    fi
  elif [[ -n "$example" ]]; then
    printf '  Ejemplo habitual: %s\n' "$example"
  fi

  while true; do
    if [[ "$masked" == "true" ]]; then
      if [[ -n "$default" ]]; then
        read -r -s -p '  Valor [Intro para conservar el configurado]: ' reply <&3 || return 1
      elif [[ "$required" == "true" ]]; then
        read -r -s -p '  Valor obligatorio: ' reply <&3 || return 1
      else
        read -r -s -p '  Valor [opcional]: ' reply <&3 || return 1
      fi
      printf '\n'
    elif [[ -n "$default" ]]; then
      read -r -p '  Valor [Intro para usar el valor mostrado]: ' reply <&3 || return 1
    elif [[ "$required" == "true" ]]; then
      read -r -p '  Valor obligatorio: ' reply <&3 || return 1
    else
      read -r -p '  Valor [opcional]: ' reply <&3 || return 1
    fi
    reply=${reply:-$default}
    if [[ "$required" == "true" && -z "$reply" ]]; then
      warn "No hay un valor predeterminado. Introduce el valor necesario."
      continue
    fi
    PROMPT_RESULT=$reply
    return 0
  done
}

config_example() {
  case "$1" in
    /npm) printf '%s/nginx-proxy-manager/data' "$DATA_ROOT" ;;
    /npm-letsencrypt) printf '%s/nginx-proxy-manager/letsencrypt' "$DATA_ROOT" ;;
    *) printf '%s' '' ;;
  esac
}

personalize_template() {
  local source=$1
  local destination=$2
  local line name target default description type required masked current value escaped prefix suffix
  local example default_is_example

  : >"$destination"
  exec 3<&0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != *"<Config "* ]]; then
      printf '%s\n' "$line" >>"$destination"
      continue
    fi

    name=$(xml_attr "$line" Name)
    target=$(xml_attr "$line" Target)
    default=$(xml_attr "$line" Default)
    description=$(xml_attr "$line" Description)
    type=$(xml_attr "$line" Type)
    required=$(xml_attr "$line" Required)
    masked=$(xml_attr "$line" Mask)
    current=$(xml_unescape "$(xml_config_value "$line")")
    [[ -n "$default" ]] || default=$current
    if [[ "$PLATFORM" == "linux" && "$type" == "Path" && "$default" == /mnt/user/appdata* ]]; then
      default="$DATA_ROOT${default#/mnt/user/appdata}"
      description="Directorio en este equipo Linux. Se reutiliza si existe y se crea si falta."
    fi
    example=$(config_example "$target")
    default_is_example=false
    if [[ "$SIMULATION_MODE" == "true" && -z "$default" && -n "$example" ]]; then
      default=$example
      default_is_example=true
    fi

    prompt_value "$name" "$description" "$default" "${required:-false}" \
      "${masked:-false}" "$example" "$default_is_example" || return 1
    value=$PROMPT_RESULT
    case "$type" in
      Port)
        while ! valid_port "$value"; do
          warn "Introduce un puerto entre 1 y 65535."
          prompt_value "$name" "$description" "$default" "true" "false" \
            "$example" "$default_is_example" || return 1
          value=$PROMPT_RESULT
        done
        if port_in_use "$value" || [[ -n "${RESERVED_PORTS[$value]:-}" ]]; then
          warn "El puerto $value ya está ocupado. Elige otro."
          while true; do
            prompt_value "$name" "$description" "" "true" "false" || return 1
            value=$PROMPT_RESULT
            valid_port "$value" && ! port_in_use "$value" && \
              [[ -z "${RESERVED_PORTS[$value]:-}" ]] && break
            warn "Ese puerto no es válido o también está ocupado."
          done
        fi
        RESERVED_PORTS[$value]=true
        ;;
      Path)
        while [[ "$value" != /* || "$value" == "/" ]]; do
          warn "Introduce una ruta absoluta y concreta."
          prompt_value "$name" "$description" "$default" "true" "false" \
            "$example" "$default_is_example" || return 1
          value=$PROMPT_RESULT
        done
        if [[ "$target" == "/var/run/docker.sock" && "$SIMULATION_MODE" != "true" && ! -S "$value" ]]; then
          die "No existe el socket de Docker indicado: $value"
        fi
        ;;
      Variable)
        if [[ "$target" == *PORT* || "$target" == *PUERTO* ]]; then
          while ! valid_port "$value"; do
            warn "Introduce un puerto entre 1 y 65535."
            prompt_value "$name" "$description" "$default" "true" "false" || return 1
            value=$PROMPT_RESULT
          done
          if port_in_use "$value" || [[ -n "${RESERVED_PORTS[$value]:-}" ]]; then
            warn "El puerto $value ya está ocupado. Elige otro."
            while true; do
              prompt_value "$name" "$description" "" "true" "false" || return 1
              value=$PROMPT_RESULT
              valid_port "$value" && ! port_in_use "$value" && \
                [[ -z "${RESERVED_PORTS[$value]:-}" ]] && break
              warn "Ese puerto no es válido o también está ocupado."
            done
          fi
          RESERVED_PORTS[$value]=true
        fi
        ;;
      *) die "La plantilla contiene un tipo de dato no compatible: $type" ;;
    esac

    escaped=$(xml_escape "$value")
    prefix=${line%%>*}
    suffix=${line#*</Config>}
    printf '%s>%s</Config>%s\n' "$prefix" "$escaped" "$suffix" >>"$destination"
    [[ "$masked" == "true" ]] || info "Dato Docker: $name = $value"
  done <"$source"
  exec 3<&-
}

install_template_file() {
  local source=$1
  local filename target temporary_target timestamp backup_target
  filename=$(basename -- "$source")
  target="$TARGET_DIR/$filename"

  if [[ -f "$target" ]] && cmp -s -- "$source" "$target"; then
    success "$filename ya está actualizado."
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Simulación: se instalaría $target"
    return 0
  fi

  mkdir -p -- "$TARGET_DIR"
  if [[ -f "$target" ]]; then
    timestamp=$(date '+%Y%m%d-%H%M%S')
    backup_target="$BACKUP_DIR/$timestamp/$filename"
    mkdir -p -- "$(dirname -- "$backup_target")"
    cp -p -- "$target" "$backup_target"
    info "Respaldo creado en $backup_target"
  fi

  temporary_target="$target.zero-launcher.$$"
  cp -- "$source" "$temporary_target"
  chmod 0600 "$temporary_target" 2>/dev/null || true
  mv -f -- "$temporary_target" "$target"
  success "Plantilla instalada: $target"
}

basic_preflight() {
  local command_name
  for command_name in awk cmp date grep mktemp sed tee tr; do
    require_command "$command_name"
  done
}

container_state() {
  local status
  if ! docker inspect "$1" >/dev/null 2>&1; then
    printf '%s' "not-installed"
    return 0
  fi
  status=$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || true)
  case "$status" in
    running|exited|created|dead|paused|restarting) printf '%s' "$status" ;;
    *) printf '%s' "unknown" ;;
  esac
}

detect_apps() {
  local app_id container
  for app_id in "${APP_IDS[@]}"; do
    container=$(app_container "$app_id")
    APP_STATES[$app_id]=$(container_state "$container")
    if [[ "${APP_STATES[$app_id]}" != "not-installed" ]]; then
      APP_IMAGES[$app_id]=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
    else
      APP_IMAGES[$app_id]=""
    fi
  done
}

state_label() {
  case "$1" in
    running) printf '%s' "instalado y funcionando" ;;
    not-installed) printf '%s' "no instalado" ;;
    exited|created) printf '%s' "instalado y detenido" ;;
    paused) printf '%s' "instalado y pausado" ;;
    restarting) printf '%s' "reiniciándose" ;;
    dead) printf '%s' "instalado con error" ;;
    *) printf '%s' "estado desconocido" ;;
  esac
}

reset_app_marks() {
  local app_id
  APP_MARKS=()
  for app_id in "${INSTALLABLE_APP_IDS[@]}"; do
    APP_MARKS[$app_id]=false
  done
}

all_apps_marked() {
  local app_id
  for app_id in "${INSTALLABLE_APP_IDS[@]}"; do
    [[ "${APP_MARKS[$app_id]:-false}" == "true" ]] || return 1
  done
  return 0
}

toggle_app_mark() {
  local position=$1
  local app_id
  local new_value=true
  local all_position=${#INSTALLABLE_APP_IDS[@]}

  if [[ "$position" -eq "$all_position" ]]; then
    all_apps_marked && new_value=false
    for app_id in "${INSTALLABLE_APP_IDS[@]}"; do
      APP_MARKS[$app_id]=$new_value
    done
    return 0
  fi

  app_id=${INSTALLABLE_APP_IDS[$position]}
  if [[ "${APP_MARKS[$app_id]:-false}" == "true" ]]; then
    APP_MARKS[$app_id]=false
  else
    APP_MARKS[$app_id]=true
  fi
}

commit_app_marks() {
  local app_id
  SELECTED_APPS=()
  ALL_APPS_SELECTED=true
  for app_id in "${INSTALLABLE_APP_IDS[@]}"; do
    if [[ "${APP_MARKS[$app_id]:-false}" == "true" ]]; then
      SELECTED_APPS+=("$app_id")
    else
      ALL_APPS_SELECTED=false
    fi
  done
  [[ ${#SELECTED_APPS[@]} -gt 0 ]]
}

install_mode_label() {
  if [[ "$INSTALL_MODE" == "local" ]]; then
    printf '%s' "Imágenes locales desde Local Registry"
  else
    printf '%s' "Imágenes públicas desde GHCR"
  fi
}

render_app_rows() {
  local current=$1
  local message=${2:-}
  local position app_id pointer mark label detail
  local all_position=${#INSTALLABLE_APP_IDS[@]}

  terminal_only_printf '\033[u'
  for ((position=0; position<=all_position; position++)); do
    pointer=" "
    [[ "$position" -ne "$current" ]] || pointer=">"
    if [[ "$position" -eq "$all_position" ]]; then
      if all_apps_marked; then mark="x"; else mark=" "; fi
      label="Instalar todas"
      detail="marca o desmarca el conjunto"
    else
      app_id=${INSTALLABLE_APP_IDS[$position]}
      if [[ "${APP_MARKS[$app_id]:-false}" == "true" ]]; then mark="x"; else mark=" "; fi
      label=$(app_label "$app_id")
      detail=$(state_label "${APP_STATES[$app_id]}")
    fi
    terminal_only_printf '\r\033[2K'
    if [[ "$position" -eq "$current" ]]; then
      terminal_only_printf ' %s%s%s %s[%s]%s %-22s %s\n' \
        "$C_CYAN" "$pointer" "$C_RESET" "$C_GREEN" "$mark" "$C_RESET" "$label" "$detail"
    else
      terminal_only_printf ' %s %s[%s]%s %-22s %s\n' \
        "$pointer" "$C_GREEN" "$mark" "$C_RESET" "$label" "$detail"
    fi
  done
  terminal_only_printf '\r\033[2K'
  [[ -z "$message" ]] || terminal_only_printf '%s%s%s' "$C_YELLOW" "$message" "$C_RESET"
}

start_app_checklist() {
  clear_screen
  banner
  if [[ "$SIMULATION_MODE" == "true" ]]; then
    printf '%sMODO SIMULADOR · servidor nuevo%s\n' "$C_YELLOW" "$C_RESET"
    printf 'No se modificarán Docker, las plantillas ni las aplicaciones.\n'
  fi
  printf 'Origen elegido: %s%s%s\n' "$C_CYAN" "$(install_mode_label)" "$C_RESET"
  if [[ "$INSTALL_MODE" == "local" ]]; then
    printf 'Local Registry se comprobará y preparará automáticamente.\n'
  fi
  printf '\n%sSelecciona las aplicaciones%s\n' "$C_BOLD" "$C_RESET"
  printf 'Usa las flechas ↑ y ↓, pulsa Espacio para marcar y Enter para continuar.\n\n'
  terminal_only_printf '\033[s'
}

choose_apps_checklist() {
  local current=0
  local key sequence message=""
  local last_position=${#INSTALLABLE_APP_IDS[@]}
  reset_app_marks
  start_app_checklist

  while true; do
    render_app_rows "$current" "$message"
    message=""
    IFS= read -r -s -n 1 key
    if [[ "$key" == $'\e' ]]; then
      sequence=""
      IFS= read -r -s -n 2 -t 0.2 sequence || true
      key+=$sequence
    fi
    case "$key" in
      $'\e[A'|$'\eOA') current=$(((current + last_position) % (last_position + 1))) ;;
      $'\e[B'|$'\eOB') current=$(((current + 1) % (last_position + 1))) ;;
      ' ') toggle_app_mark "$current" ;;
      '')
        if commit_app_marks; then
          terminal_only_printf '\033[u\033[J'
          clear_screen
          banner
          return 0
        fi
        message="Marca al menos una aplicación antes de continuar."
        ;;
    esac
  done
}

choose_apps_noninteractive() {
  local reply token index
  local -a chosen=() tokens=()
  local -A seen=()

  while true; do
    printf '\n%sAplicaciones:%s\n\n' "$C_BOLD" "$C_RESET"
    for index in "${!INSTALLABLE_APP_IDS[@]}"; do
      printf '  %s%d.%s %-18s %s\n' "$C_CYAN" "$((index + 1))" "$C_RESET" \
        "$(app_label "${INSTALLABLE_APP_IDS[$index]}")" \
        "$(state_label "${APP_STATES[${INSTALLABLE_APP_IDS[$index]}]}")"
    done
    printf '  %sA.%s Instalar todas\n' "$C_CYAN" "$C_RESET"
    printf '\nEscribe números separados por comas.\n'
    read -r -p 'Selección: ' reply
    reply=${reply//[[:space:]]/}
    if [[ "${reply^^}" == "A" ]]; then
      SELECTED_APPS=("${INSTALLABLE_APP_IDS[@]}")
      ALL_APPS_SELECTED=true
      return 0
    fi

    chosen=()
    seen=()
    IFS=',' read -r -a tokens <<<"$reply"
    for token in "${tokens[@]}"; do
      if [[ ! "$token" =~ ^[1-4]$ ]]; then
        chosen=()
        break
      fi
      index=$((token - 1))
      if [[ -z "${seen[$index]:-}" ]]; then
        chosen+=("${INSTALLABLE_APP_IDS[$index]}")
        seen[$index]=1
      fi
    done
    if [[ ${#chosen[@]} -gt 0 ]]; then
      SELECTED_APPS=("${chosen[@]}")
      ALL_APPS_SELECTED=false
      return 0
    fi
    warn "Selección no válida."
  done
}

choose_apps() {
  local app_id selected_labels=""
  if [[ -t 0 ]] && terminal_output_is_tty; then
    choose_apps_checklist
  else
    choose_apps_noninteractive
  fi
  for app_id in "${SELECTED_APPS[@]}"; do
    [[ -z "$selected_labels" ]] || selected_labels+=", "
    selected_labels+=$(app_label "$app_id")
  done
  info "Aplicaciones seleccionadas: $selected_labels"
}

choose_mode_value() {
  local reply
  while true; do
    printf '\n%s%s%s\n\n' "$C_BOLD" "$1" "$C_RESET"
    printf '  %s1.%s Imágenes públicas desde GHCR %s[recomendado]%s\n' \
      "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET"
    printf '  %s2.%s Imágenes locales desde Local Registry\n\n' "$C_CYAN" "$C_RESET"
    read -r -p 'Selección [1]: ' reply
    case "${reply:-1}" in
      1) PROMPT_RESULT="public"; return 0 ;;
      2) PROMPT_RESULT="local"; return 0 ;;
      *) warn "Selección no válida." ;;
    esac
  done
}

choose_install_mode() {
  choose_mode_value "Origen de las imágenes"
  INSTALL_MODE=$PROMPT_RESULT
}

apply_install_mode() {
  local app_id
  for app_id in "${SELECTED_APPS[@]}"; do
    APP_MODES[$app_id]=$INSTALL_MODE
  done
  APP_MODES[local-registry]="public"
}

image_available() {
  local image=$1
  local repository_with_tag
  local repository
  local tag
  local token_json
  local token
  local manifest architecture

  if [[ "${ZERO_LAUNCHER_ASSUME_IMAGES:-false}" == "true" ]]; then
    return 0
  fi
  [[ "$image" == ghcr.io/*:* ]] || return 1
  repository_with_tag=${image#ghcr.io/}
  repository=${repository_with_tag%:*}
  tag=${repository_with_tag##*:}

  token_json=$(curl --fail --silent --show-error --get \
    --data-urlencode "service=ghcr.io" \
    --data-urlencode "scope=repository:$repository:pull" \
    'https://ghcr.io/token') || return 1
  token=$(printf '%s' "$token_json" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [[ -n "$token" ]] || return 1

  manifest=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    --header "Authorization: Bearer $token" \
    --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/$repository/manifests/$tag") || return 1
  case "$MACHINE_ARCH" in aarch64|arm64) architecture="arm64" ;; *) architecture="amd64" ;; esac
  if [[ "$manifest" == *'"manifests"'* ]]; then
    printf '%s' "$manifest" | grep -Eq '"architecture"[[:space:]]*:[[:space:]]*"'"$architecture"'"'
  else
    # Las imágenes sin índice se verifican definitivamente al descargarlas con Docker.
    [[ -n "$manifest" ]]
  fi
}

choose_channel_for_app() {
  local app_id=$1
  local stable=false dev=false reply
  image_available "$(public_image "$app_id" stable)" && stable=true
  image_available "$(public_image "$app_id" dev)" && dev=true

  if "$stable" && ! "$dev"; then
    APP_CHANNELS[$app_id]="stable"
    info "$(app_label "$app_id"): se instalará la versión estable."
    return 0
  fi
  if ! "$stable" && "$dev"; then
    warn "$(app_label "$app_id") sólo está disponible en desarrollo y podría no ser estable."
    read -r -p '¿Continuar con esta versión? [S/n]: ' reply
    [[ ! "$reply" =~ ^[Nn]$ ]] || return 1
    APP_CHANNELS[$app_id]="dev"
    return 0
  fi
  if ! "$stable" && ! "$dev"; then
    error "No hay ninguna imagen disponible para $(app_label "$app_id")."
    return 1
  fi

  while true; do
    printf '\n%sVersión de %s%s\n\n' "$C_BOLD" "$(app_label "$app_id")" "$C_RESET"
    printf '  %s1.%s Stable %s[recomendado]%s\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET"
    printf '  %s2.%s Dev %s[podría no ser estable]%s\n\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET"
    read -r -p 'Selección [1]: ' reply
    case "${reply:-1}" in
      1) APP_CHANNELS[$app_id]="stable"; return 0 ;;
      2)
        read -r -p 'Escribe DEV para continuar: ' reply
        [[ "$reply" == "DEV" ]] && APP_CHANNELS[$app_id]="dev" && return 0
        ;;
      *) warn "Selección no válida." ;;
    esac
  done
}

choose_channels() {
  local app_id
  info "Comprobando qué versiones están publicadas..."
  for app_id in "${SELECTED_APPS[@]}"; do
    if [[ "${APP_STATES[$app_id]}" != "not-installed" ]]; then
      APP_CHANNELS[$app_id]="installed"
    else
      choose_channel_for_app "$app_id" || return 1
    fi
  done
}

registry_reachable() {
  local server=${1%%/*}
  local status
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 "$2://${server}/v2/" || true)
  [[ "$status" == "200" || "$status" == "401" ]]
}

find_local_registry_container() {
  local candidates
  [[ "$SIMULATION_MODE" != "true" ]] || return 1
  if docker inspect Local-Registry >/dev/null 2>&1; then
    printf '%s' "Local-Registry"
    return 0
  fi
  candidates=$(docker ps -a --format '{{.Names}}|{{.Image}}' | \
    awk -F '|' '$2 ~ /(^|\/)(local-registry|local-registry-s):/ {print $1}')
  if [[ $(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l) -eq 1 ]]; then
    printf '%s' "$candidates"
    return 0
  fi
  return 1
}

registry_port_from_container() {
  local binding
  binding=$(docker port "$1" 5000/tcp 2>/dev/null | head -n 1 || true)
  [[ -n "$binding" ]] || return 1
  printf '%s' "${binding##*:}"
}

get_config_value_by_target() {
  local template=$1 wanted=$2 line target
  while IFS= read -r line; do
    [[ "$line" == *"<Config "* ]] || continue
    target=$(xml_attr "$line" Target)
    if [[ "$target" == "$wanted" ]]; then
      xml_unescape "$(xml_config_value "$line")"
      return 0
    fi
  done <"$template"
  return 1
}

prepare_template_for_app() {
  local app_id=$1 mode=$2 channel=$3
  local raw rendered personalized filename expected_image
  ensure_work_dir
  filename=$(app_template_file "$app_id")
  raw="$WORK_DIR/raw-$filename"
  rendered="$WORK_DIR/rendered-$filename"
  personalized="$WORK_DIR/$filename"

  fetch_template "$app_id" "$raw" || return 1
  validate_template "$raw" "$app_id" || return 1
  render_template "$raw" "$rendered" "$app_id" "$channel" "$mode" \
    "${LOCAL_REGISTRY_PREFIX:-}" "${LOCAL_REGISTRY_SCHEME:-http}" || return 1
  if [[ "$mode" == "local" ]]; then
    expected_image=$(local_image "$app_id" "$channel" "$LOCAL_REGISTRY_PREFIX")
  else
    expected_image=$(public_image "$app_id" "$channel")
  fi
  validate_rendered_template "$rendered" "$expected_image" || return 1
  printf '\n%sConfiguración Docker de %s%s\n' "$C_BOLD" "$(app_label "$app_id")" "$C_RESET"
  personalize_template "$rendered" "$personalized" || return 1
  APP_TEMPLATE_PATHS[$app_id]=$personalized
}

prepare_local_registry_requirement() {
  local container port state
  if container=$(find_local_registry_container); then
    LOCAL_REGISTRY_CONTAINER=$container
    port=$(registry_port_from_container "$container") || \
      die "Local Registry existe, pero no publica el puerto interno 5000."
    LOCAL_REGISTRY_PREFIX="127.0.0.1:$port"
    LOCAL_REGISTRY_SCHEME="http"
    state=$(container_state "$container")
    if [[ "$state" == "running" ]]; then
      registry_reachable "$LOCAL_REGISTRY_PREFIX" "$LOCAL_REGISTRY_SCHEME" || \
        die "Local Registry está arrancado, pero no responde en http://$LOCAL_REGISTRY_PREFIX/v2/."
      APP_ACTIONS[local-registry]="keep"
      success "Local Registry encontrado en $LOCAL_REGISTRY_PREFIX. Se reutilizará."
    elif [[ "$state" == "exited" || "$state" == "created" ]]; then
      APP_ACTIONS[local-registry]="start"
      info "Local Registry ya está instalado y se arrancará antes de continuar."
    else
      error "Local Registry existe pero su estado requiere revisión. No se modificará."
      return 1
    fi
    return 0
  fi

  LOCAL_REGISTRY_BOOTSTRAP=true
  APP_CHANNELS[local-registry]="stable"
  APP_MODES[local-registry]="public"
  APP_ACTIONS[local-registry]="create"
  info "No hay un Local Registry instalado. Zero Launcher lo preparará primero."
  prepare_template_for_app local-registry public stable || return 1
  port=$(get_config_value_by_target "${APP_TEMPLATE_PATHS[local-registry]}" 5000)
  LOCAL_REGISTRY_PREFIX="127.0.0.1:$port"
  LOCAL_REGISTRY_SCHEME="http"
}

selected_uses_local_registry() {
  local app_id
  for app_id in "${SELECTED_APPS[@]}"; do
    [[ "${APP_MODES[$app_id]:-public}" == "local" ]] && return 0
  done
  return 1
}

app_is_selected() {
  local wanted=$1
  local app_id
  for app_id in "${SELECTED_APPS[@]}"; do
    [[ "$app_id" == "$wanted" ]] && return 0
  done
  return 1
}

prepare_actions_and_templates() {
  local app_id state
  if selected_uses_local_registry; then
    prepare_local_registry_requirement || return 1
  fi

  for app_id in "${SELECTED_APPS[@]}"; do
    state=${APP_STATES[$app_id]}
    if [[ "$app_id" == "local-registry" && -n "${APP_ACTIONS[$app_id]:-}" ]]; then
      continue
    fi
    case "$state" in
      not-installed)
        APP_ACTIONS[$app_id]="create"
        prepare_template_for_app "$app_id" "${APP_MODES[$app_id]}" "${APP_CHANNELS[$app_id]}" || return 1
        ;;
      running) APP_ACTIONS[$app_id]="keep" ;;
      exited|created) APP_ACTIONS[$app_id]="start" ;;
      *) APP_ACTIONS[$app_id]="review" ;;
    esac
  done
}

action_label() {
  case "$1" in
    create) printf '%s' "instalar" ;;
    start) printf '%s' "arrancar sin reinstalar" ;;
    keep) printf '%s' "conservar; ya funciona" ;;
    review) printf '%s' "no modificar; necesita revisión" ;;
    *) printf '%s' "sin cambios" ;;
  esac
}

confirm_plan() {
  local app_id action mode channel image reply
  local -a plan_apps=("${SELECTED_APPS[@]}")
  if "$LOCAL_REGISTRY_BOOTSTRAP" && ! app_is_selected local-registry; then
    plan_apps=("local-registry" "${plan_apps[@]}")
  fi

  printf '\n%sResumen de la instalación%s\n\n' "$C_BOLD" "$C_RESET"
  printf '  %-18s %-16s %-10s %s\n' "APLICACIÓN" "ORIGEN" "VERSIÓN" "ACCIÓN"
  printf '  %-18s %-16s %-10s %s\n' "----------" "------" "-------" "------"
  for app_id in "${plan_apps[@]}"; do
    action=${APP_ACTIONS[$app_id]:-keep}
    mode=${APP_MODES[$app_id]:-public}
    channel=${APP_CHANNELS[$app_id]:-installed}
    if [[ "$action" == "create" ]]; then
      if [[ "$mode" == "local" ]]; then
        image=$(local_image "$app_id" "$channel" "$LOCAL_REGISTRY_PREFIX")
      else
        image=$(public_image "$app_id" "$channel")
      fi
    else
      image=${APP_IMAGES[$app_id]:--}
    fi
    printf '  %-18s %-16s %-10s %s\n' \
      "$(app_label "$app_id")" \
      "$(if [[ "$mode" == "local" ]]; then printf 'Local Registry'; else printf 'GHCR'; fi)" \
      "$channel" "$(action_label "$action")"
    [[ "$action" != "create" ]] || printf '    Imagen: %s\n' "$image"
  done
  printf '\n'
  read -r -p '¿Ejecutar este plan? [S/n]: ' reply
  [[ ! "$reply" =~ ^[Nn]$ ]]
}

sync_image_to_local_registry() {
  local app_id=$1 channel=$2
  local source_image destination_image
  local source_existed=false
  source_image=$(public_image "$app_id" "$channel")
  destination_image=$(local_image "$app_id" "$channel" "$LOCAL_REGISTRY_PREFIX")

  if docker manifest inspect "$destination_image" >/dev/null 2>&1; then
    info "La imagen local de $(app_label "$app_id") ya está disponible."
    docker pull "$destination_image" || return 1
    return 0
  fi

  docker image inspect "$source_image" >/dev/null 2>&1 && source_existed=true
  info "Copiando $(app_label "$app_id") desde GHCR a Local Registry..."
  docker pull "$source_image" || return 1
  docker tag "$source_image" "$destination_image" || return 1
  if ! docker push "$destination_image"; then
    docker image rm "$destination_image" >/dev/null 2>&1 || true
    return 1
  fi
  docker pull "$destination_image" >/dev/null || return 1
  if ! "$source_existed"; then
    docker image rm "$source_image" >/dev/null 2>&1 || true
  fi
  success "Imagen guardada y comprobada en $destination_image"
}

prepare_image() {
  local app_id=$1
  local mode=${APP_MODES[$app_id]} channel=${APP_CHANNELS[$app_id]} image
  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$mode" == "local" ]]; then
      info "Simulación: se copiaría $(public_image "$app_id" "$channel") a Local Registry."
    else
      info "Simulación: se descargaría $(public_image "$app_id" "$channel")."
    fi
    return 0
  fi
  if [[ "$mode" == "local" && "$app_id" != "local-registry" ]]; then
    sync_image_to_local_registry "$app_id" "$channel"
  else
    image=$(public_image "$app_id" "$channel")
    info "Descargando la imagen de $(app_label "$app_id")..."
    docker pull "$image"
  fi
}

prepare_data_directory() {
  local path=$1 app_id=$2 target=$3
  [[ ! -d "$path" ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Simulación: se crearía la carpeta $path"
    if [[ "$app_id" == "rtfm" && "$target" == "/data" ]]; then
      info "Simulación: la carpeta nueva permitiría escribir a RTFM (10001:10001)."
    fi
    return 0
  fi
  (umask 022; mkdir -p -- "$path") || return 1
  if [[ "$app_id" == "rtfm" && "$target" == "/data" ]]; then
    if ! chown 10001:10001 -- "$path" || ! chmod 0700 -- "$path"; then
      error "No se pudieron preparar los permisos de la carpeta nueva de RTFM: $path"
      return 1
    fi
  fi
  success "Carpeta creada: $path"
}

create_container_from_template() {
  local template=$1
  local app_id=${2:-}
  local name repository network privileged webui icon extra_params post_args
  local line type target mode value
  local -a docker_args=() extra_args=() after_image=()

  name=$(xml_tag_value "$template" Name)
  if [[ -z "$app_id" && "$name" == "$(app_container rtfm)" ]]; then app_id=rtfm; fi
  repository=$(xml_tag_value "$template" Repository)
  network=$(xml_tag_value "$template" Network)
  privileged=$(xml_tag_value "$template" Privileged)
  webui=$(xml_tag_value "$template" WebUI)
  icon=$(xml_tag_value "$template" Icon)
  extra_params=$(xml_tag_value "$template" ExtraParams)
  post_args=$(xml_tag_value "$template" PostArgs)

  docker_args=(run -d --name "$name" --network "$network")
  [[ "$privileged" != "true" ]] || docker_args+=(--privileged)
  docker_args+=(
    --label "net.unraid.docker.managed=dockerman"
    --label "net.unraid.docker.webui=$webui"
    --label "net.unraid.docker.icon=$icon"
  )
  if [[ -n "$extra_params" ]]; then
    local IFS=' '
    read -r -a extra_args <<<"$extra_params"
    docker_args+=("${extra_args[@]}")
  fi

  while IFS= read -r line; do
    [[ "$line" == *"<Config "* ]] || continue
    type=$(xml_attr "$line" Type)
    target=$(xml_attr "$line" Target)
    mode=$(xml_attr "$line" Mode)
    value=$(xml_unescape "$(xml_config_value "$line")")
    case "$type" in
      Port) docker_args+=(-p "$value:$target/${mode:-tcp}") ;;
      Path)
        if [[ "$target" == "/var/run/docker.sock" ]]; then
          if [[ "$SIMULATION_MODE" != "true" ]]; then
            [[ -S "$value" ]] || die "No existe el socket de Docker: $value"
          fi
        else
          prepare_data_directory "$value" "$app_id" "$target" || return 1
        fi
        docker_args+=(-v "$value:$target:${mode:-rw}")
        ;;
      Variable) docker_args+=(-e "$target=$value") ;;
      *) die "No se puede crear $name: tipo de dato desconocido $type." ;;
    esac
  done <"$template"

  if [[ -n "$post_args" ]]; then
    local IFS=' '
    read -r -a after_image <<<"$post_args"
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Simulación: se crearía el contenedor $name."
    return 0
  fi
  if docker inspect "$name" >/dev/null 2>&1; then
    error "$name ya existe. Se conserva y no se creará un duplicado."
    return 1
  fi
  if ! docker "${docker_args[@]}" "$repository" "${after_image[@]}" >/dev/null; then
    docker inspect "$name" >/dev/null 2>&1 && docker rm -f "$name" >/dev/null 2>&1 || true
    error "No se pudo crear $name. No se ha dejado un contenedor incompleto."
    return 1
  fi
  success "Contenedor creado y arrancado: $name"
}

yaml_string() {
  local value=$1
  value=${value//\$/\$\$}
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

render_compose() {
  local template=$1 destination=$2 app_id=$3
  local extra line type target mode value arg option argument i
  local restart="unless-stopped" user="" pids="" init=false read_only=false
  local -a args=() caps_add=() caps_drop=() security=() tmpfs=() hosts=() labels=() command_args=()
  extra=$(xml_tag_value "$template" ExtraParams)
  IFS=' ' read -r -a args <<<"$extra"
  for ((i=0; i<${#args[@]}; i++)); do
    arg=${args[$i]}; option=${arg%%=*}; argument=""
    if [[ "$arg" == *=* ]]; then
      argument=${arg#*=}
    elif [[ "$option" != "--init" && "$option" != "--read-only" ]]; then
      i=$((i+1)); argument=${args[$i]:-}
      [[ -n "$argument" ]] || { error "Falta un valor para $option."; return 1; }
    fi
    case "$option" in
      --restart) restart=$argument ;;
      --user) user=$argument ;;
      --pids-limit) pids=$argument ;;
      --init) init=true ;;
      --read-only) read_only=true ;;
      --cap-add) caps_add+=("$argument") ;;
      --cap-drop) caps_drop+=("$argument") ;;
      --security-opt) security+=("$argument") ;;
      --tmpfs) tmpfs+=("$argument") ;;
      --add-host) hosts+=("$argument") ;;
      --label) labels+=("$argument") ;;
      *) error "No se puede trasladar $option a Compose. No se instalará una versión incompleta."; return 1 ;;
    esac
  done
  [[ -z "$pids" || "$pids" =~ ^[0-9]+$ ]] || return 1
  extra=$(xml_tag_value "$template" PostArgs)
  IFS=' ' read -r -a command_args <<<"$extra"
  {
    printf '# Preparado por Zero Launcher %s. Una aplicación, un contenedor.\nservices:\n  %s:\n' "$PROGRAM_VERSION" "$app_id"
    printf '    image: %s\n' "$(yaml_string "$(xml_tag_value "$template" Repository)")"
    printf '    container_name: %s\n' "$(yaml_string "$(xml_tag_value "$template" Name)")"
    printf '    network_mode: %s\n' "$(yaml_string "$(xml_tag_value "$template" Network)")"
    printf '    restart: %s\n    init: %s\n    read_only: %s\n' "$(yaml_string "$restart")" "$init" "$read_only"
    [[ -z "$user" ]] || printf '    user: %s\n' "$(yaml_string "$user")"
    [[ -z "$pids" ]] || printf '    pids_limit: %s\n' "$pids"
    [[ "$(xml_tag_value "$template" Privileged)" != "true" ]] || printf '    privileged: true\n'
    printf '    labels:\n      - %s\n' "$(yaml_string "io.zero-launcher.owner=$app_id")"
    for value in "${labels[@]}"; do printf '      - %s\n' "$(yaml_string "$value")"; done
    for option in cap_add cap_drop security_opt tmpfs extra_hosts command; do
      local -a values=()
      case "$option" in
        cap_add) values=("${caps_add[@]}") ;; cap_drop) values=("${caps_drop[@]}") ;;
        security_opt) values=("${security[@]}") ;; tmpfs) values=("${tmpfs[@]}") ;;
        extra_hosts) values=("${hosts[@]}") ;; command) values=("${command_args[@]}") ;;
      esac
      if ((${#values[@]})); then
        printf '    %s:\n' "$option"
        for value in "${values[@]}"; do printf '      - %s\n' "$(yaml_string "$value")"; done
      fi
    done
    for option in Port Path Variable; do
      local heading=false
      while IFS= read -r line; do
        [[ "$line" == *'<Config '* ]] || continue
        type=$(xml_attr "$line" Type)
        [[ "$type" == "$option" ]] || continue
        target=$(xml_attr "$line" Target); mode=$(xml_attr "$line" Mode)
        value=$(xml_unescape "$(xml_config_value "$line")")
        if [[ "$heading" == "false" ]]; then
          case "$option" in
            Port) printf '    ports:\n' ;; Path) printf '    volumes:\n' ;; Variable) printf '    environment:\n' ;;
          esac
          heading=true
        fi
        case "$option" in
          Port) printf '      - %s\n' "$(yaml_string "$value:$target/${mode:-tcp}")" ;;
          Path)
            printf '      - type: bind\n        source: %s\n        target: %s\n        read_only: %s\n        bind:\n          create_host_path: false\n' \
              "$(yaml_string "$value")" "$(yaml_string "$target")" "$(if [[ "$mode" == "ro" ]]; then printf true; else printf false; fi)"
            ;;
          Variable) printf '      %s: %s\n' "$(yaml_string "$target")" "$(yaml_string "$value")" ;;
        esac
      done <"$template"
    done
  } >"$destination"
}

create_container_from_compose() {
  local template=$1 app_id=$2
  local rendered destination name line target value backup
  ensure_work_dir
  rendered="$WORK_DIR/$app_id.compose.yaml"
  destination="$COMPOSE_DIR/$app_id/compose.yaml"
  name=$(app_container "$app_id")
  render_compose "$template" "$rendered" "$app_id" || return 1
  if [[ "$DRY_RUN" != "true" ]]; then
    [[ "$COMPOSE_DIR" == /* && "$COMPOSE_DIR" != "/" ]] || { error "La carpeta Compose debe ser una ruta absoluta y concreta."; return 1; }
    if docker inspect "$name" >/dev/null 2>&1; then
      error "$name ya existe. Se conserva y no se creará un duplicado."
      return 1
    fi
    docker compose -p "zero-$app_id" -f "$rendered" config --quiet || return 1
  fi
  while IFS= read -r line; do
    [[ "$line" == *'<Config '* && "$(xml_attr "$line" Type)" == "Path" ]] || continue
    target=$(xml_attr "$line" Target); value=$(xml_unescape "$(xml_config_value "$line")")
    if [[ "$DRY_RUN" == "true" ]]; then
      info "Simulación: se utilizaría la ruta $value"
    elif [[ "$target" == "/var/run/docker.sock" ]]; then
      [[ -S "$value" ]] || { error "No existe el socket Docker $value."; return 1; }
    elif [[ "$target" == "/npm" || "$target" == "/npm-letsencrypt" ]]; then
      [[ -d "$value" ]] || { error "La ruta $value debe contener los datos del NPM existente. No se creará vacía."; return 1; }
    else
      prepare_data_directory "$value" "$app_id" "$target" || return 1
    fi
  done <"$template"
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Simulación: se guardaría $destination y se crearía el contenedor $name con Compose."
    return 0
  fi
  mkdir -p -- "$(dirname -- "$destination")" || return 1
  if [[ -f "$destination" ]]; then
    backup="$destination.$(date '+%Y%m%d-%H%M%S').bak"
    cp -p -- "$destination" "$backup" || return 1
    info "Respaldo creado en $backup"
  fi
  install -m 0600 "$rendered" "$destination.zero-launcher.$$" || return 1
  mv -f -- "$destination.zero-launcher.$$" "$destination" || return 1
  if ! docker compose -p "zero-$app_id" -f "$destination" up -d --no-build --pull never; then
    if [[ "$(docker inspect --format '{{index .Config.Labels "io.zero-launcher.owner"}}' "$name" 2>/dev/null || true)" == "$app_id" ]]; then
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
    error "No se pudo arrancar $name. Se conserva su archivo Compose para revisar el problema."
    return 1
  fi
  success "Contenedor arrancado: $name · Configuración: $destination"
}

wait_container_ready() {
  local container=$1 attempt running health
  for attempt in {1..30}; do
    running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)
    if [[ "$running" == "true" && ( -z "$health" || "$health" == "healthy" ) ]]; then
      return 0
    fi
    [[ "$health" != "unhealthy" ]] || return 1
    sleep 1
  done
  return 1
}

wait_registry_ready() {
  local attempt
  for attempt in {1..30}; do
    registry_reachable "$LOCAL_REGISTRY_PREFIX" "$LOCAL_REGISTRY_SCHEME" && return 0
    sleep 1
  done
  return 1
}

execute_app() {
  local app_id=$1 action container
  action=${APP_ACTIONS[$app_id]}
  if [[ "$app_id" == "local-registry" && -n "$LOCAL_REGISTRY_CONTAINER" ]]; then
    container=$LOCAL_REGISTRY_CONTAINER
  else
    container=$(app_container "$app_id")
  fi
  [[ -z "${EXECUTED_APPS[$app_id]:-}" ]] || return 0
  EXECUTED_APPS[$app_id]=true

  case "$action" in
    keep) success "$(app_label "$app_id") ya está funcionando; no se modifica." ;;
    start)
      if [[ "$DRY_RUN" == "true" ]]; then
        info "Simulación: se arrancaría $container."
      else
        docker start "$container" >/dev/null || return 1
        wait_container_ready "$container" || return 1
        success "$container arrancado sin reinstalarlo."
      fi
      ;;
    create)
      prepare_image "$app_id" || return 1
      if [[ "$PLATFORM" == "linux" ]]; then
        create_container_from_compose "${APP_TEMPLATE_PATHS[$app_id]}" "$app_id" || return 1
      else
        install_template_file "${APP_TEMPLATE_PATHS[$app_id]}" || return 1
        create_container_from_template "${APP_TEMPLATE_PATHS[$app_id]}" "$app_id" || return 1
      fi
      if [[ "$DRY_RUN" != "true" ]]; then
        wait_container_ready "$container" || {
          error "$container se creó, pero no ha quedado operativo."
          return 1
        }
      fi
      ;;
    review) warn "$(app_label "$app_id") no se modifica porque su estado requiere revisión manual." ;;
  esac
}

execute_plan() {
  local app_id
  if selected_uses_local_registry; then
    execute_app local-registry || return 1
    if [[ "$DRY_RUN" != "true" ]]; then
      wait_registry_ready || {
        error "Local Registry no responde. No se instalarán aplicaciones que dependan de él."
        return 1
      }
      success "Local Registry está preparado para recibir imágenes."
    fi
  fi
  for app_id in "${SELECTED_APPS[@]}"; do
    execute_app "$app_id" || return 1
  done
}

reset_installation_state() {
  local app_id
  APP_MODES=()
  APP_CHANNELS=()
  APP_ACTIONS=()
  APP_TEMPLATE_PATHS=()
  EXECUTED_APPS=()
  RESERVED_PORTS=()
  SELECTED_APPS=()
  ALL_APPS_SELECTED=false
  LOCAL_REGISTRY_CONTAINER=""
  LOCAL_REGISTRY_PREFIX=""
  LOCAL_REGISTRY_SCHEME="http"
  LOCAL_REGISTRY_BOOTSTRAP=false
  INSTALL_MODE=""
  for app_id in "${APP_IDS[@]}"; do
    APP_STATES[$app_id]="not-installed"
    APP_IMAGES[$app_id]=""
  done
}

run_installation_flow() {
  local app_id
  choose_install_mode || return 1
  choose_apps || return 1
  apply_install_mode
  choose_channels || { warn "Instalación cancelada."; return 0; }
  prepare_actions_and_templates || return 1
  for app_id in "${SELECTED_APPS[@]}"; do
    if [[ "${APP_ACTIONS[$app_id]}" == "review" ]]; then
      warn "$(app_label "$app_id") tiene un estado que Zero Launcher no modificará."
    fi
  done
  confirm_plan || { warn "Operación cancelada."; return 0; }
  execute_plan || return 1
  printf '\n'
  if [[ "$SIMULATION_MODE" == "true" ]]; then
    success "Simulación terminada. No se ha modificado el equipo."
    printf 'El recorrido representa: %s.\n' "$SYSTEM_LABEL"
  else
    success "Proceso terminado."
    if [[ "$PLATFORM" == "unraid" ]]; then
      printf 'Los contenedores creados aparecen en la página Docker de Unraid.\n'
    else
      printf 'Los archivos de instalación están en %s/<aplicación>/compose.yaml.\n' "$COMPOSE_DIR"
    fi
    printf 'Completa la configuración funcional desde la interfaz web de cada aplicación.\n'
  fi
}

prepare_installation() {
  local result=0
  preflight_platform || return 1
  install_download_tools || return 1
  clear_screen
  banner
  reset_installation_state
  detect_apps
  run_installation_flow || result=$?
  cleanup_work_dir
  WORK_DIR=""
  return "$result"
}

simulate_new_server() {
  local previous_dry_run=$DRY_RUN
  local previous_platform=$PLATFORM previous_label=$SYSTEM_LABEL previous_data=$DATA_ROOT previous_log=$LOG_DIR
  local previous_arch=$MACHINE_ARCH
  local result=0
  basic_preflight
  choose_simulation_platform || return 1
  install_download_tools || {
    PLATFORM=$previous_platform; SYSTEM_LABEL=$previous_label; DATA_ROOT=$previous_data; LOG_DIR=$previous_log; MACHINE_ARCH=$previous_arch
    return 1
  }
  SIMULATION_MODE=true
  DRY_RUN=true
  clear_screen
  banner
  printf '%sMODO SIMULADOR%s\n' "$C_YELLOW" "$C_RESET"
  printf 'Se simulará %s, sin aplicaciones instaladas.\n' "$SYSTEM_LABEL"
  printf 'No se escribirán plantillas, no se descargarán imágenes y no se crearán contenedores.\n\n'
  reset_installation_state
  run_installation_flow || result=$?
  cleanup_work_dir
  WORK_DIR=""
  DRY_RUN=$previous_dry_run
  SIMULATION_MODE=false
  PLATFORM=$previous_platform; SYSTEM_LABEL=$previous_label; DATA_ROOT=$previous_data; LOG_DIR=$previous_log; MACHINE_ARCH=$previous_arch
  return "$result"
}

image_origin_label() {
  case "$1" in
    ghcr.io/*) printf '%s' "GHCR" ;;
    127.0.0.1:*|localhost:*) printf '%s' "Local Registry" ;;
    *) printf '%s' "otro origen" ;;
  esac
}

check_installations() {
  local app_id container state image
  preflight_platform false || return 1
  clear_screen
  banner
  detect_apps
  printf '%sEstado de las instalaciones%s\n\n' "$C_BOLD" "$C_RESET"
  printf '  %-18s %-28s %s\n' "APLICACIÓN" "ESTADO" "ORIGEN"
  printf '  %-18s %-28s %s\n' "----------" "------" "------"
  for app_id in "${APP_IDS[@]}"; do
    container=$(app_container "$app_id")
    state=${APP_STATES[$app_id]}
    image=${APP_IMAGES[$app_id]}
    if [[ "$state" == "not-installed" ]]; then
      printf '  %-18s %-28s %s\n' "$(app_label "$app_id")" "no instalado" "-"
    else
      printf '  %-18s %-28s %s\n' \
        "$(app_label "$app_id")" "$(state_label "$state")" "$(image_origin_label "$image")"
      printf '    Contenedor: %s · Imagen: %s\n' "$container" "$image"
    fi
  done
}

show_about() {
  clear_screen
  banner
  printf '%s\n' 'Zero Launcher instala y comprueba la suite en Unraid y Linux, incluida Raspberry Pi de 64 bits.'
  printf '%s\n' 'Cada aplicación se despliega como un único contenedor.'
  printf '%s\n' 'Las imágenes pueden obtenerse desde GHCR o guardarse en Local Registry.'
  printf '%s\n' 'El modo simulador permite recorrer una instalación nueva sin realizar cambios.'
  printf '%s\n' 'Al salir se guarda un registro de la sesión en la carpeta elegida.'
  printf '%s\n' 'Soporte comunitario de Unraides:'
  printf '  %s\n' "$SUPPORT_URL"
  printf '%s\n' 'Licencia: Apache-2.0.'
}

show_help() {
  cat <<'EOF'
Uso: zero-launcher.sh [opción]

Opciones:
  --dry-run   Recorre el asistente sin escribir plantillas ni crear contenedores.
  --help      Muestra esta ayuda.
  --version   Muestra la versión.
EOF
}

main_menu() {
  local reply
  while true; do
    clear_screen
    banner
    printf '%sMenú principal%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  %s1.%s Instalar aplicaciones\n' "$C_CYAN" "$C_RESET"
    printf '  %s2.%s Simular una instalación nueva\n' "$C_CYAN" "$C_RESET"
    printf '  %s3.%s Comprobar instalaciones\n' "$C_CYAN" "$C_RESET"
    printf '  %s4.%s Acerca de Zero Launcher\n' "$C_CYAN" "$C_RESET"
    printf '  %s0.%s Salir\n\n' "$C_CYAN" "$C_RESET"
    read -r -p 'Selección: ' reply || return 1
    case "$reply" in
      1) prepare_installation || true; pause ;;
      2) simulate_new_server || true; pause ;;
      3) check_installations || true; pause ;;
      4) show_about; pause ;;
      0) save_session_log; return 0 ;;
      *) warn "Selección no válida."; pause ;;
    esac
  done
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --simulator) : ;; # Compatibilidad: la simulación se elige ahora en el menú.
      --help|-h) show_help; return 0 ;;
      --version|-V) printf '%s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION"; return 0 ;;
      *) die "Opción desconocida: $1" ;;
    esac
    shift
  done
  basic_preflight
  detect_platform
  start_session_log
  main_menu
}

if [[ "${ZERO_LAUNCHER_SOURCE_ONLY:-false}" != "true" ]]; then
  main "$@"
fi

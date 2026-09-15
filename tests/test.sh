#!/usr/bin/env bash
# Copyright 2026 Ezrael
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd)
readonly PROJECT_DIR
TEST_WORK_DIR=$(mktemp -d /tmp/zero-launcher-tests.XXXXXX)
readonly TEST_WORK_DIR

cleanup_tests() { rm -rf -- "$TEST_WORK_DIR"; }
trap cleanup_tests EXIT

export ZERO_LAUNCHER_SOURCE_ONLY=true
export ZERO_LAUNCHER_TESTING=true
export ZERO_LAUNCHER_ASSUME_IMAGES=true
export NO_COLOR=1

# shellcheck disable=SC1091
source "$PROJECT_DIR/zero-launcher.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3 (esperado: $1; obtenido: $2)"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$3"
}

make_fixture() {
  local app_id=$1
  local destination=$2
  local name repo
  name=$(app_container "$app_id")
  repo=$(app_repo_slug "$app_id")
  printf '%s\n' \
    '<?xml version="1.0"?>' \
    '<Container version="2">' \
    "  <Name>$name</Name>" \
    "  <Repository>ghcr.io/ezr43l/$repo:stable</Repository>" \
    "  <Registry>https://github.com/Ezr43l/$repo</Registry>" \
    '  <Network>bridge</Network>' \
    '  <Shell>sh</Shell>' \
    '  <Privileged>false</Privileged>' \
    '  <WebUI>http://[IP]:[PORT:45454]/</WebUI>' \
    "  <TemplateURL>https://example.invalid/$repo.xml</TemplateURL>" \
    '  <Icon>https://example.invalid/icon.png</Icon>' \
    "  <Project>https://github.com/Ezr43l/$repo</Project>" \
    '  <ExtraParams>--restart=unless-stopped</ExtraParams>' \
    '  <PostArgs/>' \
    '  <Config Name="Puerto" Target="45454" Default="45454" Mode="tcp" Description="Puerto web." Type="Port" Display="always" Required="true" Mask="false">45454</Config>' \
    "  <Config Name=\"Datos\" Target=\"/data\" Default=\"$TEST_WORK_DIR/data\" Mode=\"rw\" Description=\"Datos.\" Type=\"Path\" Display=\"always\" Required=\"true\" Mask=\"false\">$TEST_WORK_DIR/data</Config>" \
    '</Container>' >"$destination"
}

test_metadata() {
  assert_eq "local-registry-s" "$(app_repo_slug local-registry)" "Slug de Local Registry"
  assert_eq "my-Keepalived.xml" "$(app_template_file keepalived)" "Plantilla de Keepalived"
  assert_eq "ghcr.io/ezr43l/rtfm-s:dev" "$(public_image rtfm dev)" "Imagen de desarrollo"
  assert_eq "https://raw.githubusercontent.com/Ezr43l/rtfm-s/main/unraid/my-RTFM.xml" \
    "$(template_url rtfm)" "La plantilla debe salir siempre de main"
}

test_registry_validation() {
  validate_registry_prefix "registry.example.net:5000/ezrael" || fail "Registro válido rechazado"
  ! validate_registry_prefix "http://registry.example.net:5000" || fail "Se aceptó un protocolo"
  ! validate_registry_prefix "registry.example.net:5000/" || fail "Se aceptó una barra final"
}

test_xml_values() {
  local original='ruta & valor <privado>'
  assert_eq "$original" "$(xml_unescape "$(xml_escape "$original")")" "Escape XML"
  valid_port 5000 || fail "Puerto válido rechazado"
  ! valid_port 70000 || fail "Puerto fuera de rango aceptado"
}

test_public_render() {
  local source="$TEST_WORK_DIR/rtfm-source.xml"
  local output="$TEST_WORK_DIR/rtfm-public.xml"
  make_fixture rtfm "$source"
  validate_template "$source" rtfm || fail "Plantilla pública válida rechazada"
  render_template "$source" "$output" rtfm dev public
  assert_contains "$output" '<Repository>ghcr.io/ezr43l/rtfm-s:dev</Repository>' \
    "No se generó el repositorio público"
  assert_contains "$output" '<TemplateURL>https://example.invalid/rtfm-s.xml</TemplateURL>' \
    "La variante pública alteró TemplateURL"
}

test_local_render() {
  local source="$TEST_WORK_DIR/vault-source.xml"
  local output="$TEST_WORK_DIR/vault-local.xml"
  make_fixture vault-guardian "$source"
  render_template "$source" "$output" vault-guardian stable local \
    "127.0.0.1:5000" "http"
  assert_contains "$output" \
    '<Repository>127.0.0.1:5000/vault-guardian-s:stable</Repository>' \
    "No se generó el repositorio local"
  assert_contains "$output" '<Registry>http://127.0.0.1:5000</Registry>' \
    "No se generó la dirección local"
  assert_contains "$output" '<TemplateURL/>' "La plantilla local conserva la actualización remota"
}

test_local_registry_bootstrap() {
  local source="$TEST_WORK_DIR/registry-source.xml"
  local output="$TEST_WORK_DIR/registry-local.xml"
  make_fixture local-registry "$source"
  render_template "$source" "$output" local-registry stable local "127.0.0.1:5000" "http"
  assert_contains "$output" \
    '<Repository>ghcr.io/ezr43l/local-registry-s:stable</Repository>' \
    "Local Registry depende de sí mismo"
}

test_config_lookup() {
  local source="$TEST_WORK_DIR/config.xml"
  make_fixture rtfm "$source"
  assert_eq "45454" "$(get_config_value_by_target "$source" 45454)" "Lectura del puerto"
  assert_eq "$TEST_WORK_DIR/data" "$(get_config_value_by_target "$source" /data)" "Lectura de ruta"
}

test_personalize_defaults() {
  local source="$TEST_WORK_DIR/personalize-source.xml"
  local output="$TEST_WORK_DIR/personalized.xml"
  make_fixture rtfm "$source"
  port_in_use() { return 1; }
  personalize_template "$source" "$output" <<'EOF'


EOF
  assert_contains "$output" '>45454</Config>' "No se conservó el puerto predeterminado"
  assert_contains "$output" ">$TEST_WORK_DIR/data</Config>" "No se conservó la ruta predeterminada"
}

test_required_npm_path_in_simulator() {
  local source="$TEST_WORK_DIR/npm-required-source.xml"
  local rewritten="$TEST_WORK_DIR/npm-required-rewritten.xml"
  local output="$TEST_WORK_DIR/npm-required-personalized.xml"
  local real_output="$TEST_WORK_DIR/npm-required-real.xml"
  local line transcript
  make_fixture npm-guardian "$source"
  unset 'RESERVED_PORTS[45454]'

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *'Target="/data"'* ]]; then
      printf '%s\n' '<Config Name="Datos de NPM" Target="/npm" Default="" Mode="rw" Description="Directorio data del NPM local." Type="Path" Display="always" Required="true" Mask="false"></Config>'
    else
      printf '%s\n' "$line"
    fi
  done <"$source" >"$rewritten"

  SIMULATION_MODE=true
  transcript=$(personalize_template "$rewritten" "$output" 2>&1 <<'EOF'


EOF
  )
  SIMULATION_MODE=false

  assert_contains "$output" '>/mnt/user/appdata/nginx-proxy-manager/data</Config>' \
    "El simulador no aplicó la ruta de ejemplo de NPM"
  [[ "$transcript" == *"Valor de ejemplo para la simulación"* ]] || \
    fail "El simulador no explicó que la ruta de NPM era un ejemplo"

  unset 'RESERVED_PORTS[45454]'
  transcript=$(personalize_template "$rewritten" "$real_output" 2>&1 <<EOF


$TEST_WORK_DIR/npm-real
EOF
  )
  assert_contains "$real_output" ">$TEST_WORK_DIR/npm-real</Config>" \
    "La instalación real no aceptó la ruta indicada para NPM"
  [[ "$transcript" == *"Ejemplo habitual: /mnt/user/appdata/nginx-proxy-manager/data"* ]] || \
    fail "La instalación real no mostró un ejemplo para la ruta de NPM"
  [[ "$transcript" == *"No hay un valor predeterminado"* ]] || \
    fail "La instalación real no explicó por qué la ruta era obligatoria"
}

test_simulator_is_isolated() {
  SIMULATION_MODE=true
  ! port_in_use 5000 || fail "El simulador está comprobando puertos reales"
  ! find_local_registry_container || fail "El simulador ha detectado un contenedor real"
  SIMULATION_MODE=false
}

test_multiple_app_selector() {
  reset_app_marks
  ! all_apps_marked || fail "La selección inicial viene marcada"
  ! commit_app_marks || fail "Se aceptó una selección vacía"
  toggle_app_mark 4
  all_apps_marked || fail "La opción Instalar todas no marcó el conjunto"
  toggle_app_mark 0
  [[ "${APP_MARKS[keepalived]}" == "false" ]] || fail "No se desmarcó Keepalived"
  commit_app_marks || fail "No se confirmó una selección parcial"
  [[ ${#SELECTED_APPS[@]} -eq 3 ]] || fail "La selección parcial no contiene tres aplicaciones"
  [[ "$ALL_APPS_SELECTED" == "false" ]] || fail "La selección parcial figura como completa"
  toggle_app_mark 4
  commit_app_marks || fail "No se volvió a marcar el conjunto"
  [[ "$ALL_APPS_SELECTED" == "true" ]] || fail "La selección completa no se reconoció"
}

test_atomic_install_and_backup() {
  local first="$TEST_WORK_DIR/first/my-RTFM.xml"
  local second="$TEST_WORK_DIR/second/my-RTFM.xml"
  mkdir -p -- "$(dirname -- "$first")" "$(dirname -- "$second")"
  printf '%s\n' 'primera' >"$first"
  printf '%s\n' 'segunda' >"$second"
  TARGET_DIR="$TEST_WORK_DIR/templates-user"
  BACKUP_DIR="$TEST_WORK_DIR/backups"
  DRY_RUN=false
  install_template_file "$first" >/dev/null
  install_template_file "$second" >/dev/null
  assert_contains "$TARGET_DIR/my-RTFM.xml" "segunda" "No se instaló la segunda plantilla"
  [[ $(find "$BACKUP_DIR" -type f -name 'my-RTFM.xml' | wc -l) -eq 1 ]] || \
    fail "No se creó exactamente un respaldo"
}

test_dry_container_creation() {
  local source="$TEST_WORK_DIR/create.xml"
  local output
  make_fixture keepalived "$source"
  DRY_RUN=true
  output=$(create_container_from_template "$source")
  [[ "$output" == *"se crearía el contenedor Keepalived"* ]] || \
    fail "La creación simulada no reconoce el contenedor"
}

test_invalid_template() {
  local source="$TEST_WORK_DIR/invalid.xml"
  make_fixture rtfm "$source"
  ! validate_template "$source" keepalived >/dev/null 2>&1 || \
    fail "Se aceptó una plantilla con nombre incorrecto"
}

test_main_menu_wraps_simulator_and_saves_log() {
  local fixture_dir="$TEST_WORK_DIR/full-simulator-templates"
  local log_dir="$TEST_WORK_DIR/full-simulator-logs"
  local console="$TEST_WORK_DIR/full-simulator-console.txt"
  local log_file first_menu_line simulator_line
  mkdir -p -- "$fixture_dir"
  make_fixture keepalived "$fixture_dir/my-Keepalived.xml"

  if ! ZERO_LAUNCHER_SOURCE_ONLY=false \
    ZERO_LAUNCHER_TEMPLATE_SOURCE_DIR="$fixture_dir" \
    ZERO_LAUNCHER_LOG_DIR="$log_dir" \
    bash "$PROJECT_DIR/zero-launcher.sh" >"$console" 2>&1 <<'EOF'
2
1
1
1




0

EOF
  then
    fail "El recorrido completo del simulador terminó con error"
  fi

  log_file=$(find "$log_dir" -maxdepth 1 -type f -name 'zero-launcher-*.log' -print -quit)
  [[ -n "$log_file" ]] || fail "El simulador no guardó el registro de la sesión"
  assert_contains "$log_file" "Simulación terminada" \
    "El registro no incluye el final de la simulación"
  assert_contains "$log_file" "Menú principal" \
    "El simulador no regresó al menú principal"
  assert_contains "$log_file" "Aplicaciones seleccionadas: Keepalived" \
    "El registro no identifica las aplicaciones elegidas"
  assert_contains "$console" "Registro guardado en $log_dir/zero-launcher-" \
    "No se mostró la ubicación del registro guardado"
  ! LC_ALL=C grep -q $'\033' "$log_file" || \
    fail "El registro conserva controles visuales de la terminal"
  first_menu_line=$(grep -n -m 1 'Menú principal' "$log_file" | cut -d: -f1)
  simulator_line=$(grep -n -m 1 'MODO SIMULADOR' "$log_file" | cut -d: -f1)
  ((first_menu_line < simulator_line)) || \
    fail "La simulación apareció antes que el menú principal"
}

test_platform_detection() {
  local release="$TEST_WORK_DIR/os-release"
  printf 'ID=debian\nVERSION_ID="13"\nVERSION_CODENAME=trixie\nPRETTY_NAME="Debian GNU/Linux 13"\n' >"$release"
  detect_platform "$release" Linux aarch64
  assert_eq linux "$PLATFORM" "Detección de Linux ARM"
  assert_eq debian "$DOCKER_DISTRO" "Repositorio oficial para Debian"
  assert_eq /srv/appdata "$DATA_ROOT" "Ruta Linux sin valores de Unraid"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04"\n' >"$release"
  detect_platform "$release" Linux x86_64
  assert_eq ubuntu "$DOCKER_DISTRO" "Detección de Ubuntu"
  detect_platform "$release" Windows arm64
  assert_eq unsupported "$PLATFORM" "Windows sólo debe permitir simular"
  PLATFORM=unraid; set_platform_defaults
}

test_new_rtfm_directory_permissions() (
  local path="$TEST_WORK_DIR/new-rtfm/data" calls="$TEST_WORK_DIR/permission-calls"
  DRY_RUN=false
  chown() { local IFS=' '; printf 'chown %s\n' "$*" >>"$calls"; }
  chmod() { local IFS=' '; printf 'chmod %s\n' "$*" >>"$calls"; }
  prepare_data_directory "$path" rtfm /data || fail "No se creó la carpeta de RTFM"
  [[ -d "$path" ]] || fail "Falta la carpeta nueva"
  assert_contains "$calls" "chown 10001:10001 -- $path" "Propietario de RTFM incorrecto"
  assert_contains "$calls" "chmod 0700 -- $path" "Permisos de RTFM incorrectos"
  assert_eq 2 "$(wc -l <"$calls" | tr -d ' ')" "Se tocaron permisos adicionales"
  prepare_data_directory "$path" rtfm /data || fail "Se rechazó la ruta existente"
  prepare_data_directory "$TEST_WORK_DIR/other-app" keepalived /data || fail "Se rechazó otra aplicación"
  assert_eq 2 "$(wc -l <"$calls" | tr -d ' ')" "Se cambiaron permisos de una ruta existente u otra aplicación"
  DRY_RUN=true
  prepare_data_directory "$TEST_WORK_DIR/simulated-rtfm" rtfm /data >/dev/null
  [[ ! -e "$TEST_WORK_DIR/simulated-rtfm" ]] || fail "La simulación creó una carpeta"
)

test_rtfm_installation_routes() (
  local source="$TEST_WORK_DIR/rtfm-routes.xml" calls="$TEST_WORK_DIR/rtfm-routes-calls"
  make_fixture rtfm "$source"
  DRY_RUN=false
  WORK_DIR="$TEST_WORK_DIR/routes-work"
  COMPOSE_DIR="$TEST_WORK_DIR/routes-compose"
  mkdir -p -- "$WORK_DIR"
  docker() { [[ "$1" != "inspect" ]]; }
  prepare_data_directory() {
    local IFS=' '
    printf '%s\n' "$*" >>"$calls"
    mkdir -p -- "$1"
  }
  create_container_from_template "$source" rtfm >/dev/null || fail "Falló la ruta Unraid"
  create_container_from_compose "$source" rtfm >/dev/null || fail "Falló la ruta Compose"
  assert_contains "$calls" "$TEST_WORK_DIR/data rtfm /data" "No se prepararon los datos de RTFM"
  assert_eq 2 "$(wc -l <"$calls" | tr -d ' ')" "No se preparó la ruta en ambos instaladores"
)

test_linux_path_defaults() {
  local source="$TEST_WORK_DIR/linux-path.xml" output="$TEST_WORK_DIR/linux-path-final.xml"
  make_fixture rtfm "$source"
  sed -i "s|$TEST_WORK_DIR/data|/mnt/user/appdata/rtfm/data|g" "$source"
  PLATFORM=linux; set_platform_defaults
  unset 'RESERVED_PORTS[45454]'
  personalize_template "$source" "$output" <<'EOF'


EOF
  assert_contains "$output" '>/srv/appdata/rtfm/data</Config>' "No se adaptó el directorio Linux"
  assert_eq /srv/appdata/nginx-proxy-manager/data "$(config_example /npm)" "Ejemplo de NPM para Linux"
  PLATFORM=unraid; set_platform_defaults
}

test_compose_preserves_runtime_options() {
  local source="$TEST_WORK_DIR/compose-source.xml" output="$TEST_WORK_DIR/compose.yaml" app_id
  for app_id in "${APP_IDS[@]}"; do
    make_fixture "$app_id" "$source"
    sed -i 's|<ExtraParams>.*</ExtraParams>|<ExtraParams>--restart=unless-stopped --init --read-only --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW --user=0:0 --security-opt=no-new-privileges:true --pids-limit=256 --tmpfs /run:rw,size=32m --tmpfs=/tmp:size=64m --add-host=host.docker.internal:host-gateway --label=com.example.role=app</ExtraParams>|' "$source"
    render_compose "$source" "$output" "$app_id" || fail "No se generó Compose para $app_id"
    assert_contains "$output" "container_name: '$(app_container "$app_id")'" "Nombre Compose incorrecto"
    assert_contains "$output" "image: '$(public_image "$app_id" stable)'" "Imagen Compose incorrecta"
    assert_contains "$output" 'init: true' "No se conservó init"
    assert_contains "$output" 'read_only: true' "No se conservó el sistema de archivos de sólo lectura"
    assert_contains "$output" "- 'NET_ADMIN'" "No se conservó la capacidad de red"
    assert_contains "$output" "- '/tmp:size=64m'" "No se conservó tmpfs"
    assert_contains "$output" "user: '0:0'" "No se conservó el usuario"
    assert_contains "$output" 'create_host_path: false' "Compose puede crear accidentalmente rutas de socket"
    assert_contains "$output" "- '45454:45454/tcp'" "No se conservó el puerto"
    [[ $(grep -c '^    container_name:' "$output") -eq 1 ]] || fail "Hay más de un contenedor"
  done
  assert_eq "'a''b\$\$c'" "$(yaml_string "a'b\$c")" "Escape YAML e interpolación Compose"
}

test_dependency_changes_require_confirmation() {
  local output marker="$TEST_WORK_DIR/package-mutation"
  output=$(
    PLATFORM=linux; DOCKER_DISTRO=debian
    apt-get() { touch "$marker"; }
    install_docker_dependencies false <<<'n' || true
  )
  [[ ! -e "$marker" ]] || fail "Se instalaron paquetes sin autorización"
  [[ "$output" == *"No se eliminarán paquetes"* ]] || fail "No se explicó el cambio"
  output=$(
    PLATFORM=linux; DOCKER_DISTRO=debian; DRY_RUN=true
    apt-get() { touch "$marker"; }
    install_docker_dependencies false <<<'s' || true
  )
  [[ ! -e "$marker" ]] || fail "dry-run cambió paquetes del sistema"
}

test_raspberry_simulator_bootstraps_registry() {
  local fixture_dir="$TEST_WORK_DIR/pi-templates" log_dir="$TEST_WORK_DIR/pi-logs"
  local console="$TEST_WORK_DIR/pi-console.txt" log_file
  mkdir -p -- "$fixture_dir"
  make_fixture keepalived "$fixture_dir/my-Keepalived.xml"
  make_fixture local-registry "$fixture_dir/my-Local-Registry.xml"
  sed -i 's/45454/5000/g' "$fixture_dir/my-Local-Registry.xml"
  ZERO_LAUNCHER_SOURCE_ONLY=false \
    ZERO_LAUNCHER_TEMPLATE_SOURCE_DIR="$fixture_dir" \
    ZERO_LAUNCHER_LOG_DIR="$log_dir" \
    bash "$PROJECT_DIR/zero-launcher.sh" >"$console" 2>&1 <<'EOF'
2
4
2
1






0

EOF
  log_file=$(find "$log_dir" -maxdepth 1 -name 'zero-launcher-*.log' -print -quit)
  [[ -n "$log_file" ]] || fail "No se guardó el registro de Raspberry Pi"
  assert_contains "$log_file" "Raspberry Pi OS de 64 bits" "No se eligió Raspberry Pi"
  assert_contains "$log_file" "zero-launcher/local-registry/compose.yaml" "No se preparó el Registry Linux"
  assert_contains "$log_file" "zero-launcher/keepalived/compose.yaml" "No se preparó Keepalived Linux"
  assert_contains "$log_file" "Simulación terminada" "No se completó la simulación Linux"
  ! grep -Fq 'Plantilla instalada:' "$log_file" || fail "Linux escribió una plantilla Unraid"
}

if (($#)); then
  for selected_test in "$@"; do
    [[ "$selected_test" == test_* ]] && declare -F "$selected_test" >/dev/null || fail "Comprobación desconocida"
    "$selected_test"
  done
  printf 'OK: %s comprobaciones seleccionadas terminadas correctamente.\n' "$#"
  exit 0
fi

test_metadata
test_registry_validation
test_new_rtfm_directory_permissions
test_public_render
test_local_render
test_local_registry_bootstrap
test_rtfm_installation_routes
test_personalize_defaults
test_required_npm_path_in_simulator
test_simulator_is_isolated
test_multiple_app_selector
test_atomic_install_and_backup
test_dry_container_creation
test_invalid_template
test_main_menu_wraps_simulator_and_saves_log
test_platform_detection
test_linux_path_defaults
test_compose_preserves_runtime_options
test_dependency_changes_require_confirmation
test_raspberry_simulator_bootstraps_registry

printf 'OK: 20 comprobaciones de Zero Launcher terminadas correctamente.\n'

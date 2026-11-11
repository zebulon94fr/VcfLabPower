#!/usr/bin/env bash
#
# vcf_lab_common.sh — fonctions partagées par vcf_lab_shutdown.sh et
# vcf_lab_startup.sh (configuration, logs, govc, ESX, API VCFMS / VCF Ops).
#
# Fichier « sourcé » : ne pas exécuter directement. Le script appelant doit
# définir SCRIPT_DIR, LOG_PREFIX, TMP_DIR, VCFOPS_CURL_CFG, DRY_RUN avant usage.
#
# shellcheck disable=SC2034  # variables utilisées par les scripts appelants

readonly VMSP_API_USER="vmware-system-user"
readonly REBOOT_HELPER="/usr/lib/vmware/vsan/bin/reboot_helper.py"

# Conf locale (ignorée par git) prioritaire sur la conf d'exemple versionnée
default_config_file() {
  if [[ -f "${SCRIPT_DIR}/vcf_lab_shutdown.local.conf" ]]; then
    echo "${SCRIPT_DIR}/vcf_lab_shutdown.local.conf"
  else
    echo "${SCRIPT_DIR}/vcf_lab_shutdown.conf"
  fi
}

set_defaults() {
  GOVC_URL="${GOVC_URL:-}"
  GOVC_USERNAME="${GOVC_USERNAME:-administrator@vsphere.local}"
  GOVC_PASSWORD="${GOVC_PASSWORD:-}"
  GOVC_INSECURE="${GOVC_INSECURE:-true}"

  MGMT_CLUSTER=""
  VCENTER_VM=""

  ESX_HOSTS=()
  ESX_SSH_USER="root"
  ESX_ROOT_PASSWORD="${ESX_ROOT_PASSWORD:-}"
  ESX_KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
  ENABLE_ESX_SSH="true"

  WORKLOAD_VMS=()
  VCFA_MODE="ui"         # ui | vm | none
  VCFA_VMS=()
  VCFNET_MODE="ui"       # ui | vm | none
  VCFNET_VMS=()
  CLOUD_PROXY_VMS=()
  LICENSE_SERVER_VMS=()

  VCFMS_NODE_IP=""
  VCFMS_NODE_PORT=5480
  VMSP_PASSWORD="${VMSP_PASSWORD:-}"
  VCFMS_SHUTDOWN_SCRIPT="${SCRIPT_DIR}/vcf_services_runtime_shutdown.sh"
  VCFMS_VMS=()
  VCFMS_VM_PATTERN=""
  VCFMS_KUBECONFIG=""   # requis par les versions récentes du script officiel (--kubeconfig)

  VCFOPS_OFFLINE_MODE="api"   # api | ui
  VCFOPS_PRIMARY_FQDN=""
  VCFOPS_ADMIN_USER="admin"
  VCFOPS_ADMIN_PASSWORD="${VCFOPS_ADMIN_PASSWORD:-}"
  VCFOPS_VMS=()

  VLSR_VMS=()
  NSX_EDGE_VMS=()
  NSX_MANAGER_VMS=()
  SDDC_MANAGER_VM=""

  INFRA_VMS=()
  MGMT_STORAGE="vsan"          # vsan | nfs (NFS ou Fibre Channel)
  VSAN_SHUTDOWN_MODE="manual"  # manual | wizard (vSAN uniquement)
  VSAN_SHARED_WITNESS="false"

  # Démarrage (vcf_lab_startup.sh)
  ESX_POWERON_CMD=""        # commande d'allumage hors bande, {host} remplacé par le nom de l'hôte
  NSX_MANAGER_FQDN=""       # VIP/FQDN NSX Manager pour attendre l'état STABLE (sinon pause manuelle)
  NSX_ADMIN_USER="admin"
  NSX_ADMIN_PASSWORD="${NSX_ADMIN_PASSWORD:-}"
  VCFMS_CONTROL_VMS=()      # nœuds control plane (sinon : VMs avec le moins de mémoire)
  VCFMS_CONTROL_WAIT=300    # attente après les control plane avant les workers (KB 440862)
  ESX_BOOT_TIMEOUT=1200
  VCENTER_START_TIMEOUT=1200
  VM_START_TIMEOUT=900
  VM_POWERON_RETRIES=6      # Power On refusé juste après le redémarrage du vCenter : réessais
  VM_POWERON_RETRY_DELAY=30
  HA_READY_TIMEOUT=600
  NSX_START_TIMEOUT=1800
  VCFOPS_ONLINE_TIMEOUT=3600
  VCFMS_START_TIMEOUT=1800

  VM_SHUTDOWN_TIMEOUT=600
  VCFOPS_OFFLINE_TIMEOUT=3600
  ESX_SHUTDOWN_TIMEOUT=900
  POLL_INTERVAL=10

  LOG_DIR="${SCRIPT_DIR}/logs"
}

ts() { date +'%Y-%m-%dT%H:%M:%S%z'; }

log() { echo "[$(ts)] [INFO]  ${*}" >&2; }

log_warn() { echo "[$(ts)] [WARN]  ${*}" >&2; }

log_error() { echo "[$(ts)] [ERROR] ${*}" >&2; }

log_step() {
  {
    echo ""
    echo "=========================================================="
    echo "[$(ts)] [STEP]  ${*}"
    echo "=========================================================="
  } >&2
}

die() {
  log_error "${*}"
  exit 1
}

cleanup() {
  local -r exit_code="${?}"
  trap - EXIT
  rm -rf "${TMP_DIR}" 2> /dev/null || true
  if [[ "${exit_code}" -ne 0 ]]; then
    log_error "Script interrompu (code ${exit_code})."
    log_error "Corrige le problème puis relance avec --from-step <étape en échec>."
  fi
  exit "${exit_code}"
}

# run <cmd...> — exécute une action destructive (ou la journalise en dry-run)
run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] ${*}"
    return 0
  fi
  "${@}"
}

# in_list <aiguille> <éléments...>
in_list() {
  local needle="${1}" item
  shift
  for item in ${@+"${@}"}; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

step_in_range() {
  [[ "${1}" -ge "${FROM_STEP}" && "${1}" -le "${TO_STEP}" ]]
}

prompt_secret() {
  # prompt_secret <NOM_VARIABLE> <libellé>
  local var="${1}" label="${2}" value=""
  [[ -n "${!var:-}" ]] && return 0
  [[ -t 0 ]] || die "${var} non défini et pas de terminal interactif."
  read -r -s -p "${label} : " value
  echo "" >&2
  [[ -n "${value}" ]] || die "${label} ne peut pas être vide."
  printf -v "${var}" '%s' "${value}"
}

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${0}"
  exit 0
}

load_config() {
  set_defaults
  [[ -f "${CONFIG_FILE}" ]] || die "Fichier de configuration introuvable : ${CONFIG_FILE}"
  bash -n "${CONFIG_FILE}" || die "Erreur de syntaxe dans ${CONFIG_FILE} (voir ci-dessus)."
  # shellcheck source=/dev/null
  if ! source "${CONFIG_FILE}"; then
    die "Le chargement de ${CONFIG_FILE} a échoué (commande en erreur dans le fichier ?)."
  fi

  case "${VCFA_MODE}" in ui | vm | none) ;; *) die "VCFA_MODE invalide : ${VCFA_MODE}" ;; esac
  case "${VCFNET_MODE}" in ui | vm | none) ;; *) die "VCFNET_MODE invalide : ${VCFNET_MODE}" ;; esac
  case "${VCFOPS_OFFLINE_MODE}" in api | ui) ;; *) die "VCFOPS_OFFLINE_MODE invalide : ${VCFOPS_OFFLINE_MODE}" ;; esac
  case "${VSAN_SHUTDOWN_MODE}" in manual | wizard) ;; *) die "VSAN_SHUTDOWN_MODE invalide : ${VSAN_SHUTDOWN_MODE}" ;; esac
  case "${MGMT_STORAGE}" in vsan | nfs) ;; *) die "MGMT_STORAGE invalide : ${MGMT_STORAGE} (vsan | nfs)" ;; esac
}

setup_logging() {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/${LOG_PREFIX}_$(date +'%Y%m%d_%H%M%S').log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
}

# resolve_vm <nom | /chemin/inventaire | VirtualMachine:vm-xx> → chemin d'inventaire sur stdout
#   rc 1 = introuvable, rc 2 = nom ambigu
# govc_retry <args govc...> — jusqu'à 3 essais (vCenter lent ou qui finit de
# démarrer) ; stderr du dernier essai dans ${TMP_DIR}/govc_err
govc_retry() {
  local attempt=1 out
  while true; do
    if out=$(govc "${@}" 2> "${TMP_DIR}/govc_err"); then
      [[ -n "${out}" ]] && printf '%s\n' "${out}"
      return 0
    fi
    [[ "${attempt}" -ge 3 ]] && return 1
    sleep 5
    attempt=$((attempt + 1))
  done
}

govc_last_error() { tr '\n' ' ' < "${TMP_DIR}/govc_err" 2> /dev/null | cut -c1-300; }

#   rc 1 = introuvable, rc 2 = nom ambigu, rc 3 = erreur govc/vCenter
resolve_vm() {
  local id="${1}" out count
  if [[ "${id}" == VirtualMachine:* || "${id}" == /* ]]; then
    if [[ "${id}" == VirtualMachine:* ]]; then
      out=$(govc_retry ls -L "${id}") || out=""
    elif govc_retry object.collect -s "${id}" name > /dev/null; then
      out="${id}"
    else
      out=""
    fi
    if [[ -z "${out}" ]]; then
      if grep -qiE 'not ?found|no such|ManagedObjectNotFound' "${TMP_DIR}/govc_err" 2> /dev/null ||
        [[ ! -s "${TMP_DIR}/govc_err" ]]; then
        return 1
      fi
      log_error "govc en erreur sur '${id}' : $(govc_last_error)"
      return 3
    fi
  else
    if ! out=$(govc_retry find / -type m -name "${id}"); then
      log_error "Recherche de la VM '${id}' en erreur (vCenter) : $(govc_last_error)"
      return 3
    fi
  fi
  [[ -n "${out}" ]] || return 1
  count=$(printf '%s\n' "${out}" | grep -c .)
  if [[ "${count}" -gt 1 ]]; then
    log_error "Nom de VM ambigu '${id}' (${count} correspondances) :"
    printf '%s\n' "${out}" | sed 's/^/    /' >&2
    return 2
  fi
  printf '%s\n' "${out}"
}

vm_power_state() {
  govc object.collect -s "${1}" runtime.powerState 2> /dev/null || echo "unknown"
}

vm_tools_status() {
  govc object.collect -s "${1}" guest.toolsRunningStatus 2> /dev/null || echo "unknown"
}

# resolve_vms <ids...> → chemins (un par ligne) ; VMs introuvables ignorées
resolve_vms() {
  local id path rc
  for id in ${@+"${@}"}; do
    rc=0
    path=$(resolve_vm "${id}") || rc=$?
    case "${rc}" in
      0) printf '%s\n' "${path}" ;;
      2 | 3) return "${rc}" ;;
      *) log_warn "  VM '${id}' introuvable dans l'inventaire — ignorée." ;;
    esac
  done
}

manual_checkpoint() {
  local msg="${1}" answer=""
  log_warn "ACTION MANUELLE : ${msg}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] Pause manuelle ici."
    return 0
  fi
  [[ -t 0 ]] || die "Action manuelle requise mais pas de terminal interactif."
  while [[ "${answer}" != "OK" ]]; do
    read -r -p "  Tape OK quand c'est fait (Ctrl+C pour abandonner) : " answer
  done
}

esx_ssh() {
  local host="${1}"
  shift
  local -a opts=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${ESX_KNOWN_HOSTS}" -o LogLevel=ERROR)
  if [[ -n "${ESX_ROOT_PASSWORD}" ]]; then
    SSHPASS="${ESX_ROOT_PASSWORD}" sshpass -e ssh "${opts[@]}" \
      -o PubkeyAuthentication=no \
      -o PreferredAuthentications=keyboard-interactive,password \
      "${ESX_SSH_USER}@${host}" "${@}"
  else
    ssh "${opts[@]}" -o BatchMode=yes "${ESX_SSH_USER}@${host}" "${@}"
  fi
}

# parse_getallvms <nom> — lit la sortie de « vim-cmd vmsvc/getallvms » sur stdin
parse_getallvms() {
  awk -v n="${1}" '
    $1 ~ /^[0-9]+$/ {
      line = $0
      sub(/^[0-9]+[ \t]+/, "", line)
      i = index(line, " [")
      if (i > 0) {
        nm = substr(line, 1, i - 1)
        gsub(/[ \t]+$/, "", nm)
        if (nm == n && !found) { print $1; found = 1 }
      }
    }'
}

# list_getallvms — « vmid|nom » pour chaque VM (stdin = sortie getallvms)
list_getallvms() {
  awk '
    $1 ~ /^[0-9]+$/ {
      line = $0
      sub(/^[0-9]+[ \t]+/, "", line)
      i = index(line, " [")
      if (i > 0) {
        nm = substr(line, 1, i - 1)
        gsub(/[ \t]+$/, "", nm)
        print $1 "|" nm
      }
    }'
}

# esx_find_vm <nom> → « hôte|vmid »
esx_find_vm() {
  local name="${1}" host out id
  for host in "${ESX_HOSTS[@]}"; do
    out=$(esx_ssh "${host}" "vim-cmd vmsvc/getallvms" 2> /dev/null) || continue
    id=$(printf '%s\n' "${out}" | parse_getallvms "${name}")
    if [[ -n "${id}" ]]; then
      printf '%s|%s\n' "${host}" "${id}"
      return 0
    fi
  done
  return 1
}

esx_vm_state() {
  esx_ssh "${1}" "vim-cmd vmsvc/power.getstate ${2}" 2> /dev/null | tail -1
}

# vcfms_http <args curl...> → corps de réponse sur stdout, code HTTP dans VCFMS_HTTP_CODE
# (fichier temporaire : la valeur est perdue si on l'appelle dans $(...))
vcfms_http() {
  local code_file="${TMP_DIR}/vcfms_http_code"
  curl -sk --max-time 30 -o "${TMP_DIR}/vcfms_http_body" -w '%{http_code}' "${@}" > "${code_file}" 2> /dev/null ||
    echo "000" > "${code_file}"
  cat "${TMP_DIR}/vcfms_http_body" 2> /dev/null || true
}

vcfms_http_code() { cat "${TMP_DIR}/vcfms_http_code" 2> /dev/null || echo "000"; }

# Extrait « nom|moRef » d'une réponse d'inventaire, en acceptant plusieurs formes
# (tableau racine, .nodes, .items, .data ; moRef sous .vm ou à plat).
parse_vcfms_nodes() {
  jq -r '
    (if type == "array" then . else (.nodes // .items // .data // .results // []) end)
    | .[]?
    | "\(.name // .hostname // .nodeName // .id // "?")|\(
        .vm.moRef // .vm.moref // .vm.moid // .vm.id // .vmMoRef // .vmMoref
        // .vm_moref // .moRef // .moref // "")"' 2> /dev/null
}

write_vcfops_curl_cfg() {
  local esc="${VCFOPS_ADMIN_PASSWORD//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  (
    umask 077
    printf 'user = "%s:%s"\n' "${VCFOPS_ADMIN_USER}" "${esc}" > "${VCFOPS_CURL_CFG}"
  )
}

vcfops_curl() {
  curl -sk --fail --max-time 60 -K "${VCFOPS_CURL_CFG}" \
    -H "Accept: application/json" -H "Content-Type: application/json" "${@}"
}

vcfops_online_state() {
  vcfops_curl "https://${VCFOPS_PRIMARY_FQDN}/casa/sysadmin/cluster/online_state" 2> /dev/null |
    jq -r '.cluster_online_state_snapshot // .online_state // .onlineState // "UNKNOWN"' 2> /dev/null ||
    echo "UNREACHABLE"
}

# esx_govc <hôte> <args govc...> — govc directement contre un ESXi (équivalent Host Client)
esx_govc() {
  local host="${1}"
  shift
  GOVC_URL="https://${host}" GOVC_USERNAME="${ESX_SSH_USER}" GOVC_PASSWORD="${ESX_ROOT_PASSWORD}" \
    GOVC_DATACENTER="" govc "${@}"
}

host_state() {
  govc object.collect -s "${1}" runtime.connectionState 2> /dev/null || echo "unknown"
}

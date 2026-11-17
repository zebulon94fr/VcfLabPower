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
  VCFMS_ACCEPT_CONSENT="false"   # true : passe --yes au script officiel sans terminal (consentement)

  VCFOPS_OFFLINE_MODE="api"   # api | ui
  VCFOPS_PRIMARY_FQDN=""
  VCFOPS_ADMIN_USER="admin"
  VCFOPS_ADMIN_PASSWORD="${VCFOPS_ADMIN_PASSWORD:-}"
  VCFOPS_VMS=()

  VLSR_VMS=()
  NSX_EDGE_VMS=()
  NSX_MANAGER_VMS=()
  SDDC_MANAGER_VM=""

  # vSphere Supervisor (VKS, vSphere Pods, Foundation Load Balancer)
  SUPERVISOR_MODE="auto"           # auto : détecté dans l'inventaire ; none : ignoré
  SUPERVISOR_FOLDER="Namespaces"   # dossier VM créé par le Supervisor
  SUPERVISOR_WCP_TIMEOUT=300       # arrêt / démarrage du service wcp du vCenter
  SUPERVISOR_POD_TIMEOUT=120       # vSphere Pods : power-off forcé au-delà (notes de version)
  SUPERVISOR_START_TIMEOUT=1800    # démarrage : VMs du control plane puis état Running/Ready

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
  CYCLE_DELAY=120           # vcf_lab_cycle.sh : pause entre arrêt et démarrage

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

# Alerte à relayer telle quelle (notification Home Assistant via vcf_lab_ha.sh)
log_alert() { echo "[$(ts)] [ALERT] ${*}" >&2; }

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
  # Valeurs d'exemple laissées telles quelles (« "<…>" » hors commentaire)
  local placeholders
  placeholders=$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "${CONFIG_FILE}" |
    grep -nE '"<[^">]+>"' | cut -c1-120 || true)
  if [[ -n "${placeholders}" ]]; then
    die "Valeurs d'exemple à remplacer dans ${CONFIG_FILE} : $(printf '%s' "${placeholders}" | paste -sd';' - | sed 's/;/ ; /g')"
  fi
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

# vcfms_login_code <hôte> [délai] — code HTTP d'un vrai login sur un nœud ou la
# VIP (000 : pas de réponse dans le délai)
vcfms_login_code() {
  local host="${1}" max="${2:-15}" payload_file="${TMP_DIR}/vcfms_probe.json" code=""
  (
    umask 077
    jq -n --arg u "${VMSP_API_USER}" --arg p "${VMSP_PASSWORD}" '{username: $u, password: $p}' > "${payload_file}"
  )
  code=$(curl -sk --max-time "${max}" -o /dev/null -w '%{http_code}' -X POST \
    "https://${host}:${VCFMS_NODE_PORT}/api/v1/auth/login" -H "Content-Type: application/json" \
    --data-binary "@${payload_file}" 2> /dev/null) || true
  rm -f "${payload_file}"
  echo "${code:-000}"
}

# vcfms_conf_vms — nœuds du VCF services runtime d'après la conf (VCFMS_VMS ou
# VCFMS_VM_PATTERN), un chemin d'inventaire par ligne
vcfms_conf_vms() {
  if [[ "${#VCFMS_VMS[@]}" -gt 0 ]]; then
    resolve_vms "${VCFMS_VMS[@]}"
  elif [[ -n "${VCFMS_VM_PATTERN}" ]]; then
    govc find / -type m -name "${VCFMS_VM_PATTERN}" 2> /dev/null || true
  fi
}

# vcfms_nodes <réf VM...> — « nom|IP » de chaque nœud (réf : nom, chemin ou
# moRef ; IP lue dans les VMware Tools, nœud ignoré tant qu'elle est absente)
vcfms_nodes() {
  local ref path ip
  for ref in ${@+"${@}"}; do
    path=$(resolve_vm "${ref}" 2> /dev/null) || continue
    ip=$(govc object.collect -s "${path}" guest.ipAddress 2> /dev/null || true)
    [[ -n "${ip}" ]] && echo "${path##*/}|${ip}"
  done
}

# vcfms_stuck_nodes <nom|IP...> — nœuds dont le node-agent accepte la connexion
# mais ne répond pas au login, alors qu'un autre nœud répond (cas « Secret
# Informer to sync » : l'agent a démarré avant l'API Kubernetes).
# Écrit « nom|IP » des nœuds bloqués. Code 0 : au moins un nœud bloqué ;
# 1 : aucun ; 2 : aucun nœud ne répond (plateforme pas encore prête).
vcfms_stuck_nodes() {
  local entry code start ok=0
  local -a stuck=()
  for entry in ${@+"${@}"}; do
    start="${SECONDS}"
    code=$(vcfms_login_code "${entry#*|}" 10)
    if [[ "${code}" == "200" ]]; then
      ok=$((ok + 1))
    elif [[ "${code}" == "000" && $((SECONDS - start)) -ge 8 ]]; then
      # Délai écoulé (pas un refus immédiat d'un nœud éteint)
      stuck+=("${entry}")
    fi
  done
  [[ "${ok}" -gt 0 ]] || return 2
  [[ "${#stuck[@]}" -gt 0 ]] || return 1
  printf '%s\n' "${stuck[@]}"
}

# vcfms_agent_procedure <nom|IP> — procédure de reprise d'un node-agent bloqué
vcfms_agent_procedure() {
  local name="${1%%|*}" ip="${1#*|}"
  printf '%s' "node-agent bloqué sur ${name} (${ip}) : le login VCF services runtime n'y répond plus. Procédure : ssh root@${ip} puis « systemctl restart node-agent » ; après 30 s, « journalctl -u node-agent --since '-1 min' | grep -c 'Informer to sync' » doit afficher 0."
}

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
# esx_host_path <hôte> — chemin de l'hôte dans son propre inventaire (connexion directe)
esx_host_path() { esx_govc "${1}" find / -type h 2> /dev/null | head -1; }

esx_govc() {
  local host="${1}"
  shift
  # GOVC_INSECURE passé explicitement : la conf le définit sans l'exporter
  GOVC_URL="https://${host}" GOVC_USERNAME="${ESX_SSH_USER}" GOVC_PASSWORD="${ESX_ROOT_PASSWORD}" \
    GOVC_INSECURE="${GOVC_INSECURE}" GOVC_DATACENTER="" govc "${@}"
}

esx_reachable() { esx_govc "${1}" about > /dev/null 2>&1; }

host_state() {
  govc object.collect -s "${1}" runtime.connectionState 2> /dev/null || echo "unknown"
}

# ---------------------------------------------------------------------------
# vSphere Supervisor
# ---------------------------------------------------------------------------
# API REST du vCenter (session SSO, mêmes identifiants que govc)
vc_api_host() {
  local h="${GOVC_URL#*://}"
  h="${h%%/*}"
  echo "${h##*@}"
}

vc_api_login() {
  [[ -n "${VC_API_TOKEN:-}" ]] && return 0
  local cfg="${TMP_DIR}/vc_api.cfg" esc
  esc="${GOVC_PASSWORD//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  (
    umask 077
    printf 'user = "%s:%s"\n' "${GOVC_USERNAME}" "${esc}" > "${cfg}"
  )
  VC_API_TOKEN=$(curl -sk --fail --max-time 30 -K "${cfg}" -X POST \
    "https://$(vc_api_host)/api/session" 2> /dev/null | jq -r '.' 2> /dev/null || true)
  rm -f "${cfg}"
  [[ -n "${VC_API_TOKEN}" && "${VC_API_TOKEN}" != "null" ]] || {
    VC_API_TOKEN=""
    return 1
  }
}

# vc_api <méthode> <chemin /api/...> — corps de la réponse sur stdout
vc_api() {
  vc_api_login || return 1
  curl -sk --fail --max-time 60 -X "${1}" -H "vmware-api-session-id: ${VC_API_TOKEN}" \
    -H "Accept: application/json" "https://$(vc_api_host)${2}"
}

# wcp_state → STARTED / STOPPED / ... (service Workload Control Plane du vCenter)
wcp_state() {
  vc_api GET /api/vcenter/services/wcp 2> /dev/null | jq -r '.state // "UNKNOWN"' 2> /dev/null ||
    echo "UNREACHABLE"
}

# wcp_set <start|stop> <état attendu> — action puis attente
wcp_set() {
  local action="${1}" want="${2}" elapsed=0 state
  state=$(wcp_state)
  if [[ "${state}" == "${want}" ]]; then
    log "  Service wcp du vCenter déjà ${want}."
    return 0
  fi
  log "  Service wcp du vCenter : ${state} → ${action} (équivalent vmon-cli $([[ "${action}" == "stop" ]] && echo -k || echo -i) wcp)"
  run vc_api POST "/api/vcenter/services/wcp?action=${action}" > /dev/null ||
    die "Action ${action} du service wcp refusée par le vCenter."
  [[ "${DRY_RUN}" == "true" ]] && return 0
  while [[ "$(wcp_state)" != "${want}" ]]; do
    [[ "${elapsed}" -ge "${SUPERVISOR_WCP_TIMEOUT}" ]] &&
      die "Service wcp toujours $(wcp_state) après ${SUPERVISOR_WCP_TIMEOUT}s."
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  log "  Service wcp : ${want} (${elapsed}s)."
}

# supervisor_vms <cp|lb|pod|vks> — chemins vCenter des VMs du Supervisor, par rôle
#   cp  : SupervisorControlPlaneVM*        lb  : flb-* (Foundation Load Balancer)
#   pod : vSphere Pods (dossier vSpherePods) vks : le reste (nœuds des clusters VKS)
supervisor_vms() {
  local role="${1}" folder path name
  [[ "${SUPERVISOR_MODE}" == "none" ]] && return 0
  while IFS= read -r folder; do
    [[ -z "${folder}" ]] && continue
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      name="${path##*/}"
      case "${path}" in
        */vSpherePods/*) [[ "${role}" == "pod" ]] && printf '%s\n' "${path}" ;;
        *)
          case "${name}" in
            SupervisorControlPlaneVM*) [[ "${role}" == "cp" ]] && printf '%s\n' "${path}" ;;
            flb-*) [[ "${role}" == "lb" ]] && printf '%s\n' "${path}" ;;
            *) [[ "${role}" == "vks" ]] && printf '%s\n' "${path}" ;;
          esac
          ;;
      esac
    done <<< "$(govc find "${folder}" -type m 2> /dev/null || true)"
  done <<< "$(govc find / -type f -name "${SUPERVISOR_FOLDER}" 2> /dev/null || true)"
  return 0
}

# supervisor_status → une ligne « config_status/kubernetes_status » par Supervisor
supervisor_status() {
  vc_api GET /api/vcenter/namespace-management/clusters 2> /dev/null |
    jq -r '.[] | "\(.config_status // "?")/\(.kubernetes_status // "?")"' 2> /dev/null || true
}

supervisor_ready() {
  local st any="false"
  while IFS= read -r st; do
    [[ -z "${st}" ]] && continue
    any="true"
    [[ "${st}" == "RUNNING/READY" ]] || return 1
  done <<< "$(supervisor_status)"
  [[ "${any}" == "true" ]]
}

# vm_host_name <chemin vCenter> → nom de l'hôte ESX qui porte la VM
vm_host_name() {
  local ref
  ref=$(govc object.collect -s "${1}" runtime.host 2> /dev/null) || return 1
  govc object.collect -s "${ref}" name 2> /dev/null
}

# list_manual_pauses <shutdown | startup | cycle> — pauses manuelles qui
# bloqueront une exécution sans terminal (une par ligne). L'allumage des
# hôtes n'est compté que si ESX_POWERON_CMD est vide : le démarrage la saute
# quand tous les hôtes répondent déjà.
list_manual_pauses() {
  local action="${1}"
  if [[ "${action}" != "shutdown" && -z "${ESX_POWERON_CMD}" ]]; then
    echo "allumage des hôtes (ESX_POWERON_CMD vide)"
  fi
  if [[ "${action}" != "shutdown" && "${#NSX_MANAGER_VMS[@]}" -gt 0 && -z "${NSX_MANAGER_FQDN}" ]]; then
    echo "état STABLE de NSX (NSX_MANAGER_FQDN vide)"
  fi
  [[ "${#VCFOPS_VMS[@]}" -gt 0 && "${VCFOPS_OFFLINE_MODE}" == "ui" ]] && echo "VCF Operations offline/online (VCFOPS_OFFLINE_MODE=ui)"
  [[ "${VCFA_MODE}" == "ui" ]] && echo "VCF Automation (VCFA_MODE=ui)"
  [[ "${VCFNET_MODE}" == "ui" ]] && echo "VCF Operations for networks (VCFNET_MODE=ui)"
  [[ "${MGMT_STORAGE}" == "vsan" && "${VSAN_SHUTDOWN_MODE}" == "wizard" ]] && echo "vSAN Shutdown/Restart cluster wizard (VSAN_SHUTDOWN_MODE=wizard)"
  if [[ "${action}" != "startup" && -n "${VCFMS_NODE_IP}" && "${VCFMS_ACCEPT_CONSENT}" != "true" ]] &&
    grep -qi -- 'consent' "${VCFMS_SHUTDOWN_SCRIPT}" 2> /dev/null; then
    echo "consentement du script officiel VCFMS (lire les conditions, puis VCFMS_ACCEPT_CONSENT=\"true\")"
  fi
  return 0
}

# list_required_secrets <shutdown | startup | cycle> — « VARIABLE|libellé »
# pour chaque secret dont l'action aura besoin.
list_required_secrets() {
  local action="${1}"
  echo "GOVC_PASSWORD|Mot de passe vCenter pour ${GOVC_USERNAME}"
  # Arrêt vSAN : clé SSH possible à la place du mot de passe root
  if [[ "${action}" != "shutdown" || "${MGMT_STORAGE}" == "nfs" ]]; then
    echo "ESX_ROOT_PASSWORD|Mot de passe ${ESX_SSH_USER} des ESX"
  fi
  [[ -n "${VCFMS_NODE_IP}" ]] && echo "VMSP_PASSWORD|Mot de passe ${VMSP_API_USER} (VCF services runtime)"
  if [[ "${#VCFOPS_VMS[@]}" -gt 0 && "${VCFOPS_OFFLINE_MODE}" == "api" ]]; then
    echo "VCFOPS_ADMIN_PASSWORD|Mot de passe ${VCFOPS_ADMIN_USER} de VCF Operations (/admin)"
  fi
  if [[ "${action}" != "shutdown" && -n "${NSX_MANAGER_FQDN}" ]]; then
    echo "NSX_ADMIN_PASSWORD|Mot de passe ${NSX_ADMIN_USER} de NSX Manager"
  fi
  return 0
}

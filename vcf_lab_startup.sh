#!/usr/bin/env bash
#
# vcf_lab_startup.sh — Démarrage ordonné du domaine de gestion d'un lab VCF 9.1
#
# Pendant de vcf_lab_shutdown.sh : même fichier de configuration, et lecture
# de l'état sauvegardé à l'arrêt (logs/cluster_state_<cluster>.env : hôte du
# vCenter, HA/DRS d'origine).
#
# Inspiré de :
#   - Doc Broadcom VCF 9.1 « Start the Management Domain » (ordre de démarrage)
#   - Doc « Start VCF Management Services » + KB 440862 (control plane, puis
#     workers ; récupération automatique en 15-20 min)
#   - Doc « Start VCF Operations » + KB 341964 (ordre des nœuds) et
#     KB 313533 (API CaSA, Bring Cluster Online)
#   - vSAN « Manually Shut Down and Restart the vSAN Cluster » / KB 322144
#
# Ordre de démarrage (doc VCF 9.1) :
#    1  Hôtes ESX, stockage et vCenter (+ VMs d'infra DNS/NTP/AD)
#    2  SDDC Manager
#    3  NSX Manager (attente de l'état STABLE)
#    4  NSX Edge / VNA
#    5  Protection & recovery (VLSR)
#    6  VCF Operations (nœuds, puis Bring Cluster Online)
#    7  VCF services runtime (control plane, puis workers)
#    8  License server
#    9  Cloud proxies
#   10  VCF Operations for networks   (VCF Operations > State management)
#   11  VCF Automation                (VCF Operations > State management)
#   12  Workloads du domaine de gestion (après le domaine de gestion)
#
# Usage :
#   vcf_lab_startup.sh [OPTIONS]
#
# Options :
#   --config FICHIER        Fichier de configuration (défaut, à côté du script :
#                           vcf_lab_shutdown.local.conf s'il existe, sinon
#                           vcf_lab_shutdown.conf).
#   --dry-run               Affiche les actions prévues sans rien démarrer.
#   --from-step N           Reprend à l'étape N (1-12).
#   --to-step N             S'arrête après l'étape N (1-12).
#   --yes                   Pas de confirmation initiale (les actions
#                           manuelles restent interactives).
#   --help                  Affiche cette aide.
#
# Secrets (variables d'environnement, sinon demandés au lancement) :
#   GOVC_PASSWORD, ESX_ROOT_PASSWORD, VCFOPS_ADMIN_PASSWORD, VMSP_PASSWORD,
#   NSX_ADMIN_PASSWORD (si NSX_MANAGER_FQDN est défini).
#
# Compatible bash 3.2+ (macOS) et Linux. Outils : curl, jq, govc
# (+ ssh / sshpass pour vSAN en mode manual).
#

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR
readonly SCRIPT_VERSION="1.0.0"
readonly FIRST_STEP=1
readonly LAST_STEP=12
readonly LOG_PREFIX="vcf_lab_startup"

# shellcheck source=vcf_lab_common.sh
source "${SCRIPT_DIR}/vcf_lab_common.sh"

# ---------------------------------------------------------------------------
# Options CLI et état
# ---------------------------------------------------------------------------
DRY_RUN="false"
ASSUME_YES="false"
FROM_STEP="${FIRST_STEP}"
TO_STEP="${LAST_STEP}"
CONFIG_FILE="$(default_config_file)"

TMP_DIR="$(mktemp -d)"
VCFOPS_CURL_CFG="${TMP_DIR}/vcfops.curlrc"
NSX_CURL_CFG="${TMP_DIR}/nsx.curlrc"

VC_ONLINE="false"   # le vCenter répond-il (govc) ?
CLUSTER_PATH=""
STATE_FILE=""
VC_HOST_NAME=""

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args() {
  while [[ "${#}" -gt 0 ]]; do
    case "${1}" in
      --config)
        CONFIG_FILE="${2:?'--config requiert un fichier'}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --from-step)
        FROM_STEP="${2:?'--from-step requiert un numéro'}"
        shift 2
        ;;
      --to-step)
        TO_STEP="${2:?'--to-step requiert un numéro'}"
        shift 2
        ;;
      --yes | -y)
        ASSUME_YES="true"
        shift
        ;;
      --help | -h)
        usage
        ;;
      *)
        log_error "Option inconnue : ${1}"
        log_error "Voir '${SCRIPT_NAME} --help'."
        exit 1
        ;;
    esac
  done
  [[ "${FROM_STEP}" =~ ^[0-9]+$ && "${TO_STEP}" =~ ^[0-9]+$ ]] ||
    die "--from-step / --to-step doivent être des entiers."
  [[ "${FROM_STEP}" -ge "${FIRST_STEP}" && "${FROM_STEP}" -le "${TO_STEP}" && "${TO_STEP}" -le "${LAST_STEP}" ]] ||
    die "Plage d'étapes invalide : ${FROM_STEP}..${TO_STEP} (${FIRST_STEP}..${LAST_STEP})."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Lit une valeur dans le fichier d'état écrit par vcf_lab_shutdown.sh
read_state() {
  [[ -n "${STATE_FILE}" && -f "${STATE_FILE}" ]] || return 0
  sed -n "s/^${1}='\\(.*\\)'\$/\\1/p" "${STATE_FILE}" | tail -1
}

# Affiche les arguments dans l'ordre inverse, un par ligne
reverse_lines() {
  local -a items=()
  local i
  for i in ${@+"${@}"}; do items=("${i}" ${items[@]+"${items[@]}"}); done
  for i in ${items[@]+"${items[@]}"}; do printf '%s\n' "${i}"; done
}

wait_until() {
  # wait_until <timeout> <libellé> <commande...> — réessaie jusqu'au succès
  local timeout="${1}" label="${2}" elapsed=0
  shift 2
  [[ "${DRY_RUN}" == "true" ]] && return 0
  until "${@}" > /dev/null 2>&1; do
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      return 1
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
    [[ $((elapsed % 60)) -lt "${POLL_INTERVAL}" ]] && log "  … ${label} (${elapsed}s)"
  done
  log "  ${label} : OK (${elapsed}s)."
}

vc_reachable() { govc about > /dev/null 2>&1; }

vm_tools_running() { [[ "$(vm_tools_status "${1}")" == "guestToolsRunning" ]]; }

# power_on_vms <libellé> <sequential|parallel> <ids...>
# Power On puis attente des VMware Tools (signe que l'OS invité a démarré).
power_on_vms() {
  local label="${1}" mode="${2}" out path
  shift 2
  if [[ "${#}" -eq 0 ]]; then
    log "Aucune VM configurée pour « ${label} » — rien à faire."
    return 0
  fi
  if [[ "${VC_ONLINE}" != "true" ]]; then
    # Uniquement possible en dry-run (vCenter éteint) : on liste sans vérifier
    log "  [DRY-RUN] vCenter injoignable — Power On prévu pour : ${*}"
    return 0
  fi
  out=$(resolve_vms "${@}") || die "Résolution des VMs « ${label} » impossible."
  local -a paths=()
  while IFS= read -r path; do
    [[ -n "${path}" ]] && paths+=("${path}")
  done <<< "${out}"
  if [[ "${#paths[@]}" -eq 0 ]]; then
    log_warn "Aucune VM « ${label} » trouvée — rien à faire."
    return 0
  fi

  log "${label} : ${#paths[@]} VM(s), démarrage ${mode}."
  for path in "${paths[@]}"; do
    request_power_on "${path}"
    [[ "${mode}" == "sequential" ]] && wait_vm_tools "${path}"
  done
  if [[ "${mode}" == "parallel" ]]; then
    for path in "${paths[@]}"; do
      wait_vm_tools "${path}"
    done
  fi
}

request_power_on() {
  local path="${1}" state err attempt=1
  state=$(vm_power_state "${path}")
  if [[ "${state}" == "poweredOn" ]]; then
    log "  '${path##*/}' déjà allumée."
    return 0
  fi
  log "  Power On : ${path##*/}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    run govc vm.power -on "${path}"
    return 0
  fi
  # Juste après le redémarrage du vCenter (HA/DRS en cours de configuration),
  # vCenter peut refuser le placement (« No host is compatible ») : on réessaie.
  while ! err=$(govc vm.power -on "${path}" 2>&1 > /dev/null); do
    [[ "$(vm_power_state "${path}")" == "poweredOn" ]] && return 0
    if [[ "${attempt}" -ge "${VM_POWERON_RETRIES}" ]]; then
      log_error "  ${err}"
      log_error "  Derniers événements de '${path##*/}' :"
      govc events -n 8 "${path}" 2> /dev/null | sed 's/^/    /' >&2 || true
      die "Power On de '${path##*/}' refusé ${attempt} fois. Corrige la cause ci-dessus puis relance avec --from-step <étape>."
    fi
    log_warn "  Power On refusé (${err##*: }) — nouvel essai dans ${VM_POWERON_RETRY_DELAY}s (${attempt}/${VM_POWERON_RETRIES})."
    sleep "${VM_POWERON_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done
}

wait_vm_tools() {
  wait_until "${VM_START_TIMEOUT}" "VMware Tools de ${1##*/}" vm_tools_running "${1}" ||
    die "'${1##*/}' : VMware Tools pas démarrés après ${VM_START_TIMEOUT}s."
}

# step_ui_or_vm_start <n> <libellé> <mode> <instruction UI> <ids...>
step_ui_or_vm_start() {
  local n="${1}" label="${2}" mode="${3}" howto="${4}"
  shift 4
  log_step "Étape ${n}/${LAST_STEP} — ${label}"
  case "${mode}" in
    none) log "Non déployé (mode none) — étape ignorée." ;;
    ui) manual_checkpoint "${howto}" ;;
    vm)
      log_warn "Mode 'vm' : Power On direct des VMs, hors procédure officielle (raccourci de lab)."
      # ordre inverse de l'arrêt
      local -a ordered=()
      local line
      while IFS= read -r line; do
        [[ -n "${line}" ]] && ordered+=("${line}")
      done <<< "$(reverse_lines ${@+"${@}"})"
      power_on_vms "${label}" sequential ${ordered[@]+"${ordered[@]}"}
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Pré-vérifications
# ---------------------------------------------------------------------------
check_tools() {
  local -a tools=("curl" "jq" "govc")
  if step_in_range 1 && [[ "${MGMT_STORAGE}" == "vsan" && "${VSAN_SHUTDOWN_MODE}" == "manual" ]]; then
    tools+=("ssh")
    [[ -n "${ESX_ROOT_PASSWORD}" ]] && tools+=("sshpass")
  fi
  local tool missing=0
  for tool in "${tools[@]}"; do
    if command -v "${tool}" > /dev/null 2>&1; then
      log "Trouvé : ${tool} ($(command -v "${tool}"))"
    else
      log_error "Outil manquant : ${tool}"
      missing=$((missing + 1))
    fi
  done
  [[ "${missing}" -eq 0 ]] || die "${missing} outil(s) manquant(s)."
}

write_basic_auth_cfg() {
  # write_basic_auth_cfg <fichier> <user> <mot de passe>
  local esc="${3//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  (
    umask 077
    printf 'user = "%s:%s"\n' "${2}" "${esc}" > "${1}"
  )
}

preflight() {
  log_step "Pré-vérifications"
  check_tools

  [[ -n "${GOVC_URL}" ]] || die "GOVC_URL non défini (URL du vCenter de gestion)."
  [[ -n "${MGMT_CLUSTER}" ]] || die "MGMT_CLUSTER non défini."
  prompt_secret GOVC_PASSWORD "Mot de passe vCenter pour ${GOVC_USERNAME}"
  export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE

  STATE_FILE="${LOG_DIR}/cluster_state_${MGMT_CLUSTER}.env"
  if [[ -f "${STATE_FILE}" ]]; then
    log "État sauvegardé à l'arrêt : ${STATE_FILE}"
    VC_HOST_NAME=$(read_state VCENTER_HOST)
    log "  Hôte du vCenter : ${VC_HOST_NAME:-non enregistré} — HA=$(read_state HA_ENABLED) DRS=$(read_state DRS_ENABLED) ($(read_state DRS_MODE))"
  else
    log_warn "Pas d'état sauvegardé (${STATE_FILE}) : hôte du vCenter recherché sur les hôtes, HA/DRS non restaurés."
    STATE_FILE=""
  fi

  if vc_reachable; then
    VC_ONLINE="true"
    log "vCenter ${GOVC_URL} joignable."
  elif step_in_range 1; then
    log "vCenter ${GOVC_URL} injoignable (normal, il sera démarré à l'étape 1)."
  elif [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "vCenter injoignable : le dry-run listera les actions sans vérifier l'inventaire."
  else
    die "vCenter ${GOVC_URL} injoignable : reprends à l'étape 1 (--from-step 1)."
  fi

  if step_in_range 1; then
    [[ "${#ESX_HOSTS[@]}" -gt 0 ]] || die "ESX_HOSTS est vide : nécessaire pour attendre le démarrage des hôtes."
    [[ -n "${VCENTER_VM}" ]] || die "VCENTER_VM non défini."
    prompt_secret ESX_ROOT_PASSWORD "Mot de passe ${ESX_SSH_USER} des ESX (Host Client)"
  fi
  if step_in_range 3 && [[ -n "${NSX_MANAGER_FQDN}" ]]; then
    prompt_secret NSX_ADMIN_PASSWORD "Mot de passe ${NSX_ADMIN_USER} de NSX Manager"
    write_basic_auth_cfg "${NSX_CURL_CFG}" "${NSX_ADMIN_USER}" "${NSX_ADMIN_PASSWORD}"
  fi
  if step_in_range 6 && [[ "${#VCFOPS_VMS[@]}" -gt 0 && "${VCFOPS_OFFLINE_MODE}" == "api" ]]; then
    [[ -n "${VCFOPS_PRIMARY_FQDN}" ]] || die "VCFOPS_PRIMARY_FQDN non défini."
    prompt_secret VCFOPS_ADMIN_PASSWORD "Mot de passe ${VCFOPS_ADMIN_USER} de VCF Operations (/admin)"
    write_vcfops_curl_cfg
  fi
  if step_in_range 7 && [[ -n "${VCFMS_NODE_IP}" ]]; then
    [[ "${#VCFMS_VMS[@]}" -gt 0 || -n "${VCFMS_VM_PATTERN}" ]] ||
      die "Au démarrage l'API VCFMS est éteinte : renseigne VCFMS_VMS ou VCFMS_VM_PATTERN pour trouver les nœuds."
    prompt_secret VMSP_PASSWORD "Mot de passe ${VMSP_API_USER} (VCF services runtime)"
  fi
}

confirm_execution() {
  log_step "Plan de démarrage (étapes ${FROM_STEP} à ${TO_STEP})"
  {
    echo "  1  ESX / stockage / vCenter : ${#ESX_HOSTS[@]} hôte(s), stockage ${MGMT_STORAGE}, vCenter ${VCENTER_VM:-?} + ${#INFRA_VMS[@]} VM(s) d'infra"
    echo "  2  SDDC Manager          : ${SDDC_MANAGER_VM:-non configuré}"
    echo "  3  NSX Manager           : ${#NSX_MANAGER_VMS[@]} VM(s), état STABLE via ${NSX_MANAGER_FQDN:-pause manuelle}"
    echo "  4  NSX Edge / VNA        : ${#NSX_EDGE_VMS[@]} VM(s)"
    echo "  5  Protection & recovery : ${#VLSR_VMS[@]} VM(s)"
    echo "  6  VCF Operations        : ${#VCFOPS_VMS[@]} VM(s), online via ${VCFOPS_OFFLINE_MODE}"
    echo "  7  VCF services runtime  : ${VCFMS_NODE_IP:-non configuré}"
    echo "  8  License server        : ${#LICENSE_SERVER_VMS[@]} VM(s)"
    echo "  9  Cloud proxies         : ${#CLOUD_PROXY_VMS[@]} VM(s)"
    echo "  10 VCF Ops for networks  : mode ${VCFNET_MODE}"
    echo "  11 VCF Automation        : mode ${VCFA_MODE}"
    echo "  12 Workloads mgmt        : ${#WORKLOAD_VMS[@]} VM(s)"
  } >&2
  log_warn "Rappels doc : démarrer le domaine de gestion AVANT les workload domains ; en démarrage de fleet complet, l'instance qui héberge VCF Operations en premier."

  [[ "${DRY_RUN}" == "true" || "${ASSUME_YES}" == "true" ]] && return 0
  [[ -t 0 ]] || die "Pas de terminal : utilise --yes pour confirmer."
  local answer=""
  read -r -p "Tape STARTUP pour lancer le démarrage : " answer
  [[ "${answer}" == "STARTUP" ]] || die "Annulé."
}

# ---------------------------------------------------------------------------
# Étape 1 — hôtes ESX, stockage, vCenter
# ---------------------------------------------------------------------------
esx_reachable() { esx_govc "${1}" about > /dev/null 2>&1; }


power_on_hosts() {
  local host cmd
  if [[ -n "${ESX_POWERON_CMD}" ]]; then
    for host in "${ESX_HOSTS[@]}"; do
      if esx_reachable "${host}"; then
        log "  ${host} répond déjà."
        continue
      fi
      cmd="${ESX_POWERON_CMD//\{host\}/${host}}"
      log "  Allumage de ${host} : ${cmd}"
      run bash -c "${cmd}" || log_warn "  Commande d'allumage en erreur pour ${host}."
    done
  else
    manual_checkpoint "Allume le stockage ${MGMT_STORAGE} puis les hôtes ${ESX_HOSTS[*]} (bouton, iLO/iDRAC/IPMI, AMT...)."
  fi
}

wait_hosts() {
  local host
  for host in ${@+"${@}"}; do
    wait_until "${ESX_BOOT_TIMEOUT}" "ESX ${host} joignable" esx_reachable "${host}" ||
      die "${host} ne répond pas après ${ESX_BOOT_TIMEOUT}s."
  done
}

esx_exit_maintenance() {
  local host="${1}" hpath mm
  [[ "${DRY_RUN}" == "true" ]] && {
    log "  [DRY-RUN] ${host} : sortie du mode maintenance si besoin"
    return 0
  }
  hpath=$(esx_host_path "${host}")
  mm=$(esx_govc "${host}" object.collect -s "${hpath}" runtime.inMaintenanceMode 2> /dev/null || echo "?")
  if [[ "${mm}" == "true" ]]; then
    log "  ${host} : sortie du mode maintenance"
    esx_govc "${host}" host.maintenance.exit "${hpath}" > /dev/null || die "${host} : sortie du mode maintenance impossible."
  fi
}

# esx_find_vm_host <vm> → hôte (parmi ESX_HOSTS) qui a la VM enregistrée
esx_find_vm_host() {
  local host
  for host in "${ESX_HOSTS[@]}"; do
    if [[ -n "$(esx_govc "${host}" find / -type m -name "${1}" 2> /dev/null | head -1)" ]]; then
      echo "${host}"
      return 0
    fi
  done
  return 1
}

# esx_power_on_vm <hôte> <vm> — Power On direct sur l'ESX (Host Client)
esx_power_on_vm() {
  local host="${1}" vm="${2}" path conn state
  path=$(esx_govc "${host}" find / -type m -name "${vm}" 2> /dev/null | head -1 || true)
  if [[ -z "${path}" ]]; then
    log_warn "  '${vm}' introuvable sur ${host} — ignorée."
    return 0
  fi
  if [[ "${DRY_RUN}" == "false" ]]; then
    # VM inaccessible tant que son datastore (NFS) n'est pas monté
    wait_until "${ESX_BOOT_TIMEOUT}" "datastore de ${vm} accessible" \
      esx_vm_connected "${host}" "${path}" ||
      die "'${vm}' reste inaccessible sur ${host} : le stockage est-il démarré et monté ?"
  fi
  state=$(esx_govc "${host}" object.collect -s "${path}" runtime.powerState 2> /dev/null || true)
  if [[ "${state}" == "poweredOn" ]]; then
    log "  '${vm}' déjà allumée."
    return 0
  fi
  log "  Power On : ${vm} (sur ${host})"
  run esx_govc "${host}" vm.power -on "${path}" > /dev/null || die "Power On de '${vm}' sur ${host} impossible."
  conn="VMware Tools de ${vm}"
  wait_until "${VM_START_TIMEOUT}" "${conn}" esx_vm_tools_running "${host}" "${path}" ||
    log_warn "  ${conn} pas démarrés après ${VM_START_TIMEOUT}s — on continue."
}

esx_vm_connected() {
  [[ "$(esx_govc "${1}" object.collect -s "${2}" runtime.connectionState 2> /dev/null)" == "connected" ]]
}

esx_vm_tools_running() {
  [[ "$(esx_govc "${1}" object.collect -s "${2}" guest.toolsRunningStatus 2> /dev/null)" == "guestToolsRunning" ]]
}

start_infra_and_vcenter_on_hosts() {
  local vm host
  # VMs d'infra (DNS/NTP/AD) d'abord : le vCenter en dépend
  for vm in ${INFRA_VMS[@]+"${INFRA_VMS[@]}"} "${VCENTER_VM}"; do
    if host=$(esx_find_vm_host "${vm}"); then
      esx_power_on_vm "${host}" "${vm}"
    elif [[ "${DRY_RUN}" == "true" ]]; then
      log "  [DRY-RUN] Power On de '${vm}' sur l'hôte où elle est enregistrée"
    else
      log_warn "  '${vm}' introuvable sur ${ESX_HOSTS[*]} — ignorée."
    fi
  done
}

wait_vcenter() {
  log "Attente du vCenter ${GOVC_URL} (jusqu'à ${VCENTER_START_TIMEOUT}s)..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    vc_reachable && VC_ONLINE="true"
    return 0
  fi
  wait_until "${VCENTER_START_TIMEOUT}" "API vCenter" vc_reachable ||
    die "Le vCenter ne répond pas après ${VCENTER_START_TIMEOUT}s. Vérifie https://${GOVC_URL#https://}/ui puis relance avec --from-step 1."
  VC_ONLINE="true"
  CLUSTER_PATH=$(govc find / -type c -name "${MGMT_CLUSTER}" 2> /dev/null | head -1 || true)
  [[ -n "${CLUSTER_PATH}" ]] || die "Cluster '${MGMT_CLUSTER}' introuvable dans le vCenter."
}

vc_host_connected() { [[ "$(host_state "${1}")" == "connected" ]]; }

reconnect_cluster_hosts() {
  local hpath mm
  [[ "${VC_ONLINE}" == "true" && -n "${CLUSTER_PATH}" ]] || {
    log "  [DRY-RUN] Hôtes du cluster : attente de la connexion à vCenter puis sortie du mode maintenance"
    return 0
  }
  while IFS= read -r hpath; do
    [[ -z "${hpath}" ]] && continue
    wait_until "${ESX_BOOT_TIMEOUT}" "${hpath##*/} connecté à vCenter" vc_host_connected "${hpath}" ||
      die "${hpath##*/} n'est pas connecté à vCenter après ${ESX_BOOT_TIMEOUT}s."
    mm=$(govc object.collect -s "${hpath}" runtime.inMaintenanceMode 2> /dev/null || echo "?")
    if [[ "${mm}" == "true" ]]; then
      log "  ${hpath##*/} : sortie du mode maintenance"
      run govc host.maintenance.exit "${hpath}" > /dev/null || die "${hpath##*/} : sortie du mode maintenance impossible."
    fi
  done <<< "$(govc find "${CLUSTER_PATH}" -type h 2> /dev/null || true)"
}

restore_ha_drs() {
  local ha drs drs_mode target="${CLUSTER_PATH:-${MGMT_CLUSTER}}"
  if [[ -z "${STATE_FILE}" ]]; then
    log_warn "Pas d'état sauvegardé : vérifie à la main vSphere HA et DRS sur ${MGMT_CLUSTER}."
    return 0
  fi
  ha=$(read_state HA_ENABLED)
  drs=$(read_state DRS_ENABLED)
  drs_mode=$(read_state DRS_MODE)
  if [[ "${drs}" == "true" && "${drs_mode}" =~ ^(manual|partiallyAutomated|fullyAutomated)$ ]]; then
    log "Restauration de DRS : ${drs_mode}"
    run govc cluster.change -drs-mode "${drs_mode}" "${target}" || log_warn "Échec restauration DRS."
  fi
  if [[ "${ha}" == "true" ]]; then
    log "Réactivation de vSphere HA"
    run govc cluster.change -ha-enabled=true "${target}" || log_warn "Échec réactivation HA."
    wait_ha_ready
  else
    log "HA était '${ha:-inconnu}' avant l'arrêt : pas de changement."
  fi
}

# HA configuré sur l'hôte : maître élu ou connecté au maître
host_ha_ready() {
  local state
  state=$(govc object.collect -s "${1}" runtime.dasHostState.state 2> /dev/null || true)
  [[ "${state}" == "master" || "${state}" == "connectedToMaster" ]]
}

wait_ha_ready() {
  local hpath
  [[ "${DRY_RUN}" == "true" || -z "${CLUSTER_PATH}" ]] && return 0
  log "Attente de la configuration de vSphere HA sur les hôtes (jusqu'à ${HA_READY_TIMEOUT}s)..."
  while IFS= read -r hpath; do
    [[ -z "${hpath}" ]] && continue
    wait_until "${HA_READY_TIMEOUT}" "HA sur ${hpath##*/}" host_ha_ready "${hpath}" ||
      log_warn "  HA pas prêt sur ${hpath##*/} après ${HA_READY_TIMEOUT}s (état : $(govc object.collect -s "${hpath}" runtime.dasHostState.state 2> /dev/null || echo ?)) — on continue."
  done <<< "$(govc find "${CLUSTER_PATH}" -type h 2> /dev/null || true)"
}

start_nfs() {
  local -a order=()
  local host
  power_on_hosts

  if [[ -z "${VC_HOST_NAME}" ]]; then
    wait_hosts "${ESX_HOSTS[@]}"
    VC_HOST_NAME=$(esx_find_vm_host "${VCENTER_VM}" || true)
    [[ -n "${VC_HOST_NAME}" || "${DRY_RUN}" == "true" ]] ||
      die "VM vCenter '${VCENTER_VM}' introuvable sur ${ESX_HOSTS[*]}."
    VC_HOST_NAME="${VC_HOST_NAME:-${ESX_HOSTS[0]}}"
  fi
  log "Hôte du vCenter : ${VC_HOST_NAME} (démarré en premier, doc NFS/FC)."
  wait_hosts "${VC_HOST_NAME}"
  esx_exit_maintenance "${VC_HOST_NAME}"

  start_infra_and_vcenter_on_hosts
  wait_vcenter

  # Les autres hôtes : attente du boot, reconnexion à vCenter, sortie de maintenance
  for host in "${ESX_HOSTS[@]}"; do
    [[ "$(echo "${host}" | tr '[:upper:]' '[:lower:]')" == "$(echo "${VC_HOST_NAME}" | tr '[:upper:]' '[:lower:]')" ]] ||
      order+=("${host}")
  done
  wait_hosts ${order[@]+"${order[@]}"}
  reconnect_cluster_hosts
  restore_ha_drs
}

start_vsan_manual() {
  local host out first="${ESX_HOSTS[0]}" hpath
  power_on_hosts
  wait_hosts "${ESX_HOSTS[@]}"

  for host in "${ESX_HOSTS[@]}"; do
    if [[ "${ENABLE_ESX_SSH}" == "true" ]]; then
      hpath=$(esx_host_path "${host}" || true)
      run esx_govc "${host}" host.service -host "${hpath}" start TSM-SSH > /dev/null 2>&1 ||
        log_warn "  ${host} : démarrage SSH impossible via l'API."
    fi
    esx_exit_maintenance "${host}"
  done

  log "Récupération du cluster vSAN sur ${first} : reboot_helper.py recover (un seul hôte)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] esx_ssh ${first} python ${REBOOT_HELPER} recover"
  else
    out=$(esx_ssh "${first}" "python ${REBOOT_HELPER} recover" 2>&1) || true
    printf '%s\n' "${out}" | sed 's/^/    /' >&2
    [[ "${out}" == *"completed successfully"* ]] ||
      die "reboot_helper.py recover n'a pas abouti (KB 390160 / 430304 / 427701). Ne pas démarrer le vCenter avant résolution."
  fi
  for host in "${ESX_HOSTS[@]}"; do
    log "  ${host} : /VSAN/IgnoreClusterMemberListUpdates = 0"
    run esx_ssh "${host}" "esxcfg-advcfg -s 0 /VSAN/IgnoreClusterMemberListUpdates" > /dev/null
  done

  start_infra_and_vcenter_on_hosts
  wait_vcenter
  reconnect_cluster_hosts
  restore_ha_drs
}

start_vsan_wizard() {
  power_on_hosts
  wait_hosts "${ESX_HOSTS[@]}"
  log "Arrêt fait avec le Shutdown Cluster wizard : le vCenter et vSAN redémarrent avec le cluster."
  if [[ "${DRY_RUN}" == "false" ]] && ! wait_until "${VCENTER_START_TIMEOUT}" "API vCenter" vc_reachable; then
    manual_checkpoint "Le vCenter ne répond pas : démarre-le depuis le Host Client de son hôte."
  fi
  wait_vcenter
  manual_checkpoint "vSphere Client > clic droit sur '${MGMT_CLUSTER}' > vSAN > Restart cluster, puis vérifie vSAN Skyline Health."
  reconnect_cluster_hosts
  restore_ha_drs
}

step_1_esx_vcenter() {
  log_step "Étape 1/${LAST_STEP} — Hôtes ESX, stockage et vCenter (${MGMT_STORAGE})"
  if [[ "${VC_ONLINE}" == "true" ]]; then
    log "vCenter déjà joignable : on vérifie seulement les hôtes du cluster."
    wait_vcenter
    reconnect_cluster_hosts
    restore_ha_drs
    return 0
  fi
  if [[ "${MGMT_STORAGE}" == "nfs" ]]; then
    start_nfs
  elif [[ "${VSAN_SHUTDOWN_MODE}" == "wizard" ]]; then
    start_vsan_wizard
  else
    start_vsan_manual
  fi
}

# ---------------------------------------------------------------------------
# Étapes 2 à 12
# ---------------------------------------------------------------------------
step_2_sddc_manager() {
  log_step "Étape 2/${LAST_STEP} — SDDC Manager"
  power_on_vms "SDDC Manager" sequential ${SDDC_MANAGER_VM:+"${SDDC_MANAGER_VM}"}
}

nsx_cluster_status() {
  curl -sk --fail --max-time 30 -K "${NSX_CURL_CFG}" -H "Accept: application/json" \
    "https://${NSX_MANAGER_FQDN}/api/v1/cluster/status" 2> /dev/null |
    jq -r '.detailed_cluster_status.overall_status // .mgmt_cluster_status.status // "UNKNOWN"' 2> /dev/null ||
    echo "UNREACHABLE"
}

nsx_stable() { [[ "$(nsx_cluster_status)" == "STABLE" ]]; }

step_3_nsx_managers() {
  log_step "Étape 3/${LAST_STEP} — NSX Manager"
  power_on_vms "NSX Manager" parallel ${NSX_MANAGER_VMS[@]+"${NSX_MANAGER_VMS[@]}"}
  [[ "${#NSX_MANAGER_VMS[@]}" -eq 0 ]] && return 0
  if [[ -n "${NSX_MANAGER_FQDN}" ]]; then
    log "Attente du cluster NSX Manager STABLE (https://${NSX_MANAGER_FQDN}, jusqu'à ${NSX_START_TIMEOUT}s)..."
    wait_until "${NSX_START_TIMEOUT}" "cluster NSX STABLE" nsx_stable ||
      die "Cluster NSX pas STABLE après ${NSX_START_TIMEOUT}s (état : $(nsx_cluster_status)). Vérifie System > Appliances puis relance avec --from-step 3."
  else
    manual_checkpoint "NSX Manager > System > Configuration > Appliances : attends que le cluster soit « Stable » et tous les nœuds disponibles (NSX_MANAGER_FQDN permet d'automatiser cette attente)."
  fi
}

step_4_nsx_edges() {
  log_step "Étape 4/${LAST_STEP} — NSX Edge / VNA du domaine de gestion"
  power_on_vms "NSX Edge" parallel ${NSX_EDGE_VMS[@]+"${NSX_EDGE_VMS[@]}"}
}

step_5_protection_recovery() {
  log_step "Étape 5/${LAST_STEP} — Protection & recovery (VMware Live Site Recovery)"
  power_on_vms "Protection & recovery" sequential ${VLSR_VMS[@]+"${VLSR_VMS[@]}"}
}

vcfops_api_up() {
  local s
  s=$(vcfops_online_state)
  [[ "${s}" != "UNREACHABLE" ]]
}

vcfops_bring_online_api() {
  local state elapsed=0
  log "Attente de l'API d'administration de VCF Operations..."
  wait_until "${VM_START_TIMEOUT}" "API CaSA ${VCFOPS_PRIMARY_FQDN}" vcfops_api_up ||
    die "API CaSA de ${VCFOPS_PRIMARY_FQDN} injoignable après ${VM_START_TIMEOUT}s."
  state=$(vcfops_online_state)
  log "État du cluster VCF Operations : ${state}"
  if [[ "${state}" == "ONLINE" ]]; then
    log "Cluster déjà online."
    return 0
  fi
  log "Bring Cluster Online (API CaSA, KB 313533) — peut prendre jusqu'à ~1 h."
  run vcfops_curl -X POST "https://${VCFOPS_PRIMARY_FQDN}/casa/sysadmin/cluster/online_state" \
    -d '{"online_state":"ONLINE","online_state_reason":null}' > /dev/null ||
    die "Échec de la requête 'Bring Cluster Online'."
  [[ "${DRY_RUN}" == "true" ]] && return 0

  while true; do
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
    state=$(vcfops_online_state)
    case "${state}" in
      ONLINE)
        log "Cluster VCF Operations online (${elapsed}s)."
        return 0
        ;;
      FAILURE)
        die "Échec du passage online : voir https://${VCFOPS_PRIMARY_FQDN}/admin (KB 446606)."
        ;;
      *) [[ $((elapsed % 60)) -lt "${POLL_INTERVAL}" ]] && log "  État : ${state} (${elapsed}s)" ;;
    esac
    [[ "${elapsed}" -lt "${VCFOPS_ONLINE_TIMEOUT}" ]] ||
      die "Cluster VCF Operations pas online après ${VCFOPS_ONLINE_TIMEOUT}s."
  done
}

step_6_vcf_operations() {
  log_step "Étape 6/${LAST_STEP} — VCF Operations"
  if [[ "${#VCFOPS_VMS[@]}" -eq 0 ]]; then
    log "VCFOPS_VMS vide — étape ignorée."
    return 0
  fi
  # KB 341964 : primary → replica → data, soit l'inverse de l'ordre d'arrêt
  local -a ordered=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && ordered+=("${line}")
  done <<< "$(reverse_lines "${VCFOPS_VMS[@]}")"
  power_on_vms "VCF Operations" sequential "${ordered[@]}"

  if [[ "${VCFOPS_OFFLINE_MODE}" == "api" ]]; then
    vcfops_bring_online_api
  else
    manual_checkpoint "https://${VCFOPS_PRIMARY_FQDN:-<vcf_operations_fqdn>}/admin (admin) > System Status > Bring Cluster Online. Attends l'état Online (jusqu'à ~1 h)."
  fi
}

# Nœuds du VCF services runtime depuis la conf (l'API est éteinte au démarrage)
vcfms_vm_paths() {
  if [[ "${#VCFMS_VMS[@]}" -gt 0 ]]; then
    resolve_vms "${VCFMS_VMS[@]}"
  elif [[ -n "${VCFMS_VM_PATTERN}" ]]; then
    govc find / -type m -name "${VCFMS_VM_PATTERN}" 2> /dev/null || true
  fi
}

vcfms_api_ready() {
  local base="https://${VCFMS_NODE_IP}:${VCFMS_NODE_PORT}" body token payload_file="${TMP_DIR}/vcfms_login.json"
  (
    umask 077
    jq -n --arg u "${VMSP_API_USER}" --arg p "${VMSP_PASSWORD}" '{username: $u, password: $p}' > "${payload_file}"
  )
  body=$(vcfms_http -X POST "${base}/api/v1/auth/login" -H "Content-Type: application/json" \
    --data-binary "@${payload_file}")
  rm -f "${payload_file}"
  token=$(printf '%s' "${body}" | jq -r '.token // empty' 2> /dev/null || true)
  [[ -n "${token}" ]] || return 1
  vcfms_http "${base}/api/v1/components" -H "Authorization: Bearer ${token}" -H "Accept: application/json" > /dev/null
  [[ "$(vcfms_http_code)" == "200" ]]
}

step_7_vcf_services_runtime() {
  log_step "Étape 7/${LAST_STEP} — VCF management services (VCF services runtime)"
  if [[ -z "${VCFMS_NODE_IP}" ]]; then
    log "VCFMS_NODE_IP non défini — étape ignorée."
    return 0
  fi
  if [[ "${VC_ONLINE}" != "true" ]]; then
    log "  [DRY-RUN] vCenter injoignable — Power On des nœuds control plane, ${VCFMS_CONTROL_WAIT}s d'attente, puis des workers."
    return 0
  fi

  local out path mem min=""
  local -a all=() controls=() workers=()
  out=$(vcfms_vm_paths) || die "Nœuds VCF services runtime introuvables."
  while IFS= read -r path; do
    [[ -n "${path}" ]] && all+=("${path}")
  done <<< "${out}"
  [[ "${#all[@]}" -gt 0 ]] || die "Aucun nœud VCF services runtime trouvé (VCFMS_VMS / VCFMS_VM_PATTERN)."

  # Control plane : VCFMS_CONTROL_VMS, sinon les VMs avec le moins de mémoire (doc)
  if [[ "${#VCFMS_CONTROL_VMS[@]}" -gt 0 ]]; then
    local cp_paths
    cp_paths=$(resolve_vms "${VCFMS_CONTROL_VMS[@]}") || die "Résolution de VCFMS_CONTROL_VMS impossible."
    for path in "${all[@]}"; do
      if [[ $'\n'"${cp_paths}"$'\n' == *$'\n'"${path}"$'\n'* ]]; then controls+=("${path}"); else workers+=("${path}"); fi
    done
  else
    for path in "${all[@]}"; do
      mem=$(govc object.collect -s "${path}" config.hardware.memoryMB 2> /dev/null || echo 0)
      [[ -z "${min}" || "${mem}" -lt "${min}" ]] && min="${mem}"
    done
    for path in "${all[@]}"; do
      mem=$(govc object.collect -s "${path}" config.hardware.memoryMB 2> /dev/null || echo 0)
      if [[ "${mem}" -eq "${min}" ]]; then controls+=("${path}"); else workers+=("${path}"); fi
    done
    [[ "${#workers[@]}" -eq 0 ]] &&
      log_warn "Toutes les VMs ont la même mémoire : impossible de distinguer control plane et workers, elles démarrent ensemble (renseigne VCFMS_CONTROL_VMS pour préciser)."
  fi

  log "Control plane : $(for p in "${controls[@]}"; do printf '%s ' "${p##*/}"; done)"
  power_on_vms "VCF services runtime — control plane" parallel "${controls[@]}"
  if [[ "${#workers[@]}" -gt 0 ]]; then
    log "Attente de ${VCFMS_CONTROL_WAIT}s avant les workers (KB 440862)..."
    [[ "${DRY_RUN}" == "true" ]] || sleep "${VCFMS_CONTROL_WAIT}"
    log "Workers : $(for p in "${workers[@]}"; do printf '%s ' "${p##*/}"; done)"
    power_on_vms "VCF services runtime — workers" parallel "${workers[@]}"
  fi

  log "Attente de l'API de gestion ${VCFMS_NODE_IP} (récupération automatique ~20 min)..."
  if ! wait_until "${VCFMS_START_TIMEOUT}" "API VCF services runtime" vcfms_api_ready; then
    log_warn "L'API de gestion ne répond pas après ${VCFMS_START_TIMEOUT}s."
  fi
  log_warn "À vérifier : VCF Operations > Build > Lifecycle > VCF Management Components > VCF services runtime : tous les services « running », et aucun nouveau worker en cours de redéploiement. Sinon, après 15-20 min : KB 440862."
}

step_8_license_server() {
  log_step "Étape 8/${LAST_STEP} — License server"
  power_on_vms "License server" sequential ${LICENSE_SERVER_VMS[@]+"${LICENSE_SERVER_VMS[@]}"}
}

step_9_cloud_proxies() {
  log_step "Étape 9/${LAST_STEP} — Cloud proxies"
  power_on_vms "Cloud proxies" parallel ${CLOUD_PROXY_VMS[@]+"${CLOUD_PROXY_VMS[@]}"}
}

step_10_vcf_ops_networks() {
  step_ui_or_vm_start 10 "VCF Operations for networks" "${VCFNET_MODE}" \
    "VCF Operations > Build > Lifecycle > VCF Management Components > VCF Operations for networks > Actions > State management > Power on. Attends la fin de la tâche." \
    ${VCFNET_VMS[@]+"${VCFNET_VMS[@]}"}
}

step_11_vcf_automation() {
  step_ui_or_vm_start 11 "VCF Automation" "${VCFA_MODE}" \
    "VCF Operations > Build > Lifecycle > VCF Management Components > Components > VCF Automation > Actions > State management > Power on. Attends la fin de la tâche." \
    ${VCFA_VMS[@]+"${VCFA_VMS[@]}"}
}

step_12_workloads() {
  log_step "Étape 12/${LAST_STEP} — Workloads du domaine de gestion"
  power_on_vms "Workloads" parallel ${WORKLOAD_VMS[@]+"${WORKLOAD_VMS[@]}"}
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args ${@+"${@}"}
  load_config
  setup_logging

  log "VCF Lab Startup v${SCRIPT_VERSION} — mode $([[ "${DRY_RUN}" == "true" ]] && echo DRY-RUN || echo LIVE)"
  log "Configuration : ${CONFIG_FILE}"
  log "Journal       : ${LOG_FILE}"

  preflight
  confirm_execution

  if [[ "${VC_ONLINE}" == "true" ]]; then
    CLUSTER_PATH=$(govc find / -type c -name "${MGMT_CLUSTER}" 2> /dev/null | head -1 || true)
  fi

  local step
  for step in $(seq "${FROM_STEP}" "${TO_STEP}"); do
    case "${step}" in
      1) step_1_esx_vcenter ;;
      2) step_2_sddc_manager ;;
      3) step_3_nsx_managers ;;
      4) step_4_nsx_edges ;;
      5) step_5_protection_recovery ;;
      6) step_6_vcf_operations ;;
      7) step_7_vcf_services_runtime ;;
      8) step_8_license_server ;;
      9) step_9_cloud_proxies ;;
      10) step_10_vcf_ops_networks ;;
      11) step_11_vcf_automation ;;
      12) step_12_workloads ;;
    esac
  done

  log ""
  log "Étapes ${FROM_STEP} à ${TO_STEP} terminées."
  log "Ensuite (doc) : démarrer les workload domains et leurs workloads."
}

main ${@+"${@}"}

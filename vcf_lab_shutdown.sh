#!/usr/bin/env bash
#
# vcf_lab_shutdown.sh — Arrêt ordonné du domaine de gestion d'un lab VCF 9.1
#
# Inspiré de :
#   - Doc Broadcom VCF 9.1 « Shut Down the Management Domain » (ordre d'arrêt)
#   - Script officiel vcf_services_runtime_shutdown.sh (KB 440874), appelé
#     tel quel pour l'étape 5
#   - KB 341964 : ordre d'arrêt des nœuds VCF Operations
#   - KB 313533 : API CaSA online_state (cluster VCF Operations offline)
#   - vSAN « Manually Shut Down and Restart the vSAN Cluster » / KB 322144
#     (reboot_helper.py) pour l'arrêt scripté de vSAN
#
# Ordre d'arrêt (doc VCF 9.1) :
#    0  Workloads / VMs hors VCF du domaine de gestion (prérequis de la doc)
#    1  VCF Automation                (VCF Operations > State management)
#    2  VCF Operations for networks   (VCF Operations)
#    3  Cloud proxies                 (Shut down Guest OS)
#    4  License server                (Shut down Guest OS)
#    5  VCF services runtime          (script officiel, puis Shut down Guest OS)
#    6  VCF Operations                (cluster offline, puis nœuds — KB 341964)
#    7  Protection & recovery (VLSR)  (Shut down Guest OS)
#    8  NSX Edge / VNA                (Shut down Guest OS)
#    9  NSX Manager                   (Shut down Guest OS)
#   10  SDDC Manager                  (Shut down Guest OS)
#   11  vCenter, VMs d'infra (DNS/NTP/AD), stockage et hôtes ESX
#       - vSAN : reboot_helper.py (scripté) ou Shutdown Cluster wizard
#       - NFS/FC : hôtes sans vCenter en maintenance + arrêt via vCenter,
#         puis vCenter et son hôte en direct (équivalent Host Client)
#
# À exécuter depuis une machine d'admin HORS du domaine de gestion
# (pas depuis SDDC Manager : il est arrêté à l'étape 10).
#
# Usage :
#   vcf_lab_shutdown.sh [OPTIONS]
#
# Options :
#   --config FICHIER        Fichier de configuration (défaut, à côté du script :
#                           vcf_lab_shutdown.local.conf s'il existe, sinon
#                           vcf_lab_shutdown.conf).
#   --dry-run               Affiche les actions prévues sans rien arrêter.
#   --from-step N           Reprend à l'étape N (0-11).
#   --to-step N             S'arrête après l'étape N (0-11).
#   --yes                   Pas de confirmation initiale (les actions
#                           manuelles restent interactives).
#   --force-poweroff        Hard power-off si VMware Tools absents ou si
#                           l'arrêt Guest OS dépasse le délai.
#   --skip-snapshot-check   Ignore la vérification des snapshots.
#   --help                  Affiche cette aide.
#
# Secrets (variables d'environnement, sinon demandés interactivement) :
#   GOVC_PASSWORD           Mot de passe vCenter (GOVC_URL/GOVC_USERNAME dans la conf).
#   VMSP_PASSWORD           Mot de passe vmware-system-user (VCF services runtime).
#   VCFOPS_ADMIN_PASSWORD   Mot de passe admin local VCF Operations (/admin).
#   ESX_ROOT_PASSWORD       Mot de passe root ESX (sinon clé SSH ; sshpass requis).
#
# Compatible bash 3.2+ (macOS) et Linux. Outils : curl, jq, govc, ssh
# (+ sshpass si ESX_ROOT_PASSWORD est utilisé).
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
readonly LAST_STEP=11
readonly LOG_PREFIX="vcf_lab_shutdown"

# shellcheck source=vcf_lab_common.sh
source "${SCRIPT_DIR}/vcf_lab_common.sh"

# ---------------------------------------------------------------------------
# Options CLI
# ---------------------------------------------------------------------------
DRY_RUN="false"
ASSUME_YES="false"
FORCE_POWEROFF="false"
SKIP_SNAPSHOT_CHECK="false"
FROM_STEP=0
TO_STEP="${LAST_STEP}"
CONFIG_FILE="$(default_config_file)"

TMP_DIR="$(mktemp -d)"
VCFOPS_CURL_CFG="${TMP_DIR}/vcfops.curlrc"

# Remplis pendant les pré-vérifications
CLUSTER_PATH=""
VCFMS_VM_IDS=()

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

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
      --force-poweroff)
        FORCE_POWEROFF="true"
        shift
        ;;
      --skip-snapshot-check)
        SKIP_SNAPSHOT_CHECK="true"
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
  [[ "${FROM_STEP}" -le "${TO_STEP}" && "${TO_STEP}" -le "${LAST_STEP}" ]] ||
    die "Plage d'étapes invalide : ${FROM_STEP}..${TO_STEP} (0..${LAST_STEP})."
}

# ---------------------------------------------------------------------------
# Helpers vCenter (govc) — utilisables tant que le vCenter est en ligne
# ---------------------------------------------------------------------------

hard_poweroff() {
  log_warn "  Hard power-off : ${1##*/}"
  run govc vm.power -off -force "${1}" > /dev/null
}

# request_guest_shutdown <chemin> — lance « Shut down Guest OS »
request_guest_shutdown() {
  local path="${1}" name="${1##*/}" state tools
  state=$(vm_power_state "${path}")
  if [[ "${state}" == "poweredOff" ]]; then
    log "  '${name}' déjà éteinte."
    return 0
  fi
  tools=$(vm_tools_status "${path}")
  if [[ "${tools}" != "guestToolsRunning" ]]; then
    if [[ "${FORCE_POWEROFF}" == "true" ]]; then
      log_warn "  VMware Tools non actifs sur '${name}' (${tools})."
      hard_poweroff "${path}"
      return 0
    fi
    die "VMware Tools non actifs sur '${name}' (${tools}) : arrêt propre impossible. Éteins-la à la main ou relance avec --force-poweroff."
  fi
  log "  Shut down Guest OS : ${name}"
  run govc vm.power -s "${path}" > /dev/null
}

# wait_vm_off <chemin>
wait_vm_off() {
  local path="${1}" name="${1##*/}" elapsed=0
  [[ "${DRY_RUN}" == "true" ]] && return 0
  while [[ "$(vm_power_state "${path}")" != "poweredOff" ]]; do
    if [[ "${elapsed}" -ge "${VM_SHUTDOWN_TIMEOUT}" ]]; then
      if [[ "${FORCE_POWEROFF}" == "true" ]]; then
        log_warn "  '${name}' toujours allumée après ${VM_SHUTDOWN_TIMEOUT}s."
        hard_poweroff "${path}"
        return 0
      fi
      die "'${name}' toujours allumée après ${VM_SHUTDOWN_TIMEOUT}s (relance avec --force-poweroff pour forcer)."
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  log "  '${name}' éteinte (${elapsed}s)."
}

# shutdown_vms <libellé> <sequential|parallel> <ids...>
shutdown_vms() {
  local label="${1}" mode="${2}" out path
  shift 2
  if [[ "${#}" -eq 0 ]]; then
    log "Aucune VM configurée pour « ${label} » — rien à faire."
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

  log "${label} : ${#paths[@]} VM(s), arrêt ${mode}."
  if [[ "${mode}" == "sequential" ]]; then
    for path in "${paths[@]}"; do
      request_guest_shutdown "${path}"
      wait_vm_off "${path}"
    done
  else
    for path in "${paths[@]}"; do
      request_guest_shutdown "${path}"
    done
    for path in "${paths[@]}"; do
      wait_vm_off "${path}"
    done
  fi
}

# verify_vms_off <libellé> <ids...> — contrôle après une action manuelle
verify_vms_off() {
  local label="${1}" out path state
  shift
  [[ "${#}" -eq 0 || "${DRY_RUN}" == "true" ]] && return 0
  out=$(resolve_vms "${@}") || die "Résolution des VMs « ${label} » impossible."
  local -a still_on=()
  while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    state=$(vm_power_state "${path}")
    [[ "${state}" == "poweredOff" ]] || still_on+=("${path##*/} (${state})")
  done <<< "${out}"
  if [[ "${#still_on[@]}" -gt 0 ]]; then
    log_error "${label} : VM(s) encore allumée(s) :"
    printf '    %s\n' "${still_on[@]}" >&2
    die "Vérifie la tâche dans VCF Operations avant de continuer."
  fi
  log "${label} : toutes les VMs sont éteintes."
}

# ---------------------------------------------------------------------------
# Helpers ESX (SSH) — utilisés quand le vCenter est arrêté
# ---------------------------------------------------------------------------

# esx_shutdown_vm <nom> — Shut down Guest OS depuis l'hôte, puis attente
esx_shutdown_vm() {
  local name="${1}" loc host id elapsed=0
  if ! loc=$(esx_find_vm "${name}"); then
    log_warn "  '${name}' introuvable sur les hôtes ESX — ignorée."
    return 0
  fi
  host="${loc%%|*}"
  id="${loc##*|}"
  if [[ "$(esx_vm_state "${host}" "${id}")" == "Powered off" ]]; then
    log "  '${name}' déjà éteinte (${host})."
    return 0
  fi

  log "  Shut down Guest OS : ${name} (vmid ${id} sur ${host})"
  if ! run esx_ssh "${host}" "vim-cmd vmsvc/power.shutdown ${id}" > /dev/null; then
    [[ "${FORCE_POWEROFF}" == "true" ]] ||
      die "Arrêt Guest OS de '${name}' refusé (VMware Tools ?). Relance avec --force-poweroff."
    log_warn "  Arrêt Guest OS refusé — hard power-off de '${name}'."
    run esx_ssh "${host}" "vim-cmd vmsvc/power.off ${id}" > /dev/null
  fi
  [[ "${DRY_RUN}" == "true" ]] && return 0

  while [[ "$(esx_vm_state "${host}" "${id}")" != "Powered off" ]]; do
    if [[ "${elapsed}" -ge "${VM_SHUTDOWN_TIMEOUT}" ]]; then
      [[ "${FORCE_POWEROFF}" == "true" ]] ||
        die "'${name}' toujours allumée après ${VM_SHUTDOWN_TIMEOUT}s."
      log_warn "  Délai dépassé — hard power-off de '${name}'."
      run esx_ssh "${host}" "vim-cmd vmsvc/power.off ${id}" > /dev/null
      break
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  log "  '${name}' éteinte (${elapsed}s)."
}

# esx_ensure_no_running_vms <hôte> — préalable au mode maintenance noAction
esx_ensure_no_running_vms() {
  local host="${1}" out entry id name
  local -a running=()
  out=$(esx_ssh "${host}" "vim-cmd vmsvc/getallvms" 2> /dev/null) ||
    die "Impossible de lister les VMs de ${host}."
  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    id="${entry%%|*}"
    name="${entry#*|}"
    [[ "$(esx_vm_state "${host}" "${id}")" == "Powered on" ]] || continue
    if [[ "${name}" == vCLS* ]]; then
      log "  ${host} : power-off de la VM système '${name}'."
      run esx_ssh "${host}" "vim-cmd vmsvc/power.off ${id}" > /dev/null || true
    else
      running+=("${name}")
    fi
  done <<< "$(printf '%s\n' "${out}" | list_getallvms)"

  if [[ "${#running[@]}" -gt 0 ]]; then
    [[ "${DRY_RUN}" == "true" ]] || die "${host} : VM(s) encore allumée(s) : ${running[*]} — éteins-les avant le mode maintenance."
    log_warn "${host} : VM(s) encore allumée(s) : ${running[*]} (dry-run : normal)"
  fi
}

# ---------------------------------------------------------------------------
# Pré-vérifications
# ---------------------------------------------------------------------------
check_tools() {
  local -a tools=("curl" "jq" "govc")
  if step_in_range 11 && [[ "${MGMT_STORAGE}" == "vsan" && "${VSAN_SHUTDOWN_MODE}" == "manual" ]]; then
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

all_configured_vms() {
  local vm
  for vm in ${WORKLOAD_VMS[@]+"${WORKLOAD_VMS[@]}"} \
    ${VCFA_VMS[@]+"${VCFA_VMS[@]}"} ${VCFNET_VMS[@]+"${VCFNET_VMS[@]}"} \
    ${CLOUD_PROXY_VMS[@]+"${CLOUD_PROXY_VMS[@]}"} \
    ${LICENSE_SERVER_VMS[@]+"${LICENSE_SERVER_VMS[@]}"} \
    ${VCFMS_VM_IDS[@]+"${VCFMS_VM_IDS[@]}"} ${VCFOPS_VMS[@]+"${VCFOPS_VMS[@]}"} \
    ${VLSR_VMS[@]+"${VLSR_VMS[@]}"} ${NSX_EDGE_VMS[@]+"${NSX_EDGE_VMS[@]}"} \
    ${NSX_MANAGER_VMS[@]+"${NSX_MANAGER_VMS[@]}"} ${SDDC_MANAGER_VM:+"${SDDC_MANAGER_VM}"} \
    ${VCENTER_VM:+"${VCENTER_VM}"} ${INFRA_VMS[@]+"${INFRA_VMS[@]}"}; do
    printf '%s\n' "${vm}"
  done
}

check_inventory_and_snapshots() {
  local vm path rc snaps missing=0
  local -a with_snap=()
  log "Vérification de l'inventaire et des snapshots des VMs configurées..."
  while IFS= read -r vm; do
    [[ -z "${vm}" ]] && continue
    rc=0
    path=$(resolve_vm "${vm}") || rc=$?
    if [[ "${rc}" -eq 3 ]]; then
      die "Impossible d'interroger le vCenter pour '${vm}' (voir l'erreur ci-dessus)."
    elif [[ "${rc}" -eq 2 ]]; then
      die "Rends le nom '${vm}' unique ou utilise un MoRef (VirtualMachine:vm-xx)."
    elif [[ "${rc}" -ne 0 ]]; then
      log_warn "  Introuvable : ${vm}"
      missing=$((missing + 1))
      continue
    fi
    log "  OK : ${path} ($(vm_power_state "${path}"))"
    if [[ "${SKIP_SNAPSHOT_CHECK}" == "false" ]]; then
      snaps=$(govc snapshot.tree -vm "${path}" 2> /dev/null || true)
      [[ -n "${snaps}" ]] && with_snap+=("${path##*/}")
    fi
  done <<< "$(all_configured_vms)"

  [[ "${missing}" -eq 0 ]] || log_warn "${missing} VM(s) configurée(s) introuvable(s) : elles seront ignorées."

  if [[ "${SKIP_SNAPSHOT_CHECK}" == "true" ]]; then
    log_warn "Vérification des snapshots ignorée (--skip-snapshot-check)."
  elif [[ "${#with_snap[@]}" -gt 0 ]]; then
    log_error "Snapshots présents sur : ${with_snap[*]}"
    log_error "Le précheck du VCF services runtime échoue s'il y a des snapshots sur ses nœuds."
    [[ "${DRY_RUN}" == "true" ]] || die "Supprime les snapshots ou relance avec --skip-snapshot-check."
  else
    log "Aucun snapshot sur les VMs configurées."
  fi
}

discover_vcfms_vms() {
  VCFMS_VM_IDS=()
  [[ -z "${VCFMS_NODE_IP}" ]] && return 0

  log "Découverte des nœuds VCF services runtime via l'API (${VCFMS_NODE_IP}:${VCFMS_NODE_PORT})..."
  local base="https://${VCFMS_NODE_IP}:${VCFMS_NODE_PORT}" body code token="" entry name moref parsed=""

  local payload_file="${TMP_DIR}/vcfms_login.json"
  (
    umask 077
    jq -n --arg u "${VMSP_API_USER}" --arg p "${VMSP_PASSWORD}" '{username: $u, password: $p}' > "${payload_file}"
  )
  body=$(vcfms_http -X POST "${base}/api/v1/auth/login" -H "Content-Type: application/json" \
    --data-binary "@${payload_file}")
  rm -f "${payload_file}"
  code=$(vcfms_http_code)
  if [[ "${code}" == "200" ]]; then
    token=$(printf '%s' "${body}" | jq -r '.token // empty' 2> /dev/null || true)
  fi
  if [[ -z "${token}" ]]; then
    log_warn "  Login API VCFMS : HTTP ${code} — ${body:0:300}"
  else
    log "  Login API VCFMS OK."
    vcfms_http "${base}/api/v1/components" -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json" > /dev/null
    code=$(vcfms_http_code)
    if [[ "${code}" == "404" ]]; then
      die "${VCFMS_NODE_IP} accepte le login mais ne sert pas l'API de gestion (GET /api/v1/components → 404). Utilise le FQDN ou la VIP du VCF services runtime dans VCFMS_NODE_IP, pas l'IP d'un nœud."
    fi
    log "  API de gestion joignable (GET /api/v1/components → HTTP ${code})."
    body=$(vcfms_http "${base}/api/v1/system/inventory/nodes" \
      -H "Authorization: Bearer ${token}" -H "Accept: application/json")
    code=$(vcfms_http_code)
    if [[ "${code}" != 2* ]]; then
      log_warn "  GET /api/v1/system/inventory/nodes : HTTP ${code} — ${body:0:300}"
      [[ "${code}" == "404" ]] && log_warn "  Endpoint absent sur ce build du VCF services runtime."
    else
      parsed=$(printf '%s' "${body}" | parse_vcfms_nodes || true)
      [[ -n "${parsed}" ]] ||
        log_warn "  Réponse d'inventaire non reconnue (HTTP ${code}) : ${body:0:500}"
    fi
  fi

  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    name="${entry%%|*}"
    moref="${entry#*|}"
    if [[ -z "${moref}" ]]; then
      log_warn "  Nœud '${name}' sans MoRef VM dans la réponse — ignoré."
      continue
    fi
    [[ "${moref}" == VirtualMachine:* ]] || moref="VirtualMachine:${moref}"
    log "  Nœud '${name}' → ${moref}"
    VCFMS_VM_IDS+=("${moref}")
  done <<< "${parsed}"

  [[ "${#VCFMS_VM_IDS[@]}" -gt 0 ]] && return 0

  if [[ "${#VCFMS_VMS[@]}" -gt 0 ]]; then
    log_warn "  Liste API indisponible — utilisation de VCFMS_VMS de la configuration."
    VCFMS_VM_IDS=("${VCFMS_VMS[@]}")
    return 0
  fi

  if [[ -n "${VCFMS_VM_PATTERN}" ]]; then
    log_warn "  Liste API indisponible — recherche dans vCenter des VMs '${VCFMS_VM_PATTERN}'."
    local path
    while IFS= read -r path; do
      [[ -z "${path}" ]] && continue
      log "  VM trouvée : ${path}"
      VCFMS_VM_IDS+=("${path}")
    done <<< "$(govc find / -type m -name "${VCFMS_VM_PATTERN}" 2> /dev/null || true)"
    [[ "${#VCFMS_VM_IDS[@]}" -gt 0 ]] && return 0
    log_warn "  Aucune VM ne correspond à '${VCFMS_VM_PATTERN}'."
  fi

  die "VMs du VCF services runtime introuvables. Renseigne VCFMS_VMS ou VCFMS_VM_PATTERN dans la conf (noms visibles dans VCF Operations > Build > Lifecycle > VCF Management Components > VCF services runtime > Nodes)."
}

check_esx_hosts() {
  local host host_path out
  [[ "${#ESX_HOSTS[@]}" -gt 0 ]] || die "ESX_HOSTS est vide."
  for host in "${ESX_HOSTS[@]}"; do
    if [[ "${ENABLE_ESX_SSH}" == "true" ]]; then
      host_path=$(govc find / -type h -name "${host}" 2> /dev/null | head -1 || true)
      if [[ -n "${host_path}" ]]; then
        log "  Démarrage du service SSH sur ${host}"
        run govc host.service -host "${host_path}" start TSM-SSH > /dev/null || log_warn "  Échec démarrage SSH sur ${host}."
      else
        log_warn "  Hôte '${host}' introuvable dans vCenter (le nom doit correspondre à l'inventaire)."
      fi
    fi
    if out=$(esx_ssh "${host}" "vmware -v" 2> /dev/null); then
      log "  SSH OK : ${host} — ${out}"
    elif [[ "${DRY_RUN}" == "true" ]]; then
      log_warn "  SSH KO sur ${host} (normal en dry-run si SSH n'est pas encore démarré)."
    else
      die "SSH impossible vers ${host} (clé SSH, ESX_ROOT_PASSWORD ou lockdown mode ?)."
    fi
  done
  if [[ "${DRY_RUN}" == "false" ]]; then
    esx_ssh "${ESX_HOSTS[0]}" "test -f ${REBOOT_HELPER}" ||
      die "${REBOOT_HELPER} absent sur ${ESX_HOSTS[0]} — utilise VSAN_SHUTDOWN_MODE=wizard."
  fi
}

preflight() {
  log_step "Pré-vérifications"

  check_tools

  if [[ -d /opt/vmware/vcf ]]; then
    die "Ce script tourne sur SDDC Manager, qui est arrêté à l'étape 10. Lance-le depuis une machine d'admin externe."
  fi

  [[ -n "${GOVC_URL}" ]] || die "GOVC_URL non défini (URL du vCenter de gestion)."
  prompt_secret GOVC_PASSWORD "Mot de passe vCenter pour ${GOVC_USERNAME}"
  export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE

  log "Connexion au vCenter ${GOVC_URL}..."
  govc about > /dev/null 2>&1 || die "Connexion au vCenter impossible (URL, identifiants, réseau)."
  log "vCenter OK : $(govc about 2> /dev/null | awk -F': *' '/^FullName/ {print $2}')"

  if step_in_range 5 && [[ -n "${VCFMS_NODE_IP}" ]]; then
    [[ -f "${VCFMS_SHUTDOWN_SCRIPT}" ]] || die "Script officiel introuvable : ${VCFMS_SHUTDOWN_SCRIPT} (KB 440874)."
    official_script_info
    if official_supports --kubeconfig && [[ -z "${VCFMS_KUBECONFIG}" ]]; then
      die "Ce script officiel attend --kubeconfig : renseigne VCFMS_KUBECONFIG (cf. KB 440874)."
    fi
    prompt_secret VMSP_PASSWORD "Mot de passe ${VMSP_API_USER} (VCF services runtime)"
    discover_vcfms_vms
  fi

  check_inventory_and_snapshots

  if step_in_range 6 && [[ "${#VCFOPS_VMS[@]}" -gt 0 && "${VCFOPS_OFFLINE_MODE}" == "api" ]]; then
    [[ -n "${VCFOPS_PRIMARY_FQDN}" ]] || die "VCFOPS_PRIMARY_FQDN non défini."
    prompt_secret VCFOPS_ADMIN_PASSWORD "Mot de passe ${VCFOPS_ADMIN_USER} de VCF Operations (/admin)"
    write_vcfops_curl_cfg
    local state
    state=$(vcfops_online_state)
    case "${state}" in
      UNREACHABLE) die "API CaSA de VCF Operations injoignable (FQDN/mot de passe admin ?). Sinon VCFOPS_OFFLINE_MODE=ui." ;;
      UNKNOWN)
        local raw
        raw=$(vcfops_curl "https://${VCFOPS_PRIMARY_FQDN}/casa/sysadmin/cluster/online_state" 2> /dev/null || true)
        log_warn "VCF Operations — état du cluster illisible. Réponse : ${raw:0:400}"
        log_warn "  Le passage offline sera demandé, puis confirmé à la main si l'état reste illisible."
        ;;
      *) log "VCF Operations — état du cluster : ${state}" ;;
    esac
  fi

  if step_in_range 11; then
    [[ -n "${MGMT_CLUSTER}" ]] || die "MGMT_CLUSTER non défini."
    [[ -n "${VCENTER_VM}" ]] || die "VCENTER_VM non défini."
    CLUSTER_PATH=$(govc find / -type c -name "${MGMT_CLUSTER}" 2> /dev/null | head -1 || true)
    [[ -n "${CLUSTER_PATH}" ]] || die "Cluster '${MGMT_CLUSTER}' introuvable."
    log "Cluster de gestion : ${CLUSTER_PATH} (stockage ${MGMT_STORAGE})"
    if [[ "${MGMT_STORAGE}" == "nfs" ]]; then
      nfs_preflight
    elif [[ "${VSAN_SHUTDOWN_MODE}" == "manual" ]]; then
      [[ "${VSAN_SHARED_WITNESS}" == "true" ]] &&
        die "reboot_helper.py ne doit pas être utilisé avec un witness partagé (KB 455801). Utilise VSAN_SHUTDOWN_MODE=wizard."
      check_esx_hosts
      log_warn "reboot_helper.py exige des horloges synchronisées (NTP) entre hôtes (KB 410326)."
    fi
  fi
}

confirm_execution() {
  log_step "Plan d'arrêt (étapes ${FROM_STEP} à ${TO_STEP})"
  {
    echo "  0  Workloads mgmt        : ${#WORKLOAD_VMS[@]} VM(s)"
    echo "  1  VCF Automation        : mode ${VCFA_MODE}"
    echo "  2  VCF Ops for networks  : mode ${VCFNET_MODE}"
    echo "  3  Cloud proxies         : ${#CLOUD_PROXY_VMS[@]} VM(s)"
    echo "  4  License server        : ${#LICENSE_SERVER_VMS[@]} VM(s)"
    echo "  5  VCF services runtime  : ${VCFMS_NODE_IP:-non configuré} (${#VCFMS_VM_IDS[@]} VM(s))"
    echo "  6  VCF Operations        : ${#VCFOPS_VMS[@]} VM(s), offline via ${VCFOPS_OFFLINE_MODE}"
    echo "  7  Protection & recovery : ${#VLSR_VMS[@]} VM(s)"
    echo "  8  NSX Edge / VNA        : ${#NSX_EDGE_VMS[@]} VM(s)"
    echo "  9  NSX Manager           : ${#NSX_MANAGER_VMS[@]} VM(s)"
    echo "  10 SDDC Manager          : ${SDDC_MANAGER_VM:-non configuré}"
    echo "  11 vCenter/vSAN/ESX      : ${VCENTER_VM:-?} + ${#INFRA_VMS[@]} VM(s) d'infra, stockage ${MGMT_STORAGE}$([[ "${MGMT_STORAGE}" == "vsan" ]] && echo ", mode ${VSAN_SHUTDOWN_MODE}")"
  } >&2
  log_warn "Rappels doc : arrêter les workload domains AVANT le domaine de gestion ; en arrêt de fleet complet, l'instance qui héberge VCF Operations en dernier."

  [[ "${DRY_RUN}" == "true" || "${ASSUME_YES}" == "true" ]] && return 0
  [[ -t 0 ]] || die "Pas de terminal : utilise --yes pour confirmer."
  local answer=""
  read -r -p "Tape SHUTDOWN pour lancer l'arrêt : " answer
  [[ "${answer}" == "SHUTDOWN" ]] || die "Annulé."
}

# ---------------------------------------------------------------------------
# Étapes
# ---------------------------------------------------------------------------
step_0_workloads() {
  log_step "Étape 0/11 — Workloads et VMs hors VCF du domaine de gestion"
  shutdown_vms "Workloads" parallel ${WORKLOAD_VMS[@]+"${WORKLOAD_VMS[@]}"}
}

# step_ui_or_vm <n> <libellé> <mode> <instruction UI> <ids...>
step_ui_or_vm() {
  local n="${1}" label="${2}" mode="${3}" howto="${4}"
  shift 4
  log_step "Étape ${n}/11 — ${label}"
  case "${mode}" in
    none)
      log "Non déployé (mode none) — étape ignorée."
      ;;
    ui)
      manual_checkpoint "${howto}"
      verify_vms_off "${label}" ${@+"${@}"}
      ;;
    vm)
      log_warn "Mode 'vm' : arrêt Guest OS direct, hors procédure officielle (raccourci de lab)."
      shutdown_vms "${label}" sequential ${@+"${@}"}
      ;;
  esac
}

step_1_vcf_automation() {
  step_ui_or_vm 1 "VCF Automation" "${VCFA_MODE}" \
    "VCF Operations > Build > Lifecycle > VCF Management Components > Components > VCF Automation > Actions > State management > Power off. Attends la fin de la tâche." \
    ${VCFA_VMS[@]+"${VCFA_VMS[@]}"}
}

step_2_vcf_ops_networks() {
  step_ui_or_vm 2 "VCF Operations for networks" "${VCFNET_MODE}" \
    "VCF Operations > Build > Lifecycle > VCF Management Components > VCF Operations for networks > Actions > State management > Power off. Attends la fin de la tâche." \
    ${VCFNET_VMS[@]+"${VCFNET_VMS[@]}"}
}

step_3_cloud_proxies() {
  log_step "Étape 3/11 — Cloud proxies"
  shutdown_vms "Cloud proxies" parallel ${CLOUD_PROXY_VMS[@]+"${CLOUD_PROXY_VMS[@]}"}
}

step_4_license_server() {
  log_step "Étape 4/11 — License server"
  shutdown_vms "License server" sequential ${LICENSE_SERVER_VMS[@]+"${LICENSE_SERVER_VMS[@]}"}
}

# official_supports <--option> — l'option est-elle une étiquette « case » du
# parseur d'arguments du script officiel (ex. « --skip-poweroff) ») ?
official_supports() {
  grep -Eq -- "^[[:space:]]*([^)#]*\|[[:space:]]*)?${1}[[:space:]]*(\|[^)]*)?\)" "${VCFMS_SHUTDOWN_SCRIPT}"
}

official_script_info() {
  local version sum
  version=$(awk -F'"' '/SCRIPT_VERSION=/ {print $2; exit}' "${VCFMS_SHUTDOWN_SCRIPT}" 2> /dev/null || true)
  sum=$( (shasum -a 256 "${VCFMS_SHUTDOWN_SCRIPT}" 2> /dev/null || sha256sum "${VCFMS_SHUTDOWN_SCRIPT}" 2> /dev/null) | awk '{print substr($1, 1, 12)}')
  log "Script officiel : ${VCFMS_SHUTDOWN_SCRIPT} (version ${version:-?}, sha256 ${sum:-?}…)"
}

step_5_vcf_services_runtime() {
  log_step "Étape 5/11 — VCF management services (VCF services runtime)"
  if [[ -z "${VCFMS_NODE_IP}" ]]; then
    log "VCFMS_NODE_IP non défini — étape ignorée."
    return 0
  fi
  if [[ "${#VCFMS_VM_IDS[@]}" -eq 0 ]]; then
    prompt_secret VMSP_PASSWORD "Mot de passe ${VMSP_API_USER} (VCF services runtime)"
    discover_vcfms_vms
  fi

  # Le script officiel gère l'arrêt applicatif (scale-down workloads et
  # contrôleurs, power-off-marker). On garde la main sur l'arrêt des VMs
  # pour faire un « Shut down Guest OS » comme la doc (lui fait un
  # power-off forcé).
  # Les versions du script de la KB 440874 n'ont pas toutes les mêmes options :
  # on n'envoie que celles qu'il connaît.
  local -a args=(--node-ip "${VCFMS_NODE_IP}")
  if official_supports --skip-poweroff; then
    args+=(--skip-poweroff)
  elif official_supports --poweroff-vms; then
    log "  Version sans --skip-poweroff : les VMs ne sont pas éteintes par défaut (pas de --poweroff-vms)."
  else
    log_warn "  Option d'extinction des VMs non reconnue dans le script officiel : VCENTER_USERNAME/PASSWORD retirés pour qu'il ne les éteigne pas."
  fi
  if official_supports --kubeconfig; then
    [[ -n "${VCFMS_KUBECONFIG}" ]] ||
      die "Cette version du script officiel attend --kubeconfig : renseigne VCFMS_KUBECONFIG (kubeconfig du VCF services runtime, cf. KB 440874)."
    [[ -f "${VCFMS_KUBECONFIG}" ]] || die "Kubeconfig introuvable : ${VCFMS_KUBECONFIG}"
    args+=(--kubeconfig "${VCFMS_KUBECONFIG}")
  elif [[ -n "${VCFMS_KUBECONFIG}" ]]; then
    log_warn "  VCFMS_KUBECONFIG défini mais ce script officiel ne gère pas --kubeconfig : ignoré."
  fi
  [[ "${DRY_RUN}" == "true" ]] && args+=(--dry-run)
  [[ "${SKIP_SNAPSHOT_CHECK}" == "true" ]] && official_supports --skip-snapshot-check && args+=(--skip-snapshot-check)

  log "Appel du script officiel : $(basename "${VCFMS_SHUTDOWN_SCRIPT}") ${args[*]}"
  if ! env -u VCENTER_USERNAME -u VCENTER_PASSWORD \
    NODE_PORT="${VCFMS_NODE_PORT}" VMSP_PASSWORD="${VMSP_PASSWORD}" \
    bash "${VCFMS_SHUTDOWN_SCRIPT}" "${args[@]}"; then
    die "Le script officiel a échoué : NE PAS éteindre les VMs. Voir la sortie ci-dessus / KB 440874."
  fi

  shutdown_vms "VCF services runtime" sequential "${VCFMS_VM_IDS[@]}"
}

vcfops_take_offline_api() {
  local state elapsed=0 unknown=0
  state=$(vcfops_online_state)
  log "État actuel du cluster VCF Operations : ${state}"
  if [[ "${state}" == "OFFLINE" ]]; then
    log "Cluster déjà offline."
    return 0
  fi
  log "Passage du cluster offline (API CaSA, KB 313533) — peut prendre jusqu'à ~1 h."
  run vcfops_curl -X POST "https://${VCFOPS_PRIMARY_FQDN}/casa/sysadmin/cluster/online_state" \
    -d '{"online_state":"OFFLINE","online_state_reason":"Arret du lab VCF"}' > /dev/null ||
    die "Échec de la requête 'Take cluster offline'."
  [[ "${DRY_RUN}" == "true" ]] && return 0

  while true; do
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
    state=$(vcfops_online_state)
    case "${state}" in
      OFFLINE)
        log "Cluster VCF Operations offline (${elapsed}s)."
        return 0
        ;;
      FAILURE)
        die "Échec du passage offline. Utilise 'Force Take Cluster Offline' dans /admin (KB 376399), puis relance avec --from-step 6."
        ;;
      UNKNOWN | UNREACHABLE)
        unknown=$((unknown + 1))
        if [[ "${unknown}" -ge 6 ]]; then
          log_warn "État non lisible via l'API."
          manual_checkpoint "Vérifie dans https://${VCFOPS_PRIMARY_FQDN}/admin que le cluster est bien Offline."
          return 0
        fi
        ;;
      *)
        unknown=0
        log "  État : ${state} (${elapsed}s)"
        ;;
    esac
    [[ "${elapsed}" -lt "${VCFOPS_OFFLINE_TIMEOUT}" ]] ||
      die "Cluster pas offline après ${VCFOPS_OFFLINE_TIMEOUT}s."
  done
}

step_6_vcf_operations() {
  log_step "Étape 6/11 — VCF Operations"
  if [[ "${#VCFOPS_VMS[@]}" -eq 0 ]]; then
    log "VCFOPS_VMS vide — étape ignorée."
    return 0
  fi
  if [[ "${VCFOPS_OFFLINE_MODE}" == "api" ]]; then
    vcfops_take_offline_api
  else
    manual_checkpoint "https://${VCFOPS_PRIMARY_FQDN:-<vcf_operations_fqdn>}/admin (admin) > System Status > Take cluster offline. Attends l'état Offline (jusqu'à ~1 h)."
  fi
  # Ordre KB 341964 : data → replica → primary (respecté via l'ordre de VCFOPS_VMS)
  shutdown_vms "VCF Operations" sequential "${VCFOPS_VMS[@]}"
}

step_7_protection_recovery() {
  log_step "Étape 7/11 — Protection & recovery (VMware Live Site Recovery)"
  [[ "${#VLSR_VMS[@]}" -gt 0 ]] &&
    log_warn "Les VMs protégées de l'instance appairée deviennent non protégées."
  shutdown_vms "Protection & recovery" sequential ${VLSR_VMS[@]+"${VLSR_VMS[@]}"}
}

step_8_nsx_edges() {
  log_step "Étape 8/11 — NSX Edge / VNA du domaine de gestion"
  shutdown_vms "NSX Edge" parallel ${NSX_EDGE_VMS[@]+"${NSX_EDGE_VMS[@]}"}
}

step_9_nsx_managers() {
  log_step "Étape 9/11 — NSX Manager"
  shutdown_vms "NSX Manager" parallel ${NSX_MANAGER_VMS[@]+"${NSX_MANAGER_VMS[@]}"}
}

step_10_sddc_manager() {
  log_step "Étape 10/11 — SDDC Manager"
  shutdown_vms "SDDC Manager" sequential ${SDDC_MANAGER_VM:+"${SDDC_MANAGER_VM}"}
}

# -- Étape 11 ----------------------------------------------------------------

check_remaining_vms() {
  local out line name
  local -a leftover=()
  out=$(govc find / -type m -runtime.powerState poweredOn 2> /dev/null) ||
    die "Impossible de lister les VMs allumées."
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    name="${line##*/}"
    [[ "${name}" == "${VCENTER_VM}" || "${name}" == vCLS* ]] && continue
    in_list "${name}" ${INFRA_VMS[@]+"${INFRA_VMS[@]}"} && continue
    leftover+=("${name}")
  done <<< "${out}"

  if [[ "${#leftover[@]}" -gt 0 ]]; then
    log_error "VM(s) encore allumée(s) hors vCenter / infra :"
    printf '    %s\n' "${leftover[@]}" >&2
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_warn "  (dry-run : normal, les étapes précédentes n'ont rien arrêté)"
    else
      die "Éteins-les ou ajoute-les à INFRA_VMS / WORKLOAD_VMS."
    fi
  else
    log "Seuls le vCenter et les VMs d'infrastructure sont encore allumés."
  fi
}

vsan_health_check() {
  local host="${1}" out members bad resync
  log "Santé vSAN (depuis ${host})..."

  out=$(esx_ssh "${host}" "esxcli vsan cluster get") || die "esxcli vsan cluster get a échoué sur ${host}."
  members=$(printf '%s\n' "${out}" | awk -F': *' '/Sub-Cluster Member Count/ {print $2}' | tr -d ' \r')
  log "  Membres du cluster vSAN : ${members:-?} (hôtes configurés : ${#ESX_HOSTS[@]})"
  if [[ "${members}" =~ ^[0-9]+$ && "${members}" -lt "${#ESX_HOSTS[@]}" ]]; then
    die "Cluster vSAN partitionné ou hôte absent."
  fi

  out=$(esx_ssh "${host}" "esxcli vsan debug object health summary get") ||
    die "Impossible de lire la santé des objets vSAN."
  bad=$(printf '%s\n' "${out}" | awk '$NF ~ /^[0-9]+$/ && $1 != "healthy" && $NF > 0 {printf "%s=%s ", $1, $NF}')
  resync=$(esx_ssh "${host}" "esxcli vsan debug resync summary get" 2> /dev/null |
    awk -F': *' '/Total Number Of Resyncing Objects/ {print $2}' | tr -d ' \r' || true)

  if [[ -n "${bad}" || ("${resync}" =~ ^[0-9]+$ && "${resync}" -gt 0) ]]; then
    log_error "  Objets non sains : ${bad:-aucun} — resync en cours : ${resync:-?}"
    [[ "${DRY_RUN}" == "true" ]] || die "vSAN non sain : corrige avant d'arrêter le cluster."
  else
    log "  Objets vSAN sains, aucune resynchronisation."
  fi
}

save_cluster_state() {
  local json ha drs drs_mode
  json=$(govc object.collect -json "${CLUSTER_PATH}" configurationEx 2> /dev/null || true)
  ha=$(printf '%s' "${json}" | jq -r '
    [.. | objects | (.dasConfig? // .DasConfig?) | select(. != null)][0] // {}
    | if has("enabled") then .enabled elif has("Enabled") then .Enabled else "inconnu" end' 2> /dev/null || echo "inconnu")
  drs=$(printf '%s' "${json}" | jq -r '
    [.. | objects | (.drsConfig? // .DrsConfig?) | select(. != null)][0] // {}
    | if has("enabled") then .enabled elif has("Enabled") then .Enabled else "inconnu" end' 2> /dev/null || echo "inconnu")
  drs_mode=$(printf '%s' "${json}" | jq -r '
    [.. | objects | (.drsConfig? // .DrsConfig?) | select(. != null)][0] // {}
    | .defaultVmBehavior // .DefaultVmBehavior // "inconnu"' 2> /dev/null || echo "inconnu")

  STATE_FILE="${LOG_DIR}/cluster_state_${MGMT_CLUSTER}.env"
  {
    echo "# État du cluster avant arrêt — $(ts)"
    echo "CLUSTER_PATH='${CLUSTER_PATH}'"
    echo "HA_ENABLED='${ha}'"
    echo "DRS_ENABLED='${drs}'"
    echo "DRS_MODE='${drs_mode}'"
  } > "${STATE_FILE}"
  log "État HA=${ha} DRS=${drs} (${drs_mode}) sauvegardé dans ${STATE_FILE}"
}

print_wizard_instructions() {
  log_warn "ACTION MANUELLE — vSAN Shutdown Cluster wizard (méthode de la doc) :"
  {
    echo "  1. vSphere Client > clic droit sur '${MGMT_CLUSTER}' > vSAN > Shutdown cluster."
    echo "  2. Vérifier que tous les prechecks sont verts."
    echo "  3. Si des VMs d'infra (DNS/NTP/AD) tournent sur le cluster, cocher"
    echo "     « I confirm all VMs below are infrastructure VMs »."
    echo "  4. Noter l'IP de l'Orchestration host (suivi une fois le vCenter arrêté)."
    echo "  5. Saisir un motif puis Shutdown."
    echo "  Ne JAMAIS cliquer « Turn Off vSAN » pour arrêter le cluster (KB 326462)."
  } >&2
}

vsan_manual_shutdown() {
  local first="${ESX_HOSTS[0]}" host out state
  local -a others=()
  for host in "${ESX_HOSTS[@]}"; do
    [[ "${host}" == "${first}" ]] || others+=("${host}")
  done

  # a) Santé vSAN (tant que tout tourne)
  vsan_health_check "${first}"

  # b) HA off / DRS manuel — comme le wizard (évite redémarrages et vMotions)
  save_cluster_state
  log "Désactivation de vSphere HA et passage de DRS en manuel..."
  run govc cluster.change -ha-enabled=false "${CLUSTER_PATH}" || log_warn "Échec désactivation HA."
  run govc cluster.change -drs-mode manual "${CLUSTER_PATH}" || log_warn "Échec passage DRS manuel."

  # c) Bloque les mises à jour de membres du cluster poussées par vCenter
  for host in "${ESX_HOSTS[@]}"; do
    log "  ${host} : /VSAN/IgnoreClusterMemberListUpdates = 1"
    run esx_ssh "${host}" "esxcfg-advcfg -s 1 /VSAN/IgnoreClusterMemberListUpdates" > /dev/null
  done

  # d) vCenter (la connexion govc est perdue à partir d'ici)
  log "Arrêt du vCenter de gestion '${VCENTER_VM}' (via ESX)..."
  esx_shutdown_vm "${VCENTER_VM}"

  # e) VMs d'infrastructure, après le vCenter (doc)
  if [[ "${#INFRA_VMS[@]}" -gt 0 ]]; then
    log "Arrêt des VMs d'infrastructure (après vCenter, comme la doc)..."
    local vm
    for vm in "${INFRA_VMS[@]}"; do
      esx_shutdown_vm "${vm}"
    done
  fi

  # f) Préparation du cluster — UNE SEULE FOIS (KB 390160)
  log "Préparation du cluster vSAN sur ${first} : reboot_helper.py prepare"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] esx_ssh ${first} python ${REBOOT_HELPER} prepare"
  else
    out=$(esx_ssh "${first}" "python ${REBOOT_HELPER} prepare" 2>&1) || true
    printf '%s\n' "${out}" | sed 's/^/    /' >&2
    [[ "${out}" == *"Cluster preparation is done"* ]] ||
      die "reboot_helper.py prepare n'a pas abouti. NE PAS le relancer à l'aveugle (KB 390160) : analyser l'erreur (NTP : KB 410326, réseau : KB 385699)."
  fi

  # g) Mode maintenance « No Action » sur tous les hôtes
  for host in "${ESX_HOSTS[@]}"; do
    esx_ensure_no_running_vms "${host}"
    log "  ${host} : mode maintenance (noAction)"
    run esx_ssh "${host}" "esxcli system maintenanceMode set -e true -m noAction" > /dev/null
    if [[ "${DRY_RUN}" == "false" ]]; then
      state=$(esx_ssh "${host}" "esxcli system maintenanceMode get" | tr -d '\r')
      [[ "${state}" == "Enabled" ]] || die "${host} n'est pas en mode maintenance (${state})."
    fi
  done

  # h) Extinction des hôtes : premier hôte en dernier
  for host in ${others[@]+"${others[@]}"} "${first}"; do
    log "  Extinction de ${host}"
    run esx_ssh "${host}" "esxcli system shutdown poweroff -r 'Arret du lab VCF'" > /dev/null || true
  done

  if [[ "${DRY_RUN}" == "false" ]]; then
    local elapsed
    for host in "${ESX_HOSTS[@]}"; do
      elapsed=0
      while esx_ssh "${host}" "true" > /dev/null 2>&1; do
        if [[ "${elapsed}" -ge "${ESX_SHUTDOWN_TIMEOUT}" ]]; then
          log_warn "  ${host} répond encore après ${ESX_SHUTDOWN_TIMEOUT}s — vérifie la console."
          break
        fi
        sleep "${POLL_INTERVAL}"
        elapsed=$((elapsed + POLL_INTERVAL))
      done
      log "  ${host} ne répond plus en SSH."
    done
  fi
}

# -- Étape 11, stockage NFS / Fibre Channel -----------------------------------
# Doc VCF 9.1 « Shut Down ESX Hosts with NFS or Fibre Channel Storage in the
# Management Domain » : hôtes sans vCenter en maintenance puis arrêtés via
# vCenter ; puis, sur l'hôte du vCenter (Host Client), Shut down Guest OS du
# vCenter et arrêt de l'hôte. Les VMs d'infra sont migrées sur cet hôte et
# arrêtées après le vCenter (prérequis de la doc).

VC_HOST_REF=""
VC_HOST_NAME=""
VC_HOST_PATH=""

locate_vcenter_host() {
  local vc_path
  vc_path=$(resolve_vm "${VCENTER_VM}") || die "VM vCenter '${VCENTER_VM}' introuvable."
  VC_HOST_REF=$(govc object.collect -s "${vc_path}" runtime.host 2> /dev/null || true)
  [[ -n "${VC_HOST_REF}" ]] || die "Impossible de déterminer l'hôte du vCenter."
  VC_HOST_NAME=$(govc object.collect -s "${VC_HOST_REF}" name 2> /dev/null || true)
  VC_HOST_PATH=$(govc ls -L "${VC_HOST_REF}" 2> /dev/null || true)
  [[ -n "${VC_HOST_NAME}" && -n "${VC_HOST_PATH}" ]] || die "Hôte du vCenter (${VC_HOST_REF}) introuvable."
}

nfs_preflight() {
  locate_vcenter_host
  log "Le vCenter tourne sur ${VC_HOST_NAME} : cet hôte sera arrêté en dernier."
  prompt_secret ESX_ROOT_PASSWORD "Mot de passe ${ESX_SSH_USER} de l'ESX ${VC_HOST_NAME} (Host Client)"
  if esx_govc "${VC_HOST_NAME}" about > /dev/null 2>&1; then
    log "Connexion directe à ${VC_HOST_NAME} OK (identifiants ESX valides)."
  else
    die "Connexion directe à https://${VC_HOST_NAME} impossible (ESX_SSH_USER / ESX_ROOT_PASSWORD ?)."
  fi
}

nfs_shutdown() {
  local vm path cur_host hpath elapsed state
  locate_vcenter_host

  save_cluster_state
  echo "VCENTER_HOST='${VC_HOST_NAME}'" >> "${STATE_FILE}"
  log "Hôte du vCenter (à noter pour le redémarrage) : ${VC_HOST_NAME}"

  log "Désactivation de vSphere HA et passage de DRS en manuel (placement figé)..."
  run govc cluster.change -ha-enabled=false "${CLUSTER_PATH}" || log_warn "Échec désactivation HA."
  run govc cluster.change -drs-mode manual "${CLUSTER_PATH}" || log_warn "Échec passage DRS manuel."

  # a) VMs d'infra regroupées sur l'hôte du vCenter
  for vm in ${INFRA_VMS[@]+"${INFRA_VMS[@]}"}; do
    path=$(resolve_vm "${vm}") || {
      log_warn "  VM d'infra '${vm}' introuvable — ignorée."
      continue
    }
    cur_host=$(govc object.collect -s "${path}" runtime.host 2> /dev/null || true)
    if [[ "${cur_host}" != "${VC_HOST_REF}" ]]; then
      log "  Migration de '${vm}' vers ${VC_HOST_NAME}"
      run govc vm.migrate -host "${VC_HOST_PATH}" "${path}" > /dev/null ||
        die "Migration de '${vm}' vers ${VC_HOST_NAME} impossible."
    fi
  done

  # b) Autres hôtes du cluster : maintenance puis arrêt via vCenter
  local -a other_hosts=()
  while IFS= read -r hpath; do
    [[ -z "${hpath}" || "${hpath}" == "${VC_HOST_PATH}" ]] && continue
    other_hosts+=("${hpath}")
  done <<< "$(govc find "${CLUSTER_PATH}" -type h 2> /dev/null || true)"

  for hpath in ${other_hosts[@]+"${other_hosts[@]}"}; do
    log "  ${hpath##*/} : mode maintenance"
    run govc host.maintenance.enter "${hpath}" > /dev/null ||
      die "${hpath##*/} n'a pas pu entrer en maintenance (VM encore allumée dessus ?)."
  done
  for hpath in ${other_hosts[@]+"${other_hosts[@]}"}; do
    log "  ${hpath##*/} : arrêt"
    run govc host.shutdown "${hpath}" > /dev/null || die "Arrêt de ${hpath##*/} impossible."
  done
  if [[ "${DRY_RUN}" == "false" ]]; then
    for hpath in ${other_hosts[@]+"${other_hosts[@]}"}; do
      elapsed=0
      while state=$(host_state "${hpath}") && [[ "${state}" == "connected" ]]; do
        if [[ "${elapsed}" -ge "${ESX_SHUTDOWN_TIMEOUT}" ]]; then
          log_warn "  ${hpath##*/} toujours connecté après ${ESX_SHUTDOWN_TIMEOUT}s — vérifie la console."
          break
        fi
        sleep "${POLL_INTERVAL}"
        elapsed=$((elapsed + POLL_INTERVAL))
      done
      log "  ${hpath##*/} : ${state}"
    done
  fi

  # c) Hôte du vCenter, directement (Host Client) : vCenter, VMs d'infra, puis l'hôte
  log "Connexion directe à ${VC_HOST_NAME} (le vCenter va être arrêté)..."
  local vm_esx
  for vm in "${VCENTER_VM}" ${INFRA_VMS[@]+"${INFRA_VMS[@]}"}; do
    vm_esx=$(esx_govc "${VC_HOST_NAME}" find / -type m -name "${vm}" 2> /dev/null | head -1 || true)
    if [[ -z "${vm_esx}" ]]; then
      log_warn "  '${vm}' introuvable sur ${VC_HOST_NAME} — ignorée."
      continue
    fi
    if [[ "$(esx_govc "${VC_HOST_NAME}" object.collect -s "${vm_esx}" runtime.powerState 2> /dev/null)" == "poweredOff" ]]; then
      log "  '${vm}' déjà éteinte."
      continue
    fi
    log "  Shut down Guest OS : ${vm} (sur ${VC_HOST_NAME})"
    if ! run esx_govc "${VC_HOST_NAME}" vm.power -s "${vm_esx}" > /dev/null; then
      [[ "${FORCE_POWEROFF}" == "true" ]] || die "Arrêt Guest OS de '${vm}' refusé (VMware Tools ?). Relance avec --force-poweroff."
      run esx_govc "${VC_HOST_NAME}" vm.power -off -force "${vm_esx}" > /dev/null
    fi
    [[ "${DRY_RUN}" == "true" ]] && continue
    elapsed=0
    until [[ "$(esx_govc "${VC_HOST_NAME}" object.collect -s "${vm_esx}" runtime.powerState 2> /dev/null)" == "poweredOff" ]]; do
      if [[ "${elapsed}" -ge "${VM_SHUTDOWN_TIMEOUT}" ]]; then
        [[ "${FORCE_POWEROFF}" == "true" ]] || die "'${vm}' toujours allumée après ${VM_SHUTDOWN_TIMEOUT}s."
        log_warn "  Délai dépassé — hard power-off de '${vm}'."
        run esx_govc "${VC_HOST_NAME}" vm.power -off -force "${vm_esx}" > /dev/null
        break
      fi
      sleep "${POLL_INTERVAL}"
      elapsed=$((elapsed + POLL_INTERVAL))
    done
    log "  '${vm}' éteinte (${elapsed}s)."
  done

  local running
  running=$(esx_govc "${VC_HOST_NAME}" find / -type m -runtime.powerState poweredOn 2> /dev/null |
    sed 's|.*/||' | grep -v '^vCLS' || true)
  if [[ -n "${running}" ]]; then
    [[ "${DRY_RUN}" == "true" ]] || die "VM(s) encore allumée(s) sur ${VC_HOST_NAME} : $(echo "${running}" | tr '\n' ' ')"
    log_warn "VM(s) encore allumée(s) sur ${VC_HOST_NAME} : $(echo "${running}" | tr '\n' ' ') (dry-run : normal)"
  fi

  log "Arrêt de ${VC_HOST_NAME}"
  run esx_govc "${VC_HOST_NAME}" host.shutdown -f > /dev/null || log_warn "Commande d'arrêt de ${VC_HOST_NAME} en erreur — vérifie la console."

  log_warn "Stockage NFS/FC : ne l'arrêter que si aucun autre client ne l'utilise (doc du constructeur)."
}

print_restart_notes_nfs() {
  local first_host="${VC_HOST_NAME}"
  [[ -n "${first_host}" ]] || first_host="l'hôte du vCenter (voir ${STATE_FILE:-logs})"
  log_step "Au redémarrage"
  {
    echo "  1. Démarrer le stockage NFS/FC et l'infra physique."
    echo "  2. Démarrer d'abord ${first_host}, puis le vCenter et les VMs d'infra depuis le Host Client."
    echo "  3. Démarrer les autres hôtes et les sortir du mode maintenance."
    echo "  4. Réactiver HA/DRS comme avant (état d'origine : ${STATE_FILE:-voir logs})."
    echo "  5. Suivre la procédure de démarrage VCF 9.1 (ordre inverse)."
  } >&2
}

print_restart_notes() {
  log_step "Au redémarrage"
  {
    echo "  1. Démarrer l'infra physique et les VMs d'infra externes, puis les hôtes ESX."
    echo "  2. Sur chaque hôte : esxcli system maintenanceMode set -e false"
    echo "  3. Sur UN SEUL hôte : python ${REBOOT_HELPER} recover"
    echo "     (attendre « Cluster reboot/power-on is completed successfully! »)"
    echo "  4. Sur chaque hôte : esxcfg-advcfg -s 0 /VSAN/IgnoreClusterMemberListUpdates"
    echo "  5. Démarrer le vCenter, puis réactiver HA/DRS (état d'origine : ${STATE_FILE:-voir logs})."
    echo "  6. Suivre la procédure de démarrage VCF 9.1 (ordre inverse)."
  } >&2
}

step_11_vsan_esx() {
  log_step "Étape 11/11 — vCenter, VMs d'infrastructure, stockage et hôtes ESX"
  check_remaining_vms
  if [[ "${MGMT_STORAGE}" == "nfs" ]]; then
    nfs_shutdown
    print_restart_notes_nfs
    return 0
  fi
  if [[ "${VSAN_SHUTDOWN_MODE}" == "wizard" ]]; then
    print_wizard_instructions
    return 0
  fi
  vsan_manual_shutdown
  print_restart_notes
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args ${@+"${@}"}
  load_config
  setup_logging

  log "VCF Lab Shutdown v${SCRIPT_VERSION} — mode $([[ "${DRY_RUN}" == "true" ]] && echo DRY-RUN || echo LIVE)"
  log "Configuration : ${CONFIG_FILE}"
  log "Journal       : ${LOG_FILE}"

  preflight
  confirm_execution

  local step
  for step in $(seq "${FROM_STEP}" "${TO_STEP}"); do
    case "${step}" in
      0) step_0_workloads ;;
      1) step_1_vcf_automation ;;
      2) step_2_vcf_ops_networks ;;
      3) step_3_cloud_proxies ;;
      4) step_4_license_server ;;
      5) step_5_vcf_services_runtime ;;
      6) step_6_vcf_operations ;;
      7) step_7_protection_recovery ;;
      8) step_8_nsx_edges ;;
      9) step_9_nsx_managers ;;
      10) step_10_sddc_manager ;;
      11) step_11_vsan_esx ;;
    esac
  done

  log ""
  log "Étapes ${FROM_STEP} à ${TO_STEP} terminées."
}

main ${@+"${@}"}

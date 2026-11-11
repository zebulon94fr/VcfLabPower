#!/usr/bin/env bash
#
# vcf_lab_cycle.sh — Cycle complet arrêt → démarrage du domaine de gestion
#
# Enchaîne vcf_lab_shutdown.sh puis vcf_lab_startup.sh avec le même fichier
# de configuration :
#   1. demande les secrets une seule fois et les transmet aux deux scripts ;
#   2. lance l'arrêt (--yes) ; s'il échoue, le démarrage n'est PAS lancé ;
#   3. attend que tous les ESX ne répondent plus (arrêt réellement terminé),
#      puis CYCLE_DELAY secondes ;
#   4. lance le démarrage (--yes).
#
# Pour un cycle sans intervention, la configuration doit éviter les pauses
# manuelles : ESX_POWERON_CMD (allumage des hôtes), NSX_MANAGER_FQDN (état
# STABLE), VCFOPS_OFFLINE_MODE=api, VCFA_MODE / VCFNET_MODE différents de ui.
# Le script signale celles qui restent avant de commencer.
#
# Usage :
#   vcf_lab_cycle.sh [OPTIONS]
#
# Options :
#   --config FICHIER        Fichier de configuration (même défaut que les
#                           deux autres scripts).
#   --dry-run               Dry-run de l'arrêt puis du démarrage.
#   --delay N               Pause en secondes entre arrêt et démarrage
#                           (défaut : CYCLE_DELAY de la conf, sinon 120).
#   --yes                   Pas de confirmation initiale.
#   --help                  Affiche cette aide.
#

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_PREFIX="vcf_lab_cycle"

# shellcheck source=vcf_lab_common.sh
source "${SCRIPT_DIR}/vcf_lab_common.sh"

DRY_RUN="false"
ASSUME_YES="false"
DELAY_OVERRIDE=""
CONFIG_FILE="$(default_config_file)"
FROM_STEP=0
TO_STEP=99

TMP_DIR="$(mktemp -d)"
VCFOPS_CURL_CFG="${TMP_DIR}/vcfops.curlrc"

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
      --delay)
        DELAY_OVERRIDE="${2:?'--delay requiert un nombre de secondes'}"
        [[ "${DELAY_OVERRIDE}" =~ ^[0-9]+$ ]] || die "--delay doit être un entier."
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
}

# Pauses manuelles qui empêcheront un cycle sans intervention
list_manual_pauses() {
  [[ -z "${ESX_POWERON_CMD}" ]] && echo "allumage des hôtes (ESX_POWERON_CMD vide)"
  [[ "${#NSX_MANAGER_VMS[@]}" -gt 0 && -z "${NSX_MANAGER_FQDN}" ]] && echo "état STABLE de NSX (NSX_MANAGER_FQDN vide)"
  [[ "${#VCFOPS_VMS[@]}" -gt 0 && "${VCFOPS_OFFLINE_MODE}" == "ui" ]] && echo "VCF Operations offline/online (VCFOPS_OFFLINE_MODE=ui)"
  [[ "${VCFA_MODE}" == "ui" ]] && echo "VCF Automation (VCFA_MODE=ui, à l'arrêt et au démarrage)"
  [[ "${VCFNET_MODE}" == "ui" ]] && echo "VCF Operations for networks (VCFNET_MODE=ui, à l'arrêt et au démarrage)"
  [[ "${MGMT_STORAGE}" == "vsan" && "${VSAN_SHUTDOWN_MODE}" == "wizard" ]] && echo "vSAN Shutdown/Restart cluster wizard (VSAN_SHUTDOWN_MODE=wizard)"
  return 0
}

collect_secrets() {
  log_step "Secrets (demandés une seule fois, transmis aux deux scripts)"
  prompt_secret GOVC_PASSWORD "Mot de passe vCenter pour ${GOVC_USERNAME}"
  prompt_secret ESX_ROOT_PASSWORD "Mot de passe ${ESX_SSH_USER} des ESX"
  if [[ -n "${VCFMS_NODE_IP}" ]]; then
    prompt_secret VMSP_PASSWORD "Mot de passe ${VMSP_API_USER} (VCF services runtime)"
  fi
  if [[ "${#VCFOPS_VMS[@]}" -gt 0 && "${VCFOPS_OFFLINE_MODE}" == "api" ]]; then
    prompt_secret VCFOPS_ADMIN_PASSWORD "Mot de passe ${VCFOPS_ADMIN_USER} de VCF Operations (/admin)"
  fi
  if [[ -n "${NSX_MANAGER_FQDN}" ]]; then
    prompt_secret NSX_ADMIN_PASSWORD "Mot de passe ${NSX_ADMIN_USER} de NSX Manager"
  fi
  export GOVC_PASSWORD ESX_ROOT_PASSWORD VMSP_PASSWORD VCFOPS_ADMIN_PASSWORD NSX_ADMIN_PASSWORD
}

esx_down() { ! esx_govc "${1}" about > /dev/null 2>&1; }

wait_all_hosts_down() {
  local host elapsed
  log "Attente de l'arrêt effectif des hôtes (jusqu'à ${ESX_SHUTDOWN_TIMEOUT}s chacun)..."
  for host in "${ESX_HOSTS[@]}"; do
    elapsed=0
    while ! esx_down "${host}"; do
      if [[ "${elapsed}" -ge "${ESX_SHUTDOWN_TIMEOUT}" ]]; then
        die "${host} répond encore après ${ESX_SHUTDOWN_TIMEOUT}s : démarrage annulé. Vérifie la console, puis lance vcf_lab_startup.sh à la main."
      fi
      sleep "${POLL_INTERVAL}"
      elapsed=$((elapsed + POLL_INTERVAL))
    done
    log "  ${host} : éteint (${elapsed}s)."
  done
}

main() {
  parse_args ${@+"${@}"}
  load_config
  setup_logging

  local delay="${DELAY_OVERRIDE:-${CYCLE_DELAY:-120}}"
  local -a common=(--config "${CONFIG_FILE}" --yes)
  [[ "${DRY_RUN}" == "true" ]] && common+=(--dry-run)

  log "VCF Lab Cycle v${SCRIPT_VERSION} — mode $([[ "${DRY_RUN}" == "true" ]] && echo DRY-RUN || echo LIVE)"
  log "Configuration : ${CONFIG_FILE}"
  log "Journal       : ${LOG_FILE}"

  [[ -x "${SCRIPT_DIR}/vcf_lab_shutdown.sh" && -x "${SCRIPT_DIR}/vcf_lab_startup.sh" ]] ||
    die "vcf_lab_shutdown.sh et vcf_lab_startup.sh doivent être exécutables à côté de ${SCRIPT_NAME}."
  [[ "${#ESX_HOSTS[@]}" -gt 0 ]] || die "ESX_HOSTS est vide : nécessaire pour vérifier l'arrêt puis le démarrage des hôtes."

  local pauses
  pauses=$(list_manual_pauses)
  if [[ -n "${pauses}" ]]; then
    log_warn "Le cycle s'arrêtera pour des actions manuelles :"
    printf '%s\n' "${pauses}" | sed 's/^/    - /' >&2
    [[ -t 0 || "${DRY_RUN}" == "true" ]] || die "Pas de terminal pour ces actions : complète la configuration ou lance le cycle depuis un terminal."
  else
    log "Configuration sans pause manuelle : cycle entièrement automatique."
  fi

  log_step "Plan du cycle"
  {
    echo "  1. Arrêt complet       : vcf_lab_shutdown.sh ${common[*]}"
    echo "  2. Attente             : tous les ESX éteints, puis ${delay}s"
    echo "  3. Démarrage complet   : vcf_lab_startup.sh ${common[*]}"
  } >&2

  if [[ "${DRY_RUN}" == "false" && "${ASSUME_YES}" == "false" ]]; then
    [[ -t 0 ]] || die "Pas de terminal : utilise --yes pour confirmer."
    local answer=""
    read -r -p "Tape CYCLE pour arrêter puis redémarrer tout le domaine de gestion : " answer
    [[ "${answer}" == "CYCLE" ]] || die "Annulé."
  fi

  collect_secrets

  log_step "Cycle 1/2 — Arrêt"
  if ! "${SCRIPT_DIR}/vcf_lab_shutdown.sh" "${common[@]}"; then
    die "L'arrêt a échoué : démarrage NON lancé. Corrige, puis reprends l'arrêt (--from-step) ou lance vcf_lab_startup.sh."
  fi

  log_step "Pause entre arrêt et démarrage"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] Attente de l'arrêt des hôtes ${ESX_HOSTS[*]}, puis ${delay}s"
  else
    wait_all_hosts_down
    log "Pause de ${delay}s avant le démarrage..."
    sleep "${delay}"
  fi

  log_step "Cycle 2/2 — Démarrage"
  if ! "${SCRIPT_DIR}/vcf_lab_startup.sh" "${common[@]}"; then
    die "Le démarrage a échoué : corrige, puis reprends avec vcf_lab_startup.sh --from-step <étape>."
  fi

  log ""
  log "Cycle arrêt → démarrage terminé."
}

main ${@+"${@}"}

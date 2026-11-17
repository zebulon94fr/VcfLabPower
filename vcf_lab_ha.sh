#!/usr/bin/env bash
#
# vcf_lab_ha.sh — Lancement non interactif de l'arrêt / du démarrage du lab,
# pour Home Assistant (ou tout autre appel distant par SSH).
#
# Les boutons Home Assistant appellent ce script par SSH sur la machine
# d'admin. Il vérifie que l'action peut tourner sans terminal, lance
# vcf_lab_shutdown.sh ou vcf_lab_startup.sh --yes en arrière-plan et rend
# la main tout de suite (shell_command de HA coupe au bout de 60 s). Chaque
# étape ([STEP] du journal) puis la fin de l'exécution sont signalées au
# webhook Home Assistant (HA_WEBHOOK_URL), événements « progress » puis
# « succeeded » / « failed » ; les alertes ([ALERT] du journal : action
# manuelle à faire, procédure incluse) partent aussitôt en « alert ».
#
# Usage :
#   vcf_lab_ha.sh shutdown [--dry-run]   Arrêt complet (étapes 0 à 11, ESX compris)
#   vcf_lab_ha.sh startup  [--dry-run]   Démarrage complet
#   vcf_lab_ha.sh status                 État de la dernière exécution
#   vcf_lab_ha.sh --ssh                  Commande forcée SSH : lit l'action
#                                        dans SSH_ORIGINAL_COMMAND
#   vcf_lab_ha.sh --help
#
# Chaque appel écrit une seule ligne JSON sur stdout, toujours avec le code
# retour 0 quand la demande a été traitée :
#   {"result":"started"|"refused"|"status", "action":..., "message":..., ...}
#
# Fichier de secrets (obligatoire, droits 600) : vcf_lab_ha.local.conf à côté
# du script, ou VCF_LAB_HA_SECRETS. Fichier bash « sourcé », par exemple :
#   GOVC_PASSWORD='...'
#   ESX_ROOT_PASSWORD='...'
#   VMSP_PASSWORD='...'
#   VCFOPS_ADMIN_PASSWORD='...'
#   NSX_ADMIN_PASSWORD='...'
#   HA_WEBHOOK_URL='http://homeassistant.local:8123/api/webhook/<id>'
#
# Configuration : la même que les autres scripts (vcf_lab_shutdown.local.conf).
# Elle doit éviter toutes les pauses manuelles (voir README, « Cycle complet »).
#

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR
readonly SCRIPT_VERSION="1.2.0"

# shellcheck source=vcf_lab_common.sh
source "${SCRIPT_DIR}/vcf_lab_common.sh"

DRY_RUN="false"
CONFIG_FILE="$(default_config_file)"
SECRETS_FILE="${VCF_LAB_HA_SECRETS:-${SCRIPT_DIR}/vcf_lab_ha.local.conf}"
HA_WEBHOOK_URL=""
HA_WEBHOOK_INSECURE="false"   # true : certificat HTTPS de HA non vérifié
LOG_TAIL_LINES=15
PROGRESS_POLL=3       # secondes entre deux lectures du journal (étapes relayées à HA)

# Session SSH non interactive : le PATH du profil n'est pas chargé (govc,
# jq installés par Homebrew ou go install seraient introuvables)
PATH="${PATH}:/usr/local/bin:/opt/homebrew/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/bin"
export PATH

STATE_DIR="${SCRIPT_DIR}/logs"
LOCK_DIR="${STATE_DIR}/ha_run.lock"
STATUS_FILE="${STATE_DIR}/ha_status.json"

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

# reply <result> <action> <message> [clé valeur]... — une ligne JSON sur stdout
reply() {
  local result="${1}" action="${2}" message="${3}"
  shift 3
  if ! command -v jq > /dev/null 2>&1; then
    message="${message//\\/\\\\}"
    printf '{"result":"%s","action":"%s","message":"%s"}\n' "${result}" "${action}" "${message//\"/\\\"}"
    return 0
  fi
  local -a args=(--arg result "${result}" --arg action "${action}" --arg message "${message}"
    --arg version "${SCRIPT_VERSION}")
  # shellcheck disable=SC2016  # variables jq, pas shell
  local filter='{result: $result, action: $action, message: $message, version: $version}'
  while [[ "${#}" -ge 2 ]]; do
    args+=(--arg "${1}" "${2}")
    filter="${filter} + {${1}: \$${1}}"
    shift 2
  done
  jq -cn "${args[@]}" "${filter}"
}

refuse() {
  reply refused "${1}" "${2}"
  exit 0
}

# ---------------------------------------------------------------------------
# Verrou : une seule exécution à la fois (mkdir est atomique)
# ---------------------------------------------------------------------------
lock_pid() { cat "${LOCK_DIR}/pid" 2> /dev/null || true; }

lock_alive() {
  local pid
  pid=$(lock_pid)
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2> /dev/null
}

acquire_lock() {
  mkdir -p "${STATE_DIR}"
  if mkdir "${LOCK_DIR}" 2> /dev/null; then
    echo "$$" > "${LOCK_DIR}/pid"
    return 0
  fi
  # Verrou laissé par une exécution morte (machine redémarrée, kill -9...)
  if ! lock_alive; then
    rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" 2> /dev/null || return 1
    echo "$$" > "${LOCK_DIR}/pid"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Statut et webhook
# ---------------------------------------------------------------------------
# write_status <état> <action> <message> [rc] [début] [fin] [journal]
write_status() {
  local tmp="${STATUS_FILE}.tmp"
  jq -n --arg state "${1}" --arg action "${2}" --arg message "${3}" \
    --arg rc "${4:-}" --arg started_at "${5:-}" --arg finished_at "${6:-}" \
    --arg log_file "${7:-}" --arg dry_run "${DRY_RUN}" --arg pid "$$" \
    '{state: $state, action: $action, message: $message, rc: $rc,
      started_at: $started_at, finished_at: $finished_at, log_file: $log_file,
      dry_run: ($dry_run == "true"), pid: $pid}' > "${tmp}"
  mv -f "${tmp}" "${STATUS_FILE}"
}

# notify_ha <événement> <action> <message> [rc] [fin de journal]
notify_ha() {
  [[ -n "${HA_WEBHOOK_URL}" ]] || return 0
  local -a opts=(-s -o /dev/null --max-time 15 -X POST -H "Content-Type: application/json")
  [[ "${HA_WEBHOOK_INSECURE}" == "true" ]] && opts+=(-k)
  jq -cn --arg event "${1}" --arg action "${2}" --arg message "${3}" --arg rc "${4:-}" \
    --arg log_tail "${5:-}" --arg dry_run "${DRY_RUN}" --arg host "$(hostname)" \
    '{event: $event, action: $action, message: $message, rc: $rc, log_tail: $log_tail,
      dry_run: ($dry_run == "true"), host: $host}' |
    curl "${opts[@]}" --data-binary @- "${HA_WEBHOOK_URL}" || true
}

show_status() {
  if [[ ! -f "${STATUS_FILE}" ]]; then
    reply status "none" "Aucune exécution enregistrée." state idle
    return 0
  fi
  local state
  state=$(jq -r '.state' "${STATUS_FILE}" 2> /dev/null || echo "?")
  # « running » alors que plus personne ne tourne : exécution interrompue
  if [[ "${state}" == "running" ]] && ! lock_alive; then
    jq -c '{result: "status"} + . + {state: "interrupted",
      message: "Exécution interrompue (processus disparu) : voir le journal."}' "${STATUS_FILE}"
    return 0
  fi
  jq -c '{result: "status"} + .' "${STATUS_FILE}"
}

# ---------------------------------------------------------------------------
# Pré-vérifications (rapides : HA attend la réponse)
# ---------------------------------------------------------------------------
load_secrets() {
  [[ -f "${SECRETS_FILE}" ]] || return 1
  local perms
  # ls plutôt que stat : syntaxe identique sur macOS et Linux
  # shellcheck disable=SC2012
  perms=$(ls -l "${SECRETS_FILE}" | cut -c5-10)
  [[ "${perms}" == "------" ]] || return 2
  # Guillemet non fermé : source lirait des mots de passe tronqués sans échouer
  bash -n "${SECRETS_FILE}" 2> /dev/null || return 4
  # shellcheck source=/dev/null
  source "${SECRETS_FILE}" || return 3
  export GOVC_PASSWORD ESX_ROOT_PASSWORD VMSP_PASSWORD VCFOPS_ADMIN_PASSWORD NSX_ADMIN_PASSWORD
}

# Joignabilité réseau seulement (pas d'authentification) : borné à 5 s par hôte
esx_answers() { curl -sk --max-time 5 -o /dev/null "https://${1}/" 2> /dev/null; }

preflight() {
  local action="${1}" tool line var missing="" pauses="" host

  for tool in curl jq govc; do
    command -v "${tool}" > /dev/null 2>&1 || refuse "${action}" "Outil manquant sur la machine d'admin : ${tool}."
  done

  # load_config appelle die en cas d'erreur : on la teste dans un sous-shell
  # pour renvoyer une réponse JSON plutôt qu'un message sur stderr.
  if ! (load_config) > /dev/null 2>&1; then
    refuse "${action}" "Configuration invalide ou introuvable : ${CONFIG_FILE}."
  fi
  load_config

  local rc=0
  load_secrets || rc=$?
  case "${rc}" in
    0) ;;
    1) refuse "${action}" "Fichier de secrets introuvable : ${SECRETS_FILE}." ;;
    2) refuse "${action}" "Droits trop ouverts sur ${SECRETS_FILE} : chmod 600." ;;
    4) refuse "${action}" "Erreur de syntaxe dans ${SECRETS_FILE##*/} (guillemet non fermé ? une apostrophe s'écrit '\\'' entre guillemets simples). Vérifie avec : bash -n ${SECRETS_FILE##*/}" ;;
    *) refuse "${action}" "Erreur au chargement de ${SECRETS_FILE}." ;;
  esac

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    var="${line%%|*}"
    [[ -n "${!var:-}" ]] || missing="${missing:+${missing}, }${var}"
  done <<< "$(list_required_secrets "${action}")"
  [[ -z "${missing}" ]] || refuse "${action}" "Secrets absents de ${SECRETS_FILE##*/} : ${missing}."

  [[ "${#ESX_HOSTS[@]}" -gt 0 ]] || refuse "${action}" "ESX_HOSTS est vide dans ${CONFIG_FILE##*/}."

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    # Sans ESX_POWERON_CMD, le démarrage ne s'arrête pas si les hôtes sont déjà allumés
    if [[ "${line}" == allumage* ]]; then
      for host in "${ESX_HOSTS[@]}"; do
        esx_answers "${host}" || {
          pauses="${pauses:+${pauses} ; }${line} et ${host} ne répond pas"
          break
        }
      done
      continue
    fi
    pauses="${pauses:+${pauses} ; }${line}"
  done <<< "$(list_manual_pauses "${action}")"
  [[ -z "${pauses}" ]] || refuse "${action}" "Pause manuelle requise, impossible sans terminal : ${pauses}."

  if [[ "${action}" == "shutdown" ]]; then
    curl -sk --max-time 10 -o /dev/null "${GOVC_URL}" 2> /dev/null ||
      refuse "${action}" "vCenter injoignable (${GOVC_URL}) : rien à arrêter, ou réseau coupé."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Exécution en arrière-plan
# ---------------------------------------------------------------------------
script_for() {
  case "${1}" in
    shutdown) echo "${SCRIPT_DIR}/vcf_lab_shutdown.sh" ;;
    startup) echo "${SCRIPT_DIR}/vcf_lab_startup.sh" ;;
  esac
}

label_for() {
  case "${1}" in
    shutdown) echo "Arrêt du lab" ;;
    startup) echo "Démarrage du lab" ;;
  esac
}

# log_tagged <journal> <STEP|ALERT|ERROR> — lignes « [TAG] » du journal, sans
# l'horodatage (une par ligne)
log_tagged() {
  { grep -F "[${2}]" "${1}" 2> /dev/null || true; } | sed -e "s/^.*\\[${2}\\][[:space:]]*//"
}

log_steps() { log_tagged "${1}" STEP; }

# Processus détaché : exécute le script, relaie chaque étape à HA, puis
# prévient HA de la fin
run_detached() {
  local action="${1}" script started log_file rc=0 tail_txt label child
  local sent=0 total last_step="" line alerts_sent=0 alerts_total last_error
  script=$(script_for "${action}")
  label=$(label_for "${action}")
  started=$(now_iso)
  log_file="${STATE_DIR}/ha_${action}_$(date +'%Y%m%d_%H%M%S').log"

  echo "$$" > "${LOCK_DIR}/pid"
  trap 'rm -rf "${LOCK_DIR}"' EXIT

  write_status running "${action}" "${label} en cours." "" "${started}" "" "${log_file}"
  notify_ha started "${action}" "${label} lancé depuis $(hostname)."

  local -a args=(--config "${CONFIG_FILE}" --yes)
  [[ "${DRY_RUN}" == "true" ]] && args+=(--dry-run)
  "${script}" "${args[@]}" < /dev/null > "${log_file}" 2>&1 &
  child=$!
  # Un TERM (arrêt de la machine d'admin...) arrête le script et compte comme un échec
  trap 'kill -TERM "${child}" 2> /dev/null; exit 143' TERM
  trap 'kill -INT "${child}" 2> /dev/null; exit 130' INT

  # relay_steps : envoie à HA les étapes apparues depuis le dernier passage
  relay_steps() {
    total=$(log_steps "${log_file}" | grep -c . || true)
    [[ "${total}" -gt "${sent}" ]] || return 0
    while IFS= read -r line; do
      last_step="${line}"
      notify_ha progress "${action}" "${line}"
    done < <(log_steps "${log_file}" | sed -n "$((sent + 1)),${total}p")
    sent="${total}"
    write_status running "${action}" "${label} : ${last_step}" "" "${started}" "" "${log_file}"
  }

  # relay_alerts : envoie à HA les alertes ([ALERT]) apparues depuis le dernier passage
  relay_alerts() {
    alerts_total=$(log_tagged "${log_file}" ALERT | grep -c . || true)
    [[ "${alerts_total}" -gt "${alerts_sent}" ]] || return 0
    while IFS= read -r line; do
      notify_ha alert "${action}" "${line}"
    done < <(log_tagged "${log_file}" ALERT | sed -n "$((alerts_sent + 1)),${alerts_total}p")
    alerts_sent="${alerts_total}"
  }

  while kill -0 "${child}" 2> /dev/null; do
    relay_steps
    relay_alerts
    sleep "${PROGRESS_POLL}"
  done
  wait "${child}" || rc=$?
  relay_steps
  relay_alerts

  tail_txt=$(tail -n "${LOG_TAIL_LINES}" "${log_file}" 2> /dev/null || true)
  if [[ "${rc}" -eq 0 ]]; then
    write_status succeeded "${action}" "${label} terminé." 0 "${started}" "$(now_iso)" "${log_file}"
    notify_ha succeeded "${action}" "${label} terminé." 0 "${tail_txt}"
  else
    local where="${last_step:+ à « ${last_step} »}" why=""
    last_error=$(log_tagged "${log_file}" ERROR | tail -n 1)
    [[ -n "${last_error}" ]] && why=" : ${last_error}"
    write_status failed "${action}" "${label} en échec${where}${why} (code ${rc})." "${rc}" "${started}" "$(now_iso)" "${log_file}"
    notify_ha failed "${action}" "${label} en échec${where}${why} (code ${rc}). Journal : ${log_file}" "${rc}" "${tail_txt}"
  fi
}

start_action() {
  local action="${1}" script
  script=$(script_for "${action}")
  [[ -x "${script}" ]] || refuse "${action}" "Script introuvable ou non exécutable : ${script}."

  if ! acquire_lock; then
    local running
    running=$(jq -r '.action // "?"' "${STATUS_FILE}" 2> /dev/null || echo "?")
    refuse "${action}" "Une exécution est déjà en cours (${running}, pid $(lock_pid))."
  fi
  # En cas de refus à partir d'ici, le verrou est rendu
  trap 'rm -rf "${LOCK_DIR}"' EXIT
  preflight "${action}"

  local -a child=("${SCRIPT_DIR}/${SCRIPT_NAME}" __run "${action}")
  [[ "${DRY_RUN}" == "true" ]] && child+=(--dry-run)
  # Détaché de la session SSH : nohup (SIGHUP), setsid si disponible (Linux)
  if command -v setsid > /dev/null 2>&1; then
    VCF_LAB_HA_CHILD=1 nohup setsid "${child[@]}" < /dev/null > /dev/null 2>&1 &
  else
    VCF_LAB_HA_CHILD=1 nohup "${child[@]}" < /dev/null > /dev/null 2>&1 &
  fi
  # Le processus détaché écrit son pid dans le verrou : on l'attend (3 s max)
  local _ pid
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    pid=$(lock_pid)
    [[ -n "${pid}" && "${pid}" != "$$" ]] && break
    sleep 0.2
  done
  pid=$(lock_pid)
  if [[ "${pid}" == "$$" ]] || ! kill -0 "${pid}" 2> /dev/null; then
    refuse "${action}" "Le processus d'arrière-plan n'a pas démarré (voir ${STATE_DIR})."
  fi
  # Le verrou appartient maintenant au processus détaché
  trap - EXIT

  reply started "${action}" "$(label_for "${action}") lancé$([[ "${DRY_RUN}" == "true" ]] && echo " (dry-run)")." \
    pid "${pid}" started_at "$(now_iso)"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
main() {
  local action="" run_action="" from_ssh="false"
  local -a argv=(${@+"${@}"})

  if [[ "${1:-}" == "--ssh" ]]; then
    from_ssh="true"
    # Commande forcée (authorized_keys) : seule la commande demandée par le
    # client est lue, découpée en mots sans interprétation shell ni globbing.
    set -f
    # shellcheck disable=SC2206
    argv=(${SSH_ORIGINAL_COMMAND:-})
    set +f
  fi
  set -- ${argv[@]+"${argv[@]}"}

  # Processus détaché lancé par start_action (jamais accepté par SSH)
  if [[ "${1:-}" == "__run" && "${from_ssh}" == "false" && "${VCF_LAB_HA_CHILD:-}" == "1" ]]; then
    run_action="${2:-}"
    [[ "${3:-}" == "--dry-run" ]] && DRY_RUN="true"
    case "${run_action}" in
      shutdown | startup) ;;
      *) exit 1 ;;
    esac
    load_config
    load_secrets
    run_detached "${run_action}"
    exit 0
  fi

  while [[ "${#}" -gt 0 ]]; do
    case "${1}" in
      shutdown | startup | status)
        [[ -z "${action}" ]] || refuse "${action}" "Une seule action à la fois."
        action="${1}"
        ;;
      --dry-run) DRY_RUN="true" ;;
      --help | -h)
        [[ "${from_ssh}" == "false" ]] && usage
        refuse "?" "Actions : shutdown, startup, status (option --dry-run)."
        ;;
      *) refuse "${action:-?}" "Argument inconnu : ${1}. Actions : shutdown, startup, status (option --dry-run)." ;;
    esac
    shift
  done

  case "${action}" in
    status) show_status ;;
    shutdown | startup) start_action "${action}" ;;
    *) refuse "?" "Aucune action. Actions : shutdown, startup, status (option --dry-run)." ;;
  esac
}

main ${@+"${@}"}

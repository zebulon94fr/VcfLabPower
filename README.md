# VcfLabPower

Arrêt ordonné du **domaine de gestion d'un lab VMware Cloud Foundation 9.1**, en un seul script bash.

L'ordre d'arrêt suit la documentation Broadcom
[Shut Down the Management Domain (VCF 9.1)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain.html).
Le script réutilise le script officiel `vcf_services_runtime_shutdown.sh` (KB 440874) pour arrêter le VCF services runtime.

> ⚠️ Pensé pour un **lab**. Lis le script, adapte la configuration et lance toujours un `--dry-run` avant.

## Ordre d'arrêt

| Étape | Composant | Méthode |
|---|---|---|
| 0 | Workloads / VMs hors VCF du domaine de gestion | Shut down Guest OS |
| 1 | VCF Automation | Pause manuelle : power-off via VCF Operations (State management), puis contrôle des VMs |
| 2 | VCF Operations for networks | Pause manuelle via VCF Operations, puis contrôle des VMs |
| 3 | Cloud proxies | Shut down Guest OS |
| 4 | License server | Shut down Guest OS |
| 5 | VCF services runtime | Script officiel (`--skip-poweroff`), puis Shut down Guest OS des nœuds |
| 6 | VCF Operations | *Take cluster offline* (API CaSA, KB 313533, ou pause UI), puis nœuds dans l'ordre KB 341964 |
| 7 | Protection & recovery (VLSR) | Shut down Guest OS |
| 8 | NSX Edge / VNA | Shut down Guest OS |
| 9 | NSX Manager | Shut down Guest OS |
| 10 | SDDC Manager | Shut down Guest OS |
| 11 | vCenter, VMs d'infra (DNS/NTP/AD), stockage, hôtes ESX | **vSAN** : arrêt scripté (`reboot_helper.py`) ou instructions du *Shutdown Cluster wizard*. **NFS / FC** : procédure doc « without vSAN storage » |

Si une liste de VMs est vide dans la configuration, l'étape correspondante est sautée.

## Prérequis

- Une **machine d'admin hors du domaine de gestion**. Pas SDDC Manager : il est arrêté à l'étape 10, et le script refuse de tourner dessus.
- `bash` (3.2+, donc macOS compris), `curl`, `jq`, [`govc`](https://github.com/vmware/govmomi/tree/main/govc).
- vSAN uniquement : `ssh` vers les ESX, et `sshpass` si l'accès se fait par mot de passe plutôt que par clé. En NFS/FC, SSH n'est pas nécessaire.
- Le script officiel **`vcf_services_runtime_shutdown.sh`**, à télécharger depuis la [KB 440874](https://knowledge.broadcom.com/external/article/440874) et à placer à côté de `vcf_lab_shutdown.sh`.
  Il n'est pas versionné ici (Broadcom Confidential).
  - Prends **la pièce jointe actuelle** de la KB. Une ancienne copie peut appeler des endpoints absents de ton build (HTTP 404 sur `/api/v1/system?action=shutdown` constaté en 9.1.1.0100).
  - `vcf_lab_shutdown.sh` détecte les options de la version présente (`--skip-poweroff` ou `--poweroff-vms`, `--kubeconfig`) et n'envoie que celles qu'elle accepte.
  - Si la version demande `--kubeconfig`, renseigne `VCFMS_KUBECONFIG`.
- Pas de snapshot sur les VMs : le précheck du VCF services runtime échoue s'il en trouve.
- Les workload domains déjà arrêtés.

## Installation

```bash
git clone https://github.com/zebulon94fr/VcfLabPower.git
cd VcfLabPower
# copier ici vcf_services_runtime_shutdown.sh (KB 440874)
cp vcf_lab_shutdown.conf mon-lab.local.conf   # ignoré par git
vi mon-lab.local.conf
```

## Configuration

Le fichier `vcf_lab_shutdown.conf` est commenté. On y renseigne :

- le vCenter de gestion (`GOVC_URL`, `GOVC_USERNAME`), le cluster (`MGMT_CLUSTER`) et la VM vCenter (`VCENTER_VM`) ;
- les hôtes ESX (`ESX_HOSTS`) : le premier exécute `reboot_helper.py` et s'éteint en dernier ;
- les noms de VMs de chaque étape (nom d'inventaire vCenter ou MoRef `VirtualMachine:vm-123`) ;
- l'IP d'un nœud control plane du VCF services runtime (`VCFMS_NODE_IP`). Les VMs des nœuds sont découvertes via l'API. Sur certains builds 9.1.1, l'endpoint d'inventaire renvoie HTTP 404 : il faut alors renseigner `VCFMS_VMS` (noms exacts) ou `VCFMS_VM_PATTERN` (motif glob recherché dans vCenter) ;
- les modes :
  - `VCFA_MODE` / `VCFNET_MODE` : `ui` (pause manuelle, méthode de la doc), `vm` (arrêt Guest OS direct, raccourci de lab) ou `none` ;
  - `VCFOPS_OFFLINE_MODE` : `api` ou `ui` ;
  - `MGMT_STORAGE` : `vsan` ou `nfs` (NFS ou Fibre Channel) ;
  - `VSAN_SHUTDOWN_MODE` (vSAN) : `manual` (scripté) ou `wizard` (instructions du Shutdown Cluster wizard) ;
- `INFRA_VMS` : DNS, NTP, AD… hébergés sur le cluster, arrêtés **après** le vCenter.

Les secrets se passent par variables d'environnement. S'ils sont absents, le script les demande au lancement :

| Variable | Usage |
|---|---|
| `GOVC_PASSWORD` | vCenter de gestion |
| `VMSP_PASSWORD` | `vmware-system-user` du VCF services runtime |
| `VCFOPS_ADMIN_PASSWORD` | compte `admin` local de VCF Operations (`/admin`) |
| `ESX_ROOT_PASSWORD` | root ESX : SSH en vSAN (sinon clé SSH) ; connexion directe à l'ESX du vCenter en NFS/FC |

## Utilisation

```bash
./vcf_lab_shutdown.sh --config mon-lab.local.conf --dry-run   # simulation
./vcf_lab_shutdown.sh --config mon-lab.local.conf             # arrêt réel (confirmation « SHUTDOWN »)
./vcf_lab_shutdown.sh --config mon-lab.local.conf --from-step 6   # reprise après échec
```

| Option | Effet |
|---|---|
| `--dry-run` | Affiche les actions sans rien arrêter. Les lectures (inventaire, SSH, API) sont faites. |
| `--from-step N` / `--to-step N` | Exécute seulement une plage d'étapes (0-11). |
| `--yes` | Pas de confirmation initiale. Les pauses manuelles restent interactives. |
| `--force-poweroff` | Hard power-off si VMware Tools est absent ou si le délai d'arrêt est dépassé. |
| `--skip-snapshot-check` | Ignore la vérification des snapshots. |

Les journaux sont écrits dans `logs/`. L'état HA/DRS d'origine du cluster y est aussi sauvegardé (`cluster_state_<cluster>.env`).

## Arrêt vSAN scripté (`VSAN_SHUTDOWN_MODE=manual`)

Il suit la procédure vSAN *Manually Shut Down and Restart the vSAN Cluster* et la KB 322144 :

1. Contrôle de santé vSAN : membres du cluster, objets, resynchronisation.
2. vSphere HA désactivé, DRS en manuel (état d'origine sauvegardé).
3. `esxcfg-advcfg -s 1 /VSAN/IgnoreClusterMemberListUpdates` sur chaque hôte.
4. Shut down Guest OS du vCenter, puis des VMs d'infra, depuis les hôtes (`vim-cmd`).
5. `python /usr/lib/vmware/vsan/bin/reboot_helper.py prepare`, **une seule fois** (KB 390160).
6. Mode maintenance `noAction` sur chaque hôte.
7. `esxcli system shutdown poweroff` : le premier hôte est éteint en dernier.

Points d'attention :

- L'arrêt est **interdit avec un witness vSAN partagé** (KB 455801) : passer en `VSAN_SHUTDOWN_MODE=wizard`.
- Les hôtes doivent avoir une heure synchronisée par NTP (KB 410326).
- Le script démarre le service SSH des ESX via vCenter pendant les pré-vérifications (`ENABLE_ESX_SSH`).

## Arrêt NFS / Fibre Channel (`MGMT_STORAGE=nfs`)

Il suit la doc VCF 9.1 [Shut Down ESX Hosts with NFS or Fibre Channel Storage in the Management Domain](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain/shut-down-the-esx-hosts-in-management-domain/shut-down-esx-hosts-without-vsan-storage.html) :

1. Repère l'hôte qui exécute le vCenter et le note dans `logs/cluster_state_*.env` : il faudra le démarrer en premier.
2. Désactive vSphere HA et passe DRS en manuel, pour figer le placement (état d'origine sauvegardé).
3. Migre les VMs d'infra sur l'hôte du vCenter, comme le demande la doc.
4. Met en maintenance puis éteint via vCenter tous les autres hôtes du cluster. La liste vient du cluster lui-même ; `ESX_HOSTS` est ignoré.
5. Se connecte directement à l'ESX du vCenter avec govc (équivalent du Host Client, sans SSH) :
   - Shut down Guest OS du vCenter, puis des VMs d'infra ;
   - arrêt de l'hôte.
6. Rappelle de n'arrêter le stockage NFS/FC que si aucun autre client ne l'utilise.

Un seul cluster de gestion est géré. S'il y en a plusieurs, il faut arrêter d'abord ceux qui n'hébergent pas le vCenter.

## Redémarrage (rappel)

**vSAN :**

1. Démarrer l'infra physique, puis les hôtes ESX.
2. Sur chaque hôte : `esxcli system maintenanceMode set -e false`.
3. Sur **un seul** hôte : `python /usr/lib/vmware/vsan/bin/reboot_helper.py recover`.
4. Sur chaque hôte : `esxcfg-advcfg -s 0 /VSAN/IgnoreClusterMemberListUpdates`.
5. Démarrer le vCenter, puis réactiver HA/DRS comme avant (voir `logs/cluster_state_*.env`).
6. Suivre la procédure de démarrage VCF 9.1, dans l'ordre inverse de l'arrêt.

**NFS / FC :**

1. Démarrer le stockage et l'infra physique.
2. Démarrer d'abord l'hôte du vCenter (`VCENTER_HOST` dans `logs/cluster_state_*.env`), puis le vCenter et les VMs d'infra depuis le Host Client.
3. Démarrer les autres hôtes et les sortir du mode maintenance.
4. Réactiver HA/DRS comme avant.
5. Suivre la procédure de démarrage VCF 9.1.

## À valider sur ton environnement

- La lecture de l'état du cluster VCF Operations par `GET /casa/sysadmin/cluster/online_state`. La KB 313533 ne documente que le `POST`. En cas de souci, passer en `VCFOPS_OFFLINE_MODE=ui`.
- La présence de `reboot_helper.py` sur les ESX 9.x. Le script la vérifie en pré-check.
- VCF Automation et VCF Operations for networks : la doc ne documente aucune API d'arrêt, d'où les pauses manuelles.

## Références

- [Shut Down the Management Domain (VCF 9.1)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain.html)
- [Shut Down VCF Management Services](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/fleet-management/vcf-shutdown-and-startup/vcf-shutdown/shut-down-the-management-domain/shut-down-vcf-managament-services.html) — KB 440874
- [KB 313533 – état online/offline du cluster VCF Operations](https://knowledge.broadcom.com/external/article/313533)
- [KB 341964 – ordre d'arrêt et de démarrage des nœuds VCF Operations](https://knowledge.broadcom.com/external/article/341964)
- [KB 322144 – reboot_helper.py](https://knowledge.broadcom.com/external/article/322144)
- [KB 390160](https://knowledge.broadcom.com/external/article/390160), [KB 455801](https://knowledge.broadcom.com/external/article/455801), [KB 410326](https://knowledge.broadcom.com/external/article/410326/vsan-cluster-shutdown-preparation-fails.html)

Ce projet n'est pas affilié à Broadcom ni à VMware. Utilisation à tes risques.

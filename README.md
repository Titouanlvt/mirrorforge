# mirror.sh — Miroir APT local (Debian 13, Proxmox, Ceph) sur HDD

Un script Bash unique et turnkey qui miroite des dépôts APT sur un disque HDD local, sans aucun argument :

```bash
sudo ./mirror.sh
```

# Prérequis

- **Debian 13 (trixie)**, fraîchement installée.
- Accès **root** (le script se relance via `sudo` si besoin).
- Un **HDD de ≥ 4 To, branché et DÉJÀ FORMATÉ** (ext4 ou tout autre filesystem reconnu par `blkid`), **non monté**.
- Une connexion Internet vers `deb.debian.org`, `security.debian.org` et `download.proxmox.com`.

# Ce que fait le script (sans argument)

1. Se relance en root si besoin (sudo).
2. Installe ses dépendances : `debmirror`, `rsync`, `gnupg`, `debian-archive-keyring`, `curl`.
3. **Détecte automatiquement** le plus grand disque qui n'est ni le disque système ni monté, lit son UUID via `blkid`, ajoute une entrée `fstab` (par UUID, `nofail`) si absente, et le monte sur `/mnt/miroir`.
4. Crée l'arborescence des dépôts sur le disque.
5. Vérifie l'espace libre (marge configurable, 50 Go par défaut).
6. Importe les clés GPG nécessaires (keyring Debian + clé Proxmox release-trixie).
7. Synchronise séquentiellement, via `debmirror` :
   - **Debian** : `trixie`, `trixie-updates`, `trixie-backports` → `debian/`
   - **Debian security** : `trixie-security` → `debian-security/`
   - **Proxmox VE** (`pve-no-subscription`) → `pve/`
   - **Proxmox Backup Server** (`pbs-no-subscription`) → `pbs/`
   - **Proxmox Datacenter Manager** (`pdm-no-subscription`) → `pdm/`
   - **Ceph** (`no-subscription`) : `ceph-squid` et `ceph-tentacle` → `ceph-squid/`, `ceph-tentacle/`
8. Affiche un rapport final : par dépôt, volume, durée, statut.

Sources (.deb-src) désactivées par défaut (option `INCLUDE_SOURCES="true"` en tête de script).

# Ce que le script ne fait PAS

- **Il ne formate, ne partitionne et n'efface JAMAIS rien.** Si le disque détecté n'a pas de filesystem reconnu, il s'arrête avec un message clair.
- **Il n'installe aucun serveur HTTP** (nginx, apache…) et **aucun timer** systemd : il se contente de déposer les dépôts sur le disque.
- Si plusieurs disques candidats de taille proche sont trouvés, **il ne devine pas** : il liste les candidats et s'arrête.
- Il ne publie pas les dépôts sur le réseau — pour servir un LAN, ajoutez vous-même un serveur HTTP pointant sur `/mnt/miroir`.

# Commandes

| Commande | Effet |
|---|---|
| `sudo ./mirror.sh` | Bootstrap complet + synchro de tout |
| `sudo ./mirror.sh sync [debian\|proxmox\|ceph\|all]` | Relance seulement une synchro (sans refaire l'install/détection si déjà bootstrappé) |
| `sudo ./mirror.sh dry-run [cible]` | Estime ce qui serait téléchargé sans rien écrire |
| `sudo ./mirror.sh status` | Espace utilisé par dépôt + date de dernière synchro réussie |
| `sudo ./mirror.sh unmount` | Démonte proprement le disque |

# Robustesse

- `set -euo pipefail`, script **shellcheck-clean** et **idempotent** (relançable sans casse).
- `flock` contre la double exécution.
- Logs horodatés sur le disque miroir (`/mnt/miroir/mirror-logs/`) + sortie console avec progression.
- **3 retries** avec délai exponentiel par dépôt ; l'échec d'un dépôt **ne bloque pas** les suivants.
- Le premier sync dure des heures : **Ctrl+C interrompt proprement** et un simple relancement reprend là où c'était arrêté (debmirror ne retélécharge pas ce qui est déjà présent).

# Configuration

Tout est regroupé en tête de `mirror.sh` dans un bloc de variables commentées :

- `DISK_UUID` — figer le disque (sinon détection auto + mémorisation sur le disque).
- `MOUNT_POINT` — point de montage.
- `MIN_FREE_GB` — marge d'espace libre requise.
- `DEBIAN_SUITES`, `SECURITY_SUITES`, `DEBIAN_SECTIONS` — suites/sections Debian.
- `PROXMOX_SUITE`, `PVE_COMPONENT`, `PBS_COMPONENT`, `PDM_COMPONENT` — dépôts Proxmox.
- `CEPH_RELEASES` — releases Ceph miroitées (ex. `"squid tentacle"`).
- `ARCHES` — architectures (défaut : `amd64`).
- `INCLUDE_SOURCES` — inclure les sources `.deb-src` (défaut : `false`).

## Ajouter une release Ceph

Ajoutez simplement le nom à `CEPH_RELEASES` (ex. `CEPH_RELEASES="squid tentacle reef"`). Le script crée automatiquement `/mnt/miroir/ceph-<release>` et miroite `download.proxmox.com/debian/ceph-<release>`.

## Ajouter une suite Debian

Ajoutez-la à `DEBIAN_SUITES` ou `SECURITY_SUITES` (ex. `DEBIAN_SUITES="trixie,trixie-updates,trixie-backports,forky"`).

# Publier sur GitHub

```bash
git init && git add mirror.sh README.md && git commit -m "Miroir APT Debian 13 + Proxmox + Ceph"
git remote add origin git@github.com:Titouanlvt/mirrorforge.git
git push -u origin main
```

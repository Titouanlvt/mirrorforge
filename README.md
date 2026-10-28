<div align="center">

# 🔷 mirrorforge

**Un seul script Bash. Un HDD. Tous vos dépôts APT.**

Debian 13 · Proxmox VE · Proxmox Backup · Datacenter Manager · Ceph

[![Debian](https://img.shields.io/badge/Debian-13%20trixie-A80030?style=flat-square&logo=debian&logoColor=white)](https://www.debian.org)
[![Proxmox](https://img.shields.io/badge/Proxmox-VE%209%20·%20PBS%20·%20PDM-E57000?style=flat-square)](https://www.proxmox.com)
[![Ceph](https://img.shields.io/badge/Ceph-Squid%20·%20Tentacle-EF5B25?style=flat-square)](https://ceph.io)
[![Shell](https://img.shields.io/badge/Shell-Bash%205-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-0%20erreur-2ea44f?style=flat-square)](https://www.shellcheck.net)
[![Licence](https://img.shields.io/badge/usage-libre-blue?style=flat-square)](#)

*Par défaut, le script ne formate rien et ne touche qu'un disque déjà formaté.*
*Pour un disque NEUF : une seule variable à activer (`FORMAT_DISK="yes"`) et il s'en occupe.*

</div>

---

## ⚡ Démarrage express

Vous venez d'installer Debian 13, votre HDD est branché et **déjà formaté** ? C'est tout ce qu'il faut :

```bash
git clone https://github.com/Titouanlvt/mirrorforge.git
cd mirrorforge
sudo ./mirror.sh
```

Le script fait **tout, automatiquement, jusqu'au bout** : dépendances, détection du disque, montage, clés GPG, puis miroir complet des 7 dépôts. Le premier sync dure des heures — vous pouvez faire **Ctrl+C** et relancer plus tard, il reprendra où il s'était arrêté.

## 📦 Dépôts miroités

| Dépôt | Suites / composants | Destination |
|---|---|---|
| 🐧 **Debian** | `trixie` `trixie-updates` `trixie-backports` — main, contrib, non-free, non-free-firmware | `debian/` |
| 🔒 **Debian Security** | `trixie-security` | `debian-security/` |
| 🖥️ **Proxmox VE** | `pve-no-subscription` | `pve/` |
| 💾 **Proxmox Backup Server** | `pbs-no-subscription` | `pbs/` |
| 🗂️ **Proxmox Datacenter Manager** | `pdm-no-subscription` | `pdm/` |
| 🦑 **Ceph Squid** | `no-subscription` | `ceph-squid/` |
| 🐙 **Ceph Tentacle** | `no-subscription` | `ceph-tentacle/` |

Tout atterrit sur `/mnt/miroir/`, arch `amd64`, sources `.deb-src` désactivées par défaut.

## 🧭 Commandes

```bash
sudo ./mirror.sh                     # 🚀 Bootstrap complet + synchro de tout
sudo ./mirror.sh sync [debian|proxmox|ceph|all]
                                     # ♻️  Ressynchronise un groupe (sans refaire l'install)
sudo ./mirror.sh dry-run [cible]     # 👀 Estime le téléchargement sans rien écrire
sudo ./mirror.sh status              # 📊 Espace par dépôt + dernière synchro réussie
sudo ./mirror.sh unmount             # ⏏️  Démonte proprement le disque
```

## 🛡️ Ce que le script ne fait JAMAIS

> **✋ Règles de sécurité, codées en dur :**

| ❌ Jamais sans consentement explicite | ✅ Comportement réel |
|---|---|
| Formater par défaut | Le script ne formate **que** si `FORMAT_DISK="yes"` et uniquement un disque **vierge** (pas de fs, pas de partitions multiples, non monté, pas le disque système) |
| Deviner entre plusieurs disques | Candidats (formatés **ou** vierges) de taille proche → **liste affichée + arrêt propre** |
| Monter un disque sans filesystem reconnu | `blkid` ne reconnaît rien et `FORMAT_DISK="no"` → **arrêt avec message clair** |

Et également :
- 🚫 **Aucun serveur HTTP** — pas de nginx, pas d'apache
- 🚫 **Aucun timer systemd** — pas de cron, pas de service
- 🚫 **Aucune exposition réseau** — les dépôts sont juste déposés sur le disque

Pour servir un LAN ensuite, ajoutez vous-même un serveur HTTP pointant sur `/mnt/miroir`.

## 🔧 Robustesse

```
set -euo pipefail · shellcheck-clean · idempotent
├── 🔒 flock          → pas de double exécution
├── 📝 logs horodatés → /mnt/miroir/mirror-logs/ + console avec progression
├── 🔁 3 retries       → délai exponentiel par dépôt (30s → 60s → 120s)
├── 🧯 isolation      → l'échec d'un dépôt ne bloque PAS les suivants
└── ⏸️  Ctrl+C         → interruption propre, reprise au relancement
```

## ⚙️ Configuration

Tout se règle dans le **bloc de variables commenté en tête de `mirror.sh`** — aucun fichier externe requis :

| Variable | Rôle | Défaut |
|---|---|---|
| `DISK_UUID` | Figer le disque (vide = détection auto + mémorisation) | `""` |
| `FORMAT_DISK` | Auto-formater un disque **neuf/vierge** en ext4 (`no` par défaut) | `no` |
| `MOUNT_POINT` | Point de montage | `/mnt/miroir` |
| `MIN_FREE_GB` | Marge d'espace libre exigée avant synchro | `50` |
| `DEBIAN_SUITES` / `SECURITY_SUITES` | Suites Debian | `trixie…` |
| `DEBIAN_SECTIONS` | Sections Debian | main, contrib, non-free, non-free-firmware |
| `PROXMOX_SUITE` | Suite des dépôts Proxmox | `trixie` |
| `CEPH_RELEASES` | Releases Ceph miroitées | `squid tentacle` |
| `ARCHES` | Architectures | `amd64` |
| `INCLUDE_SOURCES` | Inclure les `.deb-src` | `false` |
| `MAX_RETRIES` / `RETRY_DELAY` | Tentatives et délai exponentiel | `3` / `30` |

### ➕ Ajouter une release Ceph

```bash
# en tête de mirror.sh :
CEPH_RELEASES="squid tentacle reef"
```

Le script crée automatiquement `/mnt/miroir/ceph-reef` et miroite `download.proxmox.com/debian/ceph-reef`. Rien d'autre à faire.

### ➕ Ajouter une suite Debian

```bash
DEBIAN_SUITES="trixie,trixie-updates,trixie-backports,forky"
```

## 📋 Prérequis

- [ ] Debian 13 (**trixie**), fraîchement installée
- [ ] Accès **root** (le script se relance via `sudo` si besoin)
- [ ] Un HDD de **≥ 2 To** (un miroir complet Debian + Proxmox + Ceph tient dans ~500 Go ; entre 2 et 3 To c'est confortable), branché, **non monté**
  - Disque **déjà formaté** → rien à faire, le script le détecte
  - Disque **neuf (vierge)** → mettez `FORMAT_DISK="yes"` en tête du script : il sera formaté automatiquement en ext4, sous conditions de sécurité
- [ ] Une connexion Internet vers `deb.debian.org` · `security.debian.org` · `download.proxmox.com`

> 💡 **Pas besoin de préparer le disque à la main** : détection automatique du plus grand disque libre, entrée `fstab` par UUID avec `nofail` ajoutée seule si absente.

## 📖 Comment ça marche

```
sudo ./mirror.sh
   │
   ├─ 1. Relance en root via sudo si nécessaire
   ├─ 2. Installe debmirror, rsync, gnupg, debian-archive-keyring, curl
   ├─ 3. Détecte le HDD (exclut disque système & disques montés) → fstab → montage
   ├─ 4. Crée /mnt/miroir/{debian, debian-security, pve, pbs, pdm, ceph-*}
   ├─ 5. Vérifie l'espace libre (marge 50 Go)
   ├─ 6. Importe les clés GPG (Debian + Proxmox release-trixie)
   └─ 7. debmirror × 7 dépôts, séquentiel, avec retries → rapport final
```

---

<div align="center">

**mirrorforge** — miroir APT local, turnkey, sans risque.

⭐ Une étoile sur le dépôt si le script vous a servi !

</div>

#!/usr/bin/env bash
#
# mirror.sh — Miroir APT local (Debian 13 "trixie", Proxmox VE/PBS/PDM, Ceph)
#
# Usage :
#   sudo ./mirror.sh                 # bootstrap complet + synchro de tout
#   sudo ./mirror.sh sync [debian|proxmox|ceph|all]
#   sudo ./mirror.sh dry-run [debian|proxmox|ceph|all]
#   sudo ./mirror.sh status          # espace utilisé + dernière synchro par dépôt
#   sudo ./mirror.sh unmount         # démonte le disque miroir
#
# Le script ne formate JAMAIS, ne partitionne JAMAIS et n'efface JAMAIS rien.
# Il ne monte qu'un disque DÉJÀ formaté et n'installe aucun serveur HTTP ni timer.
#
# Compatible Debian 13 (trixie). Dépendances présentes dans les dépôts Debian :
# debmirror, rsync, gnupg, debian-archive-keyring, curl, util-linux, util-linux( flock ).

set -euo pipefail

# PATH complet et déterministe : sur certaines installs minimales/VM, sudo
# fournit un PATH restreint sans /usr/sbin ni /usr/local/bin — les binaires
# système (mkfs.ext4, blkid, mount...) sembleraient alors « introuvables »
# alors qu'ils sont installés. On force un PATH complet dès le départ.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Résolution robuste des binaires système : retourne le chemin absolu du
# binaire, en cherchant dans le PATH puis dans les répertoires sbin classiques
# (certains environnements restreints ne les exposent pas dans le PATH).
resolve_bin() {
    local b
    for b in "$(command -v "$1" 2>/dev/null || true)" \
        /usr/sbin/"$1" /sbin/"$1" /usr/bin/"$1" /bin/"$1" \
        /usr/local/sbin/"$1" /usr/local/bin/"$1"; do
        [[ -n $b && -x $b ]] && { echo "$b"; return 0; }
    done
    return 1
}

# =============================================================================
# BLOC DE CONFIGURATION — tout est réglable ici, aucun fichier externe requis
# =============================================================================

# Disque : laissez DISK_UUID vide pour la détection automatique au premier
# lancement. Après le bootstrap, l'UUID détecté est mémorisé dans un fichier
# d'état sur le disque miroir ; vous pouvez aussi le figer ici manuellement
# (ex.: DISK_UUID="a1b2c3d4-...").
DISK_UUID=""

# Point de montage du disque miroir.
MOUNT_POINT="/mnt/miroir"

# Racine des dépôts sur le disque miroir.
MIRROR_ROOT="$MOUNT_POINT"

# Marge d'espace libre minimale (en Go) exigée sur le disque avant toute synchro.
MIN_FREE_GB="50"

# AUTO-FORMATAGE d'un disque NEUF (vierge, sans filesystem) :
#   "no"  (défaut, sûr) : si le disque détecté est vierge, le script s'arrête
#         avec un message vous invitant à le formater vous-même.
#   "yes" (pour disque neuf) : si le disque détecté est vierge ET qu'il passe
#         toutes les vérifications de sécurité (pas le disque système, pas monté,
#         pas de partitions), il est formaté automatiquement en ext4.
# ATTENTION : formater efface IRRÉMÉDIABLEMENT le contenu du disque.
# Ne mettez "yes" que pour un disque neuf que vous venez de brancher.
FORMAT_DISK="yes"

# Suites et sections Debian.
DEBIAN_HOST="deb.debian.org"
DEBIAN_ROOT="debian"
DEBIAN_SUITES="trixie,trixie-updates,trixie-backports"
SECURITY_HOST="security.debian.org"
SECURITY_ROOT="debian-security"
SECURITY_SUITES="trixie-security"
DEBIAN_SECTIONS="main,contrib,non-free,non-free-firmware"

# Dépôts Proxmox.
PROXMOX_HOST="download.proxmox.com"
PROXMOX_SUITE="trixie"
PVE_COMPONENT="pve-no-subscription"
PBS_COMPONENT="pbs-no-subscription"
PDM_COMPONENT="pdm-no-subscription"

# Releases Ceph packagées par Proxmox (ex.: "squid tentacle").
# Chaque release X devient : dépôt /debian/ceph-X -> $MIRROR_ROOT/ceph-X
CEPH_RELEASES="squid tentacle"
CEPH_COMPONENT="no-subscription"

# Architectures à miroiter.
ARCHES="amd64"

# Inclure les sources (.deb-src) : "true" ou "false" (défaut : false).
INCLUDE_SOURCES="false"

# Clé GPG Proxmox (release trixie) et emplacement du keyring local.
PROXMOX_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg"
PROXMOX_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
DEBIAN_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"

# Tentatives par dépôt et délai initial entre tentatives (secondes, exponentiel).
MAX_RETRIES="3"
RETRY_DELAY="30"

# Répertoire des logs (créé sur le disque miroir une fois monté).
LOG_DIR="$MIRROR_ROOT/mirror-logs"

# Répertoire d'état interne (dernières synchros) sur le disque miroir.
STATE_DIR="$MIRROR_ROOT/.mirror-state"

# Fichier d'état système (UUID mémorisé) : sur le filesystem RACINE, pas sur le
# disque miroir, car il doit être lisible AVANT le montage à chaque lancement.
PERSIST_STATE_DIR="/var/lib/mirror-sh"
STATE_UUID_FILE="$PERSIST_STATE_DIR/disk.uuid"

# =============================================================================
# FIN DU BLOC DE CONFIGURATION
# =============================================================================

VERSION="1.1.0"
# Progression globale : dépôt courant / total des dépôts du run.
REPO_INDEX=0
REPO_TOTAL=0
# Temps et volume cumulés des dépôts déjà traités (estimation restant + débit).
ELAPSED_REPO_SECONDS=0
ELAPSED_REPO_MB=0
LOCK_FILE="/run/lock/mirror.sh.lock"
FSTAB="/etc/fstab"
LOG_FILE=""
START_TS=$(date +%s)
mkdir -p "$PERSIST_STATE_DIR" 2>/dev/null || true

# Logger console + fichier. Le fichier n'est ouvert qu'après le montage du
# disque (avance_log), avant : console uniquement.
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERREUR : $*"
    log "Abandon."
    exit 1
}

usage() {
    cat <<EOF
mirror.sh v$VERSION — miroir APT local Debian 13 / Proxmox / Ceph

Usage :
  sudo ./mirror.sh                          bootstrap + synchro de tout
  sudo ./mirror.sh sync [debian|proxmox|ceph|all]
  sudo ./mirror.sh dry-run [debian|proxmox|ceph|all]
  sudo ./mirror.sh status                   espace utilisé + dernières synchros
  sudo ./mirror.sh unmount                  démonte le disque miroir
  sudo ./mirror.sh doctor                   diagnostic complet de l'environnement
EOF
    exit 2
}

# Ouvre le fichier de log sur le disque miroir et y redirige aussi la sortie.
init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/mirror-$(date '+%Y%m%d-%H%M%S').log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Log : $LOG_FILE"
}

# --- flock : évite deux exécutions simultanées -------------------------------
acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        die "Une autre instance de mirror.sh tourne déjà (verrou $LOCK_FILE)."
    fi
}

# Ctrl+C / SIGTERM : arrêt propre (debmirror reprendra au prochain lancement).
on_interrupt() {
    log "Interrompu (Ctrl+C). Les dépôts déjà synchronisés sont intacts ;"
    log "relancez le script pour reprendre là où il s'était arrêté."
    exit 130
}

# --- root / relance sudo ----------------------------------------------------
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            log "Pas en root, relance via sudo..."
            exec sudo "$0" "$@"
        fi
        die "Ce script doit être exécuté en root (sudo ./mirror.sh)."
    fi
}

# =============================================================================
# ÉTAPE 1 — dépendances
# =============================================================================
install_deps() {
    log "[1/6] Vérification des dépendances..."
    export DEBIAN_FRONTEND=noninteractive
    log "  → apt-get update..."
    apt-get update -qq
    log "  → Installation des paquets : debmirror rsync gnupg debian-archive-keyring curl e2fsprogs util-linux mount"
    if ! apt-get install -y debmirror rsync gnupg debian-archive-keyring curl \
        e2fsprogs util-linux mount; then
        die "apt-get install a échoué — ci-dessus l'erreur réelle du gestionnaire de paquets."
    fi
    log "  ✔ Dépendances installées :"
    log "      • debmirror (moteur de synchro)"
    log "      • rsync (transfert incrémental)"
    log "      • gnupg (vérification GPG)"
    log "      • debian-archive-keyring (clés Debian)"
    log "      • curl (téléchargement clé Proxmox)"
    log "      • e2fsprogs (mkfs.ext4, wipefs)"
    log "      • util-linux (blkid, lsblk, findmnt, flock, udevadm)"
    log "      • mount (mount, umount)"
    # Vérification que les binaires critiques sont bien là (chemin absolu),
    # avec auto-réparation : si un binaire manque, on réinstalle son paquet
    # (--reinstall force la remise en place des fichiers, symlinks compris)
    # puis on re-résout ; en dernier recours on affiche le contenu du paquet
    # (dpkg -L) pour voir ce qui a réellement été installé et où.
    local bin path_bin owner_pkg
    for bin in debmirror blkid flock lsblk findmnt mountpoint curl wipefs; do
        if ! path_bin=$(resolve_bin "$bin"); then
            owner_pkg=$(dpkg -S "$bin" 2>/dev/null | head -1 | cut -d: -f1 || true)
            [[ -n $owner_pkg ]] || owner_pkg="util-linux"
            log "  ⚠ $bin introuvable — réinstallation forcée de $owner_pkg..."
            apt-get install -y --reinstall "$owner_pkg" || true
            hash -r 2>/dev/null || true
            path_bin=$(resolve_bin "$bin") || {
                log "  ✘ $bin TOUJOURS introuvable après réinstallation de $owner_pkg."
                log "    Contenu du paquet (dpkg -L $owner_pkg) :"
                dpkg -L "$owner_pkg" 2>/dev/null | grep -E "$bin|sbin" | head -10 | while read -r l; do log "      $l"; done
                log "    PATH actuel : $PATH"
                die "Impossible de trouver $bin — relancez avec ./mirror.sh doctor pour un diagnostic complet."
            }
        fi
        log "      ✔ $bin -> $path_bin"
    done
    # Le formateur ext4 : mkfs.ext4 OU son binaire réel mke2fs.
    MKFS_EXT4=$(resolve_bin mkfs.ext4 || true)
    if [[ -z $MKFS_EXT4 ]]; then
        MKFS_EXT4=$(resolve_bin mke2fs || true)
        [[ -n $MKFS_EXT4 ]] && MKFS_EXT4="$MKFS_EXT4 -t ext4"
    fi
    if [[ -z $MKFS_EXT4 ]]; then
        log "  ⚠ mkfs.ext4/mke2fs introuvable — réinstallation forcée d'e2fsprogs..."
        apt-get install -y --reinstall e2fsprogs || true
        hash -r 2>/dev/null || true
        MKFS_EXT4=$(resolve_bin mkfs.ext4 || true)
        if [[ -z $MKFS_EXT4 ]]; then
            MKFS_EXT4=$(resolve_bin mke2fs || true)
            [[ -n $MKFS_EXT4 ]] && MKFS_EXT4="$MKFS_EXT4 -t ext4"
        fi
        if [[ -z $MKFS_EXT4 ]]; then
            log "  ✘ formateur ext4 TOUJOURS introuvable. Contenu d'e2fsprogs :"
            dpkg -L e2fsprogs 2>/dev/null | grep -E 'mkfs|mke2fs' | head -10 | while read -r l; do log "      $l"; done
            log "    PATH actuel : $PATH"
            die "Relancez avec ./mirror.sh doctor pour un diagnostic complet."
        fi
    fi
    log "      ✔ formateur ext4 -> $MKFS_EXT4"
    log "  ✔ Tous les binaires critiques vérifiés."
}

# Diagnostic complet de l'environnement : pour les « introuvable »
# récurrents, sans deviner. Affiche OS, PATH, binaires résolus, paquets.
cmd_doctor() {
    log "=== mirror.sh doctor — diagnostic complet ==="
    log ""
    log "── Système ──"
    log "  OS     : $(cat /etc/os-release 2>/dev/null | grep PRETTY | cut -d'"' -f2 || echo inconnu)"
    log "  Kernel : $(uname -r)"
    log "  User   : $(id)"
    log "  PATH   : $PATH"
    log ""
    log "── Binaires critiques (résolution par chemin absolu) ──"
    local bin resolved
    for bin in debmirror blkid lsblk findmnt flock mountpoint curl wipefs mkfs.ext4 mke2fs mkswap udevadm; do
        if resolved=$(resolve_bin "$bin"); then
            log "  ✔ $bin -> $resolved"
        else
            log "  ✘ $bin -> INTROUVABLE"
        fi
    done
    log ""
    log "── Paquets requis ──"
    local pkg status
    for pkg in debmirror rsync gnupg debian-archive-keyring curl e2fsprogs util-linux mount; do
        status=$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print "installé"; found=1} END{if(!found) print "ABSENT"}')
        log "  $pkg : $status"
    done
    log ""
    log "── Disques visibles ──"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | while read -r l; do log "  $l"; done
    log ""
    log "── Swap actif ──"
    awk 'NR>1{print "  " $1}' /proc/swaps 2>/dev/null || log "  aucun"
    log ""
    log "=== Fin du diagnostic — copiez cette sortie si vous demandez de l'aide ==="
}

# =============================================================================
# ÉTAPE 2 — détection et montage du disque
# =============================================================================

# Disques qui portent (directement ou via une partition) le système, tout point
# de montage actif, du swap actif ou des périphériques LVM/crypté : à exclure
# absolument (findmnt ne voit pas le swap, ni les volumes actifs).
system_disk_names() {
    local disks part parent
    disks=""
    # Toutes les partitions montées -> leurs disques parents.
    while read -r part; do
        [[ -n $part ]] || continue
        parent=$(lsblk -no PKNAME "$part" 2>/dev/null || true)
        if [[ -n $parent ]]; then
            disks+=" $parent"
        else
            # fs directement sur le disque (pas de partition)
            disks+=" $(basename "$part")"
        fi
    done < <(findmnt -rno SOURCE | grep '^/dev/' | sort -u)
    # Swap actif -> disques parents.
    while read -r part; do
        [[ -n $part ]] || continue
        parent=$(lsblk -no PKNAME "$part" 2>/dev/null || true)
        [[ -n $parent ]] && disks+=" $parent"
    done < <(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep '^/dev/' | sort -u)
    echo "$disks"
}

# Vrai si le disque est inutilisable pour un miroir : pseudo-périphériques
# (loop, RAM, LVM/device-mapper, RAID logiciel), qui ne sont pas de vrais HDD.
is_virtual_disk() {
    local name="$1"
    [[ $name =~ ^(loop|zram|dm-|md|nvme[0-9]+c) ]] && return 0
    # Toute hiérarchie device-mapper (LVM, LUKS) : disque déjà employé.
    lsblk -rno TYPE "/dev/$name" 2>/dev/null | grep -qE 'crypt|lvm|raid' && return 0
    return 1
}

# Analyse un disque : renvoie "device fstype" si un fs unique utilisable,
# sinon une ligne vide.
probe_disk() {
    local disk="/dev/$1" part count dev fstype
    if fstype=$(blkid -s TYPE -o value "$disk" 2>/dev/null) && [[ -n $fstype ]]; then
        echo "$disk $fstype"
        return
    fi
    # Pas de fs sur le disque entier : accepter uniquement le cas simple
    # d'UNE SEULE partition porteuse d'un filesystem.
    count=0
    while read -r dev; do
        count=$((count + 1))
    done < <(lsblk -rno NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')
    if [[ $count -eq 1 ]]; then
        part=$(lsblk -rno NAME,TYPE "$disk" | awk '$2=="part"{print "/dev/"$1; exit}')
        if fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null) && [[ -n $fstype ]]; then
            echo "$part $fstype"
            return
        fi
    fi
    return
}

detect_disk() {
    local excluded size_bytes best_dev best_fs best_size sz
    local candidates=() sizes=()
    excluded=$(system_disk_names)

    # Candidats = disques (tri du plus grand au plus petit) qui ne portent ni
    # le système ni aucun point de montage, et sur lesquels blkid voit un fs.
    while read -r name size_bytes; do
        [[ -n $name ]] || continue
        if [[ " $excluded " == *" $name "* ]]; then
            continue
        fi
        if is_virtual_disk "$name"; then
            continue
        fi
        local probe
        probe=$(probe_disk "$name") || probe=""
        [[ -z $probe ]] && continue
        candidates+=("$probe")
        sizes+=("$size_bytes")
    done < <(lsblk -drbno NAME,SIZE 2>/dev/null | awk '$2 ~ /^[0-9]+$/')

    if [[ ${#candidates[@]} -eq 0 ]]; then
        # FORMAT_DISK=yes : tente le formatage d'un disque neuf, sous conditions.
        if [[ $FORMAT_DISK == "yes" ]]; then
            format_new_disk
            return
        fi
        cat >&2 <<EOF
ERREUR : aucun disque candidat trouvé.

Il faut un disque (HDD) branché, DÉJÀ FORMATÉ (ext4 ou autre fs reconnu
par blkid), qui ne soit ni le disque système ni déjà monté.

Pour formater un disque NEUF, mettez FORMAT_DISK="yes" en tête du script,
ou formatez-le vous-même :  mkfs.ext4 /dev/sdX

Disques actuellement vus par le système :
$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null)
EOF
        return 1
    fi

    if [[ ${#candidates[@]} -ge 2 ]]; then
        best_size=${sizes[0]}
        sz=${sizes[1]}
        # Deux disques de taille proche (>90 % du plus gros) : on ne devine pas.
        if (( sz * 10 >= best_size * 9 )); then
            {
                echo "ERREUR : plusieurs disques candidats de taille proche, je ne choisis pas à votre place."
                echo ""
                echo "Candidats (périphérique, filesystem, taille en octets) :"
                local i=0
                for i in "${!candidates[@]}"; do
                    echo "  ${candidates[$i]}  (${sizes[$i]} octets)"
                done
                echo ""
                echo "Fixez le disque voulu via DISK_UUID=... en tête du script"
                echo "puis relancez. Vous pouvez obtenir l'UUID via : blkid /dev/sdX"
            } >&2
            return 1
        fi
    fi

    best_dev=${candidates[0]%% *}
    best_fs=${candidates[0]#* }
    if [[ -z $best_dev || -z $best_fs ]]; then
        die "Le disque détecté n'a pas de filesystem reconnu (blkid)."
    fi

    DISK_UUID=$(blkid -s UUID -o value "$best_dev")
    [[ -n $DISK_UUID ]] || die "Impossible de lire l'UUID de $best_dev."

    mkdir -p "$PERSIST_STATE_DIR" 2>/dev/null || true
    echo "$DISK_UUID" >"$STATE_UUID_FILE" 2>/dev/null || true
    log "Disque détecté : $best_dev ($best_fs, UUID $DISK_UUID)"
}

# Formatage sécurisé d'un disque NEUF (appelé uniquement si FORMAT_DISK="yes").
# Vérifications : pas le disque système, pas monté, pas de partitions, pas de
# filesystem existant. En cas de doute sur plusieurs disques vierges, s'arrête.
format_new_disk() {
    local excluded name size_bytes dev count
    local blanks=() sizes=()
    excluded=$(system_disk_names)

    while read -r name size_bytes; do
        [[ -n $name ]] || continue
        if [[ " $excluded " == *" $name "* ]]; then
            continue
        fi
        if is_virtual_disk "$name"; then
            continue
        fi
        local probe fstype
        probe=$(probe_disk "$name" 2>/dev/null) || probe=""
        [[ -n $probe ]] && continue
        # Disque vierge = aucun fs sur le disque ni sur ses partitions.
        fstype=$(blkid -s TYPE -o value "/dev/$name" 2>/dev/null || true)
        [[ -n $fstype ]] && continue
        count=$(lsblk -rno NAME,TYPE "/dev/$name" 2>/dev/null | awk '$2=="part"' | wc -l)
        # Une partition sans fs peut exister sur un disque neuf : on l'effacera
        # via mkfs sur le disque entier, mais on refuse les disques à plusieurs
        # partitions (données potentielles ailleurs).
        if (( count > 1 )); then
            continue
        fi
        blanks+=("$name")
        sizes+=("$size_bytes")
    done < <(lsblk -drbno NAME,SIZE 2>/dev/null | awk '$2 ~ /^[0-9]+$/')

    if [[ ${#blanks[@]} -eq 0 ]]; then
        die "Aucun disque vierge éligible au formatage trouvé (FORMAT_DISK=yes)."
    fi
    if [[ ${#blanks[@]} -ge 2 ]]; then
        if (( sizes[1] * 10 >= sizes[0] * 9 )); then
            {
                echo "ERREUR : plusieurs disques vierges de taille proche, je ne choisis pas à votre place."
                echo ""
                echo "Disques vierges détectés :"
                local i
                for i in "${!blanks[@]}"; do
                    echo "  /dev/${blanks[$i]}  (${sizes[$i]} octets)"
                done
                echo ""
                echo "Formatez manuellement le bon disque (mkfs.ext4 /dev/sdX),"
                echo "ou fixez DISK_UUID après un formatage manuel."
            } >&2
            return 1
        fi
    fi

    dev="/dev/${blanks[0]}"
    log "Disque neuf détecté : $dev (${sizes[0]} octets) — formatage ext4 (FORMAT_DISK=yes)..."
    log "ATTENTION : TOUT le contenu de $dev va être effacé."
    wipefs -a "$dev" >/dev/null 2>&1 || true
    $MKFS_EXT4 -F -L miroir "$dev"
    # Attendre que udev/blkid voient le nouveau filesystem (fréquent en VM :
    # le cache blkid renvoie l'ancienne entrée vide juste après mkfs).
    udevadm settle 2>/dev/null || true
    sleep 2
    DISK_UUID=$(blkid -c /dev/null -s UUID -o value "$dev")
    [[ -n $DISK_UUID ]] || die "Formatage effectué mais UUID illisible sur $dev (blkid ne voit pas le fs — redémarrez et relancez)."
    mkdir -p "$PERSIST_STATE_DIR" 2>/dev/null || true
    echo "$DISK_UUID" >"$STATE_UUID_FILE" 2>/dev/null || true
    log "Disque formaté : $dev (ext4, UUID $DISK_UUID)."
}

ensure_mounted() {
    if mountpoint -q "$MOUNT_POINT"; then
        log "  ✔ Disque déjà monté sur $MOUNT_POINT — rien à faire."
        return
    fi
    if [[ -z $DISK_UUID ]]; then
        # UUID mémorisé d'un lancement précédent ?
        if [[ -r $STATE_UUID_FILE ]]; then
            DISK_UUID=$(cat "$STATE_UUID_FILE")
            log "  ✔ UUID mémorisé réutilisé : $DISK_UUID (fichier $STATE_UUID_FILE)"
        else
            detect_disk || exit 1
        fi
    fi

    local fstype dev
    dev=$(blkid -U "$DISK_UUID" 2>/dev/null) || true
    [[ -n $dev ]] || die "Aucun périphérique avec UUID=$DISK_UUID. Vérifiez que le disque est branché."
    fstype=$(blkid -s TYPE -o value "$dev")
    [[ -n $fstype ]] || die "Le disque $dev n'a pas de filesystem reconnu (blkid). Je ne formate rien — formatez-le puis relancez."

    mkdir -p "$MOUNT_POINT"
    if ! grep -qsE "^[^#]*UUID=$DISK_UUID" "$FSTAB"; then
        echo "UUID=$DISK_UUID $MOUNT_POINT $fstype defaults,nofail 0 2" >>"$FSTAB"
        log "Entrée fstab ajoutée (UUID=$DISK_UUID, $MOUNT_POINT, $fstype, nofail)."
    else
        log "Entrée fstab déjà présente pour UUID=$DISK_UUID."
    fi
    mount "$MOUNT_POINT" || die "Échec du montage de $MOUNT_POINT (voir dmesg)."
    log "  ✔ Disque monté sur $MOUNT_POINT ($(df -h "$MOUNT_POINT" | awk 'NR==2{print $2}') au total, $(df -h "$MOUNT_POINT" | awk 'NR==2{print $4}') libres)."
}

# =============================================================================
# ÉTAPE 3 — arborescence
# =============================================================================
create_layout() {
    log "[3/6] Création de l'arborescence des dépôts..."
    mkdir -p "$MIRROR_ROOT/debian" "$MIRROR_ROOT/debian-security" \
        "$MIRROR_ROOT/pve" "$MIRROR_ROOT/pbs" "$MIRROR_ROOT/pdm" \
        "$MIRROR_ROOT/ceph-squid" "$MIRROR_ROOT/ceph-tentacle"
    local rel
    for rel in $CEPH_RELEASES; do
        mkdir -p "$MIRROR_ROOT/ceph-$rel"
    done
    mkdir -p "$STATE_DIR"
    log "  ✔ Arborescence prête :"
    local _d
    for _d in debian debian-security pve pbs pdm ceph-*; do
        [[ -d $MIRROR_ROOT/$_d ]] && log "      • $MIRROR_ROOT/$_d"
    done
}

# =============================================================================
# ÉTAPE 4 — espace disque
# =============================================================================
check_space() {
    local avail_kb
    avail_kb=$(df -B 1K --output=avail "$MIRROR_ROOT" | tail -1)
    if (( avail_kb < MIN_FREE_GB * 1024 * 1024 )); then
        die "Espace libre insuffisant : $((avail_kb / 1024 / 1024)) Go disponibles, marge requise : ${MIN_FREE_GB} Go. Libérez de l'espace ou ajustez MIN_FREE_GB."
    fi
    log "Espace libre : $((avail_kb / 1024 / 1024)) Go (marge requise ${MIN_FREE_GB} Go) — OK."
}

# =============================================================================
# ÉTAPE 5 — clés GPG
# =============================================================================
setup_keys() {
    log "[5/6] Clés GPG..."
    [[ -r $DEBIAN_KEYRING ]] || die "Keyring Debian introuvable : $DEBIAN_KEYRING (installez debian-archive-keyring)."
    if [[ ! -r $PROXMOX_KEYRING ]]; then
        log "Téléchargement de la clé Proxmox (release-trixie)..."
        curl -fsSL "$PROXMOX_KEY_URL" -o "$PROXMOX_KEYRING"
    fi
    [[ -r $PROXMOX_KEYRING ]] || die "Clé Proxmox introuvable après téléchargement ($PROXMOX_KEYRING)."
    log "Clés prêtes : Debian + Proxmox."
}

# =============================================================================
# ÉTAPE 6 — synchros debmirror
# =============================================================================

# Arguments debmirror communs ; GNUPGHOME pointe vers un répertoire inexistant
# pour que seuls les keyrings explicites (--keyring) soient utilisés.
build_debmirror_opts() {
    DEBMIRROR_BASE_OPTS=(--method=http --arch="$ARCHES" --keyring="$DEBIAN_KEYRING"
        --keyring="$PROXMOX_KEYRING" --progress --postcleanup
        --rsync-extra=none --timeout=600)
    if [[ $INCLUDE_SOURCES == "true" ]]; then
        DEBMIRROR_BASE_OPTS+=(--source)
    else
        DEBMIRROR_BASE_OPTS+=(--nosource)
    fi
}

# Tableau des dépôts : "nom|hôte|root|suites|sections|répertoire cible"
repos_for_group() {
    case ${1:-all} in
    debian)
        echo "debian|$DEBIAN_HOST|$DEBIAN_ROOT|$DEBIAN_SUITES|$DEBIAN_SECTIONS|$MIRROR_ROOT/debian"
        echo "debian-security|$SECURITY_HOST|$SECURITY_ROOT|$SECURITY_SUITES|$DEBIAN_SECTIONS|$MIRROR_ROOT/debian-security"
        ;;
    proxmox)
        echo "pve|$PROXMOX_HOST|debian/pve|$PROXMOX_SUITE|$PVE_COMPONENT|$MIRROR_ROOT/pve"
        echo "pbs|$PROXMOX_HOST|debian/pbs|$PROXMOX_SUITE|$PBS_COMPONENT|$MIRROR_ROOT/pbs"
        echo "pdm|$PROXMOX_HOST|debian/pdm|$PROXMOX_SUITE|$PDM_COMPONENT|$MIRROR_ROOT/pdm"
        ;;
    ceph)
        local rel
        for rel in $CEPH_RELEASES; do
            echo "ceph-$rel|$PROXMOX_HOST|debian/ceph-$rel|$PROXMOX_SUITE|$CEPH_COMPONENT|$MIRROR_ROOT/ceph-$rel"
        done
        ;;
    all)
        repos_for_group debian
        repos_for_group proxmox
        repos_for_group ceph
        ;;
    *) die "Groupe inconnu : '$1'. Attendu : debian|proxmox|ceph|all." ;;
    esac
}

human_size() {
    local mb=$1
    if ((mb >= 1024)); then
        echo "$((mb / 1024)) Go"
    else
        echo "$mb Mo"
    fi
}

# Formate une durée en secondes : "1h52m10s".
human_duration() {
    local s=$1 hh mm ss
    hh=$((s / 3600)); mm=$(((s % 3600) / 60)); ss=$((s % 60))
    if ((hh > 0)); then
        echo "${hh}h${mm}m${ss}s"
    elif ((mm > 0)); then
        echo "${mm}m${ss}s"
    else
        echo "${ss}s"
    fi
}

# Débit moyen : Mo / durée. Renvoie "-" si rien à télécharger.
human_speed() {
    local mb=$1 sec=$2
    (( sec > 0 )) || { echo "-"; return; }
    local mbps=$((mb / sec))
    if ((mbps >= 1024)); then
        echo "$((mbps / 1024)) Go/s"
    else
        echo "${mbps} Mo/s"
    fi
}

# Estime le temps restant à partir de la durée moyenne des dépôts traités.
estimate_remaining() {
    (( REPO_INDEX > 0 )) || return 0
    local avg remaining
    avg=$((ELAPSED_REPO_SECONDS / REPO_INDEX))
    remaining=$((avg * (REPO_TOTAL - REPO_INDEX)))
    human_duration "$remaining"
}

# Synchro d'un dépôt avec retries exponentiels. Variables de rapport :
# REPORT_NAME/REPORT_STATUS/REPORT_MB/REPORT_SEC/REPORT_ATTEMPTS.
sync_repo() {
    local name="$1" host="$2" root="$3" suites="$4" sections="$5" target="$6"
    local dry="${7:-false}"
    local attempt=0 delay=$RETRY_DELAY rc=0 before_mb after_mb t0 t1
    local extra=()
    [[ $dry == "true" ]] && extra=(--dry-run)

    mkdir -p "$target"
    before_mb=$(du -sm "$target" 2>/dev/null | awk '{print $1}')
    t0=$(date +%s)

    while ((attempt < MAX_RETRIES)); do
        attempt=$((attempt + 1))
        log "▶ [$name] tentative $attempt/$MAX_RETRIES — synchronisation en cours, patientez..."
        log "  (sortie debmirror en direct ci-dessous ; aussi dans : $log_capture)"
        # Lancement de debmirror en arrière-plan avec moniteur de progression :
        # - stdbuf --output=L : line-buffering, sinon Perl bufferise et rien
        #   ne s'affiche pendant des heures dans le pipe tee ;
        # - un écho périodique (toutes les 60 s) du volume écrit et du débit
        #   instantané du dépôt en cours.
        (
            GNUPGHOME="$MIRROR_ROOT/.gnupg-empty" stdbuf --output=L --error=L \
                debmirror "${DEBMIRROR_BASE_OPTS[@]}" \
                --host="$host" --root="$root" --dist="$suites" --section="$sections" \
                "${extra[@]}" "$target" >>"$log_capture" 2>&1
            echo $? >"$log_capture.rc"
        ) &
        local dm_pid=$!
        local last_mb=0 cur_mb delta rate
        while kill -0 "$dm_pid" 2>/dev/null; do
            sleep 60
            kill -0 "$dm_pid" 2>/dev/null || break
            cur_mb=$(du -sm "$target" 2>/dev/null | awk '{print $1}')
            cur_mb=${cur_mb:-0}
            delta=$((cur_mb - last_mb))
            rate=$((delta / 60))
            printf '%s 💿 [%s] en cours : %s Mo écrits dans ce dépôt (+%s Mo/min ≈ %s Mo/s)\n' \
                "$(date '+%H:%M:%S')" "$name" "$cur_mb" "$delta" "$rate"
            last_mb=$cur_mb
        done
        wait "$dm_pid" 2>/dev/null || true
        rc=$(cat "$log_capture.rc" 2>/dev/null || echo 1)
        rm -f "$log_capture.rc"
        if (( rc == 0 )); then
            break
        fi
        log "✘ [$name] échec de la tentative $attempt (code $rc)."
        if ((attempt < MAX_RETRIES)); then
            log "  nouvelle tentative dans ${delay}s (délai exponentiel)..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    t1=$(date +%s)
    after_mb=$(du -sm "$target" 2>/dev/null | awk '{print $1}')
    REPORT_NAME="$name"
    REPORT_ATTEMPTS=$attempt
    if [[ $rc -eq 0 ]]; then
        if [[ $dry != "true" ]]; then
            date -Is >"$STATE_DIR/$name.lastsync"
        fi
        REPORT_STATUS="OK"
    else
        REPORT_STATUS="ÉCHEC (code $rc)"
    fi
    REPORT_MB=$((after_mb - before_mb))
    if ((REPORT_MB < 0)); then REPORT_MB=0; fi
    REPORT_SEC=$((t1 - t0))
    ELAPSED_REPO_SECONDS=$((ELAPSED_REPO_SECONDS + REPORT_SEC))
    ELAPSED_REPO_MB=$((ELAPSED_REPO_MB + REPORT_MB))
    return 0 # le rapport final gère les échecs, on ne casse pas set -e
}

# Exécute un groupe de dépôts et imprime le rapport.
run_group() {
    local group="$1" dry="$2" line
    local failed=0
    while read -r line; do
        [[ -z $line ]] && continue
        IFS='|' read -r name host root suites sections target <<<"$line"
        REPO_INDEX=$((REPO_INDEX + 1))
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "▶ DÉPÔT $REPO_INDEX/$REPO_TOTAL : $name"
        log "   cible   : $target"
        log "   source  : http://$host/$root"
        log "   suites  : $suites"
        log "   sections: $sections"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        sync_repo "$name" "$host" "$root" "$suites" "$sections" "$target" "$dry"
        if [[ $REPORT_STATUS == "OK" ]]; then
            log "✔ [$REPORT_NAME] terminé — $(human_size "$REPORT_MB") ajoutés en $(human_duration "$REPORT_SEC") (débit moyen : $(human_speed "$REPORT_MB" "$REPORT_SEC"))."
            log "  Taille actuelle du miroir : $(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}') — restant : $((REPO_TOTAL - REPO_INDEX)) dépôt(s)."
            local remaining
            remaining=$(estimate_remaining)
            [[ -n $remaining ]] && log "  ⏳ Temps restant estimé : $remaining (moyenne : $(human_duration $((ELAPSED_REPO_SECONDS / REPO_INDEX))) par dépôt, débit global : $(human_speed "$ELAPSED_REPO_MB" "$ELAPSED_REPO_SECONDS"))."
        else
            log "✘ [$REPORT_NAME] ÉCHEC après ${REPORT_ATTEMPTS} tentative(s) — les autres dépôts continuent."
            failed=1
            FAILED_REPOS+=("$REPORT_NAME")
        fi
    done < <(repos_for_group "$group")
    return $failed
}

log_capture="/tmp/mirror-debmirror-$$.log"

# =============================================================================
# COMMANDES
# =============================================================================

cmd_bootstrap_and_sync() {
    local groups="${1:-all}" dry="${2:-false}"
    log ""
    log "═════════════════════════════════════════════════════════════════════════"
    log "  mirror.sh v$VERSION — $(date -Is)"
    log "  Mode : $([[ $dry == "true" ]] && echo "DRY-RUN (estimation, sans écriture)" || echo "SYNCHRONISATION COMPLÈTE")"
    log "═════════════════════════════════════════════════════════════════════════"
    log ""
    log "[1/6] Vérification des dépendances..."
    install_deps
    log "[2/6] Détection et montage du disque..."
    ensure_mounted
    init_log
    trap on_interrupt INT TERM
    log "[3/6] Création de l'arborescence des dépôts..."
    create_layout
    log "[4/6] Vérification de l'espace disque..."
    check_space
    log "[5/6] Clés GPG..."
    setup_keys
    build_debmirror_opts
    # Comptage des dépôts pour la progression.
    REPO_TOTAL=$(repos_for_group "$groups" | wc -l)
    REPO_INDEX=0
    log "[6/6] Synchronisation — $REPO_TOTAL dépôt(s) à traiter."
    FAILED_REPOS=()
    local global_rc=0
    local g
    if [[ $groups == "all" ]]; then
        for g in debian proxmox ceph; do
            run_group "$g" "$dry" || global_rc=1
        done
    else
        run_group "$groups" "$dry" || global_rc=1
    fi
    final_report "$dry"
    exit "$global_rc"
}

final_report() {
    local dry="$1"
    local total=$(( $(date +%s) - START_TS ))
    local hh=$((total / 3600)) mm=$(((total % 3600) / 60)) ss=$((total % 60))
    local ok_count=$((REPO_TOTAL - ${#FAILED_REPOS[@]}))
    log ""
    log "═════════════════════════════════════════════════════════════════════════"
    log "  RAPPORT FINAL"
    log "═════════════════════════════════════════════════════════════════════════"
    if [[ $dry == "true" ]]; then
        log "  Mode            : DRY-RUN (aucun paquet téléchargé)"
    fi
    log "  Dépôts OK       : $ok_count/$REPO_TOTAL"
    if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
        log "  Dépôts en échec : ${FAILED_REPOS[*]}"
    fi
    log "  Temps sync      : $(human_duration "$ELAPSED_REPO_SECONDS")"
    log "  Volume sync     : $(human_size "$ELAPSED_REPO_MB") — débit moyen : $(human_speed "$ELAPSED_REPO_MB" "$ELAPSED_REPO_SECONDS")"
    log "  Durée totale    : ${hh}h${mm}m${ss}s"
    log "  Espace utilisé  : $(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}') sur $MIRROR_ROOT"
    log "  Espace libre    : $(df -h "$MIRROR_ROOT" | awk 'NR==2{print $4}')"
    log "  Log détaillé    : $LOG_FILE"
    log "═════════════════════════════════════════════════════════════════════════"
    if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
        log "  Code de sortie : 1 — relancez « ./mirror.sh sync » pour réessayer les dépôts en échec."
    else
        log "  Code de sortie : 0 — tout est en ordre. Prochain sync : ./mirror.sh sync all"
    fi
    log "═════════════════════════════════════════════════════════════════════════"
}

cmd_status() {
    ensure_mounted
    local d f
    printf '%-18s %-12s %-22s %s\n' "DÉPÔT" "TAILLE" "DERNIÈRE SYNCHRO" "CHEMIN"
    for d in debian debian-security pve pbs pdm; do
        f="$STATE_DIR/$d.lastsync"
        printf '%-18s %-12s %-22s %s\n' "$d" \
            "$(du -sh "$MIRROR_ROOT/$d" 2>/dev/null | awk '{print $1}' || echo '-') " \
            "$([[ -r $f ]] && cat "$f" || echo 'jamais')" \
            "$MIRROR_ROOT/$d"
    done
    local rel
    for rel in $CEPH_RELEASES; do
        f="$STATE_DIR/ceph-$rel.lastsync"
        printf '%-18s %-12s %-22s %s\n' "ceph-$rel" \
            "$(du -sh "$MIRROR_ROOT/ceph-$rel" 2>/dev/null | awk '{print $1}' || echo '-')" \
            "$([[ -r $f ]] && cat "$f" || echo 'jamais')" \
            "$MIRROR_ROOT/ceph-$rel"
    done
    printf '%-18s %-12s\n' "TOTAL" "$(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
    printf 'Libre : %s\n' "$(df -h "$MIRROR_ROOT" | awk 'NR==2{print $4}')"
}

cmd_unmount() {
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" || die "Démontage impossible : périphérique occupé (lsof / fuser pour identifier)."
        log "Disque démonté de $MOUNT_POINT."
    else
        log "Aucun disque monté sur $MOUNT_POINT."
    fi
}

main() {
    local cmd="${1:-bootstrap}" arg="${2:-all}"
    case $cmd in
    bootstrap | sync | dry-run)
        # relance en root si nécessaire
        if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
            exec sudo "$0" "$@"
        fi
        ;;
    esac

    acquire_lock
    case $cmd in
    bootstrap) cmd_bootstrap_and_sync "$arg" "false" ;;
    sync) cmd_bootstrap_and_sync "$arg" "false" ;;
    dry-run) cmd_bootstrap_and_sync "$arg" "true" ;;
    status)
        if [[ ${EUID:-$(id -u)} -ne 0 ]]; then exec sudo "$0" "$@"; fi
        acquire_lock
        cmd_status
        ;;
    unmount)
        if [[ ${EUID:-$(id -u)} -ne 0 ]]; then exec sudo "$0" "$@"; fi
        cmd_unmount
        ;;
    doctor)
        if [[ ${EUID:-$(id -u)} -ne 0 ]]; then exec sudo "$0" "$@"; fi
        cmd_doctor
        ;;
    -h | --help | help) usage ;;
    *) usage ;;
    esac
    rm -f "$log_capture"
}

main "$@"

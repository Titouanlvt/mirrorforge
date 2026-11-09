#!/usr/bin/env bash
#
# depot.sh — Serveur de dépôt offline (RedHat Enterprise Linux 10) pour le
# disque miroir créé par mirror.sh.
#
# Usage :
#   sudo ./depot.sh setup     # monte le disque miroir, installe le service,
#                             # ouvre le pare-feu, démarre le serveur HTTP
#   sudo ./depot.sh status    # santé : service, dépôts servis, tailles
#   sudo ./depot.sh unmount   # arrête le service et démonte tout
#
# Zéro installation : si httpd (Apache) est déjà présent il est utilisé,
# sinon le serveur HTTP intégré de Python 3 (présent sur toute install
# RHEL 10, dnf en dépend) sert le miroir via une unit systemd sandboxée.
#
# Sécurité :
#   - la racine servie (/srv/miroir) ne contient QUE les dépôts, jamais
#     mirror-logs/ ni .mirror-state/ (bind-mounts en lecture seule) ;
#   - unit systemd durcie : utilisateur jetable, filesystem ro, aucune
#     capability, syscalls filtrés ;
#   - firewalld : le port n'est ouvert QUE vers les subnets/IP clients ;
#   - intégrité de bout en bout : les clients vérifient les signatures GPG
#     des fichiers Release (apt sur Proxmox, pkg sur OPNsense).

set -euo pipefail

# PATH complet et déterministe (cf. mirror.sh).
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# =============================================================================
# BLOC DE CONFIGURATION — tout est réglable ici, aucun fichier externe requis
# =============================================================================

# UUID du disque miroir (celui mémorisé par mirror.sh sur la machine de
# synchro). Laissez vide pour la détection automatique : le script cherche un
# disque au fs autorisé qui CONTIENT un miroir (répertoires debian/, .mirror-state/).
DISK_UUID=""

# Point de montage du disque miroir (même valeur que dans mirror.sh).
MOUNT_POINT="/mnt/miroir"

# Racine SERVIE par le serveur HTTP : ne contient que les dépôts, en lecture
# seule (bind-mounts). Les logs et l'état du disque ne sont JAMAIS servis.
SERVE_ROOT="/srv/miroir"

# Adresse et port d'écoute. Le pare-feu filtre : seuls CLIENT_SUBNETS passent.
LISTEN_ADDR="0.0.0.0"
LISTEN_PORT="80"

# Subnets/IP autorisés à interroger le serveur (séparés par espaces).
# Ex. : "192.168.10.0/24 192.168.20.5"
CLIENT_SUBNETS="192.168.1.0/24"

# Nom de l'unit systemd du serveur HTTP.
SERVICE_NAME="miroir-serve"

# Dépôts à servir (doivent exister sur le disque ; les absents sont ignorés
# avec un avertissement). Ordre = ordre d'affichage du status.
SERVED_REPOS="debian debian-security pve pbs pdm ceph-squid ceph-tentacle opnsense"

# Filesystems acceptés pour le disque miroir (même liste que mirror.sh).
ALLOWED_FILESYSTEMS="ext2 ext3 ext4 xfs btrfs f2fs"

# =============================================================================
# FIN DU BLOC DE CONFIGURATION
# =============================================================================

VERSION="1.0.0"
FSTAB="/etc/fstab"
LOCK_FILE="/run/lock/depot.sh.lock"
LOG_FILE="/var/log/depot-setup-$(date +%Y%m%d-%H%M%S).log"
BACKEND=""

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
depot.sh v$VERSION — serveur de dépôt offline (RHEL 10) pour le disque mirror.sh

Usage :
  sudo ./depot.sh setup     monte le disque, crée le service, ouvre le pare-feu
  sudo ./depot.sh status    santé du service + dépôts servis
  sudo ./depot.sh import <chemin>   copie le miroir d'un disque externe
                                      de transport vers $MOUNT_POINT
  sudo ./depot.sh unmount   arrête le service et démonte tout
EOF
    exit 2
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        die "Une autre instance de depot.sh tourne déjà (verrou $LOCK_FILE)."
    fi
}

# Fichier de log de setup (console + /var/log, via tee).
init_log() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Log : $LOG_FILE"
}

# --- détection disque (même logique prudente que mirror.sh) ----------------

fs_allowed() {
    local fstype="$1" fs
    [[ -z $fstype ]] && return 1
    for fs in $ALLOWED_FILESYSTEMS; do
        [[ $fstype == "$fs" ]] && return 0
    done
    return 1
}

system_disk_names() {
    local disks part parent
    disks=""
    while read -r part; do
        [[ -n $part ]] || continue
        parent=$(lsblk -no PKNAME "$part" 2>/dev/null || true)
        if [[ -n $parent ]]; then
            disks+=" $parent"
        else
            disks+=" $(basename "$part")"
        fi
    done < <(findmnt -rno SOURCE | grep '^/dev/' | sort -u)
    while read -r part; do
        [[ -n $part ]] || continue
        parent=$(lsblk -no PKNAME "$part" 2>/dev/null || true)
        if [[ -n $parent ]]; then
            disks+=" $parent"
        fi
    done < <(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep '^/dev/' | sort -u)
    echo "$disks"
}

is_virtual_disk() {
    local name="$1"
    [[ $name =~ ^(loop|zram|dm-|md|nvme[0-9]+c) ]] && return 0
    lsblk -rno TYPE "/dev/$name" 2>/dev/null | grep -qE 'crypt|lvm|raid' && return 0
    return 1
}

# Cherche UN disque au fs autorisé, non système, non monté, qui CONTIENT un
# miroir (vérifié par montage temporaire en lecture seule : .mirror-state ou
# debian/ présents). Refuse tout si plusieurs candidats.
detect_mirror_disk() {
    local excluded name dev fstype probe_dir
    local candidates=()
    excluded=$(system_disk_names)
    while read -r name _; do
        [[ -n $name ]] || continue
        if [[ " $excluded " == *" $name "* ]]; then
            continue
        fi
        if is_virtual_disk "$name"; then
            continue
        fi
        dev="/dev/$name"
        if fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null) && fs_allowed "$fstype"; then
            candidates+=("$dev|$fstype")
        fi
    done < <(lsblk -drbno NAME,SIZE 2>/dev/null | awk '$2 ~ /^[0-9]+$/')

    if [[ ${#candidates[@]} -eq 0 ]]; then
        die "Aucun disque miroir trouvé. Branchez le disque synchronisé par mirror.sh (fs : ${ALLOWED_FILESYSTEMS// /, })."
    fi
    if [[ ${#candidates[@]} -ge 2 ]]; then
        {
            echo "ERREUR : plusieurs disques candidats, je ne choisis pas à votre place :"
            local c
            for c in "${candidates[@]}"; do
                echo "  ${c%%|*} (fs ${c#*|})"
            done
            echo "Fixez DISK_UUID en tête de script (blkid /dev/sdX)."
        } >&2
        return 1
    fi

    # Vérification du contenu : le disque doit ÊTRE un miroir mirror.sh.
    dev="${candidates[0]%%|*}"
    probe_dir=$(mktemp -d /tmp/depot-probe.XXXXXX)
    if ! mount -o ro "$dev" "$probe_dir" 2>/dev/null; then
        rm -rf "$probe_dir"
        die "Impossible de monter $dev en lecture seule pour vérification."
    fi
    if [[ ! -d $probe_dir/debian && ! -d $probe_dir/.mirror-state ]]; then
        umount "$probe_dir"
        rm -rf "$probe_dir"
        die "$dev ne contient pas de miroir (ni debian/ ni .mirror-state/). Ce n'est pas un disque créé par mirror.sh — refus."
    fi
    umount "$probe_dir"
    rm -rf "$probe_dir"
    DISK_UUID=$(blkid -s UUID -o value "$dev")
    [[ -n $DISK_UUID ]] || die "UUID illisible sur $dev."
    log "Disque miroir détecté : $dev (UUID $DISK_UUID)."
}

ensure_mounted() {
    if mountpoint -q "$MOUNT_POINT"; then
        log "  ✔ Disque déjà monté sur $MOUNT_POINT."
        return
    fi
    # Mode « miroir local » : le contenu a été livré par rsync/scp dans un
    # répertoire du serveur (pas de disque à monter). On vérifie que c'est
    # bien un miroir mirror.sh avant de le servir.
    if [[ -d $MOUNT_POINT/debian || -d $MOUNT_POINT/.mirror-state ]]; then
        log "  ✔ Miroir local présent dans $MOUNT_POINT (livré par rsync/scp) — pas de disque à monter."
        return
    fi
    if [[ -z $DISK_UUID ]]; then
        detect_mirror_disk
    fi
    local dev fstype
    dev=$(blkid -U "$DISK_UUID" 2>/dev/null) || true
    [[ -n $dev ]] || die "Aucun périphérique avec UUID=$DISK_UUID — le disque est-il branché ?"
    fstype=$(blkid -s TYPE -o value "$dev")
    fs_allowed "$fstype" || die "Le disque $dev est en $fstype (non autorisé : ${ALLOWED_FILESYSTEMS// /, })."
    mkdir -p "$MOUNT_POINT"
    if ! grep -qsE "^[^#]*UUID=${DISK_UUID}[[:space:]]+${MOUNT_POINT}([[:space:]]|$)" "$FSTAB"; then
        echo "UUID=$DISK_UUID $MOUNT_POINT $fstype defaults,nofail,ro 0 2" >>"$FSTAB"
        log "  Entrée fstab ajoutée (UUID=$DISK_UUID, $MOUNT_POINT, $fstype, ro, nofail)."
    fi
    mount "$MOUNT_POINT" || die "Échec du montage de $MOUNT_POINT (voir dmesg)."
    log "  ✔ Disque monté sur $MOUNT_POINT (lecture seule)."
}

# --- racine servie : bind-mounts ro des seuls dépôts --------------------------

create_serve_root() {
    local repo
    mkdir -p "$SERVE_ROOT"
    for repo in $SERVED_REPOS; do
        if [[ ! -d $MOUNT_POINT/$repo ]]; then
            log "  ⚠ $repo absent du disque miroir — non servi."
            continue
        fi
        mkdir -p "$SERVE_ROOT/$repo"
        if mountpoint -q "$SERVE_ROOT/$repo"; then
            log "  ✔ $repo déjà bind-mounté."
            continue
        fi
        if ! grep -qsE "^[^#]*[[:space:]]${SERVE_ROOT}/${repo}([[:space:]]|$)" "$FSTAB"; then
            echo "$MOUNT_POINT/$repo $SERVE_ROOT/$repo none bind,ro 0 0" >>"$FSTAB"
        fi
        mount --bind "$MOUNT_POINT/$repo" "$SERVE_ROOT/$repo"
        mount -o remount,ro "$SERVE_ROOT/$repo"
        log "  ✔ $repo servi sur $SERVE_ROOT/$repo (lecture seule)."
    done
}

# --- backend HTTP : httpd si présent, sinon Python sandboxé -----------------

choose_backend() {
    if command -v httpd >/dev/null 2>&1; then
        BACKEND="httpd"
        log "  Backend : httpd (Apache, déjà installé)."
    elif command -v python3 >/dev/null 2>&1; then
        BACKEND="python"
        log "  Backend : python3 http.server (zéro installation)."
    else
        die "Ni httpd ni python3 présents — impossible de servir le miroir."
    fi
}

write_python_unit() {
    cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
# Généré par depot.sh v$VERSION — serveur HTTP du miroir offline.
# Sandbox maximal : utilisateur jetable, fs ro, aucune capability.
[Unit]
Description=Serveur de dépôt offline (miroir mirror.sh)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server ${LISTEN_PORT} --bind ${LISTEN_ADDR} --directory ${SERVE_ROOT}
Restart=on-failure
RestartSec=5
# --- sandbox ---
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryDenyWriteExecute=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
ReadWritePaths=

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log "  ✔ Unit systemd écrite : ${SERVICE_NAME}.service (sandboxée)."
}

write_httpd_conf() {
    cat >"/etc/httpd/conf.d/miroir.conf" <<EOF
# Généré par depot.sh v$VERSION — serveur HTTP du miroir offline.
Listen ${LISTEN_PORT}
<VirtualHost ${LISTEN_ADDR}:${LISTEN_PORT}>
    DocumentRoot ${SERVE_ROOT}
    <Directory ${SERVE_ROOT}>
        Options +Indexes +FollowSymLinks
        Require all granted
    </Directory>
</VirtualHost>
EOF
    # SELinux : labelliser la racine servie (RHEL enforcing par défaut).
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_content_t "${SERVE_ROOT}(/.*)?" 2>/dev/null || true
        restorecon -R "$SERVE_ROOT" 2>/dev/null || true
        log "  ✔ Contexte SELinux httpd_sys_content_t appliqué à $SERVE_ROOT."
    else
        log "  ⚠ semanage absent — vérifiez manuellement le contexte SELinux de $SERVE_ROOT."
    fi
    log "  ✔ Configuration httpd écrite : /etc/httpd/conf.d/miroir.conf."
}

setup_firewall() {
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        log "  ⚠ firewalld inactif — aucune règle ajoutée (LAN isolé : à votre discrétion)."
        return
    fi
    local subnet
    for subnet in $CLIENT_SUBNETS; do
        firewall-cmd --permanent \
            --add-rich-rule="rule family=ipv4 source address=${subnet} port port=${LISTEN_PORT} protocol=tcp accept" \
            >/dev/null
        log "  ✔ Pare-feu : port ${LISTEN_PORT} ouvert pour ${subnet}."
    done
    firewall-cmd --reload >/dev/null
}

start_service() {
    systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}.service"
    sleep 1
    if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        die "Le service ${SERVICE_NAME} ne démarre pas — voir : journalctl -u ${SERVICE_NAME} -e"
    fi
    log "  ✔ Service ${SERVICE_NAME} actif et activé au boot."
}

# --- commandes ----------------------------------------------------------------

cmd_setup() {
    log "═════════════════════════════════════════════════════════"
    log "  depot.sh v$VERSION — mise en place du serveur de dépôt"
    log "═════════════════════════════════════════════════════════"
    init_log
    log "[1/5] Montage du disque miroir..."
    ensure_mounted
    log "[2/5] Racine servie (dépôts seuls, lecture seule)..."
    create_serve_root
    log "[3/5] Backend HTTP..."
    choose_backend
    if [[ $BACKEND == "httpd" ]]; then
        write_httpd_conf
        SERVICE_NAME="httpd"
    else
        write_python_unit
    fi
    log "[4/5] Pare-feu..."
    setup_firewall
    log "[5/5] Démarrage du service..."
    start_service
    log ""
    log "═════════════════════════════════════════════════════════"
    log "  RAPPORT : serveur de dépôt OPÉRATIONNEL"
    log "  URL de base : http://<ip-de-ce-serveur>:${LISTEN_PORT}/"
    log "  Dépôts servis :"
    local repo
    for repo in $SERVED_REPOS; do
        if mountpoint -q "$SERVE_ROOT/$repo" 2>/dev/null || [[ -d $SERVE_ROOT/$repo ]]; then
            log "    • /$repo  ($(du -sh "$SERVE_ROOT/$repo" 2>/dev/null | awk '{print $1}'))"
        fi
    done
    log "  Exemple client Proxmox :"
    log "    deb http://<ip>:${LISTEN_PORT}/debian trixie main contrib non-free non-free-firmware"
    log "═════════════════════════════════════════════════════════"
}

cmd_status() {
    log "── Service ──"
    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        log "  ✔ ${SERVICE_NAME} actif (backend : ${BACKEND:-inconnu})"
    else
        log "  ✘ ${SERVICE_NAME} INACTIF — lancez « sudo ./depot.sh setup »"
    fi
    # Miroir présent ? (disque monté OU répertoire local livré par rsync/scp)
    if ! mountpoint -q "$MOUNT_POINT" && [[ ! -d $MOUNT_POINT/debian && ! -d $MOUNT_POINT/.mirror-state ]]; then
        log "  ✘ miroir introuvable sur $MOUNT_POINT (ni disque monté, ni contenu local)"
        return 1
    fi
    log ""
    log "── Dépôts servis (HTTP ${LISTEN_PORT}) ──"
    local repo code
    for repo in $SERVED_REPOS; do
        if [[ ! -d $SERVE_ROOT/$repo ]]; then
            log "  ✘ $repo : non servi (absent du disque)"
            continue
        fi
        code=$(curl -fsS -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${LISTEN_PORT}/${repo}/" 2>/dev/null || echo "000")
        if [[ $code == "200" ]]; then
            log "  ✔ $repo : HTTP 200 — $(du -sh "$SERVE_ROOT/$repo" 2>/dev/null | awk '{print $1}')"
        else
            log "  ✘ $repo : HTTP $code"
        fi
    done
    log ""
    log "  Libre sur le disque : $(df -h "$MOUNT_POINT" | awk 'NR==2{print $4}')"
}

# Import du miroir depuis un disque externe de transport (copie INCRÉMENTALE
# par rsync dans $MOUNT_POINT du serveur). Usage : depot.sh import <chemin>
# où <chemin> = le répertoire du disque externe contenant le miroir
# (ex. /run/media/admin/miroir).
cmd_import() {
    local src="$1"
    if [[ -z $src ]]; then
        die "Usage : sudo ./depot.sh import <chemin du disque externe> (ex. /run/media/admin/miroir)"
    fi
    [[ -d $src ]] || die "$src n'existe pas — le disque externe est-il monté ?"
    # Le contenu source doit être un miroir mirror.sh.
    if [[ ! -d $src/debian && ! -d $src/.mirror-state ]]; then
        die "$src ne contient pas de miroir (ni debian/ ni .mirror-state/). Ce n'est pas une copie de mirror.sh — refus."
    fi
    mkdir -p "$MOUNT_POINT"
    # Espace libre : marge de 10 Go en plus de la taille du miroir source.
    local src_gb avail_gb
    src_gb=$(du -sBG "$src" 2>/dev/null | awk '{gsub("G","",$1); print $1}')
    avail_gb=$(df -BG --output=avail "$MOUNT_POINT" | tail -1 | tr -dc '0-9')
    if (( avail_gb < src_gb + 10 )); then
        die "Espace insuffisant sur $MOUNT_POINT : $avail_gb Go libres, il faut ~$((src_gb + 10)) Go (miroir $src_gb Go + marge 10 Go)."
    fi
    log "Import du miroir depuis $src vers $MOUNT_POINT (rsync incrémental)..."
    log "  Seuls les fichiers nouveaux/modifiés seront copiés — les mises à jour suivantes seront rapides."
    if ! rsync -aH --delete --info=progress2 --exclude mirror-logs \
        "$src/" "$MOUNT_POINT/"; then
        die "rsync a échoué — ci-dessus l'erreur réelle. L'état précédent de $MOUNT_POINT est préservé."
    fi
    log "  ✔ Import terminé : $(du -sh "$MOUNT_POINT" 2>/dev/null | awk '{print $1}') dans $MOUNT_POINT."
    log "Prochaine étape : sudo ./depot.sh setup  (première fois) puis sudo ./depot.sh status."
}

cmd_unmount() {
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    local repo
    for repo in $SERVED_REPOS; do
        if mountpoint -q "$SERVE_ROOT/$repo"; then
            umount "$SERVE_ROOT/$repo" && log "  ✔ $repo démonté de $SERVE_ROOT"
        fi
    done
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" && log "  ✔ Disque démonté de $MOUNT_POINT"
    else
        log "  Aucun disque monté sur $MOUNT_POINT."
    fi
}

main() {
    local cmd="${1:-}"
    case $cmd in
    setup | status | import | unmount)
        if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
            exec sudo "$0" "$@"
        fi
        ;;
    esac
    acquire_lock
    case $cmd in
    setup) cmd_setup ;;
    status) cmd_status ;;
    import) shift; cmd_import "${1:-}" ;;
    unmount) cmd_unmount ;;
    -h | --help | help | "") usage ;;
    *) usage ;;
    esac
}

main "$@"

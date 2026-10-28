# NOTES FOR AI — Documentation interne de mirror.sh

> Ce fichier s'adresse à toute IA (ou développeur) qui reprend le projet
> `mirrorforge`. Il décrit l'architecture, les invariants critiques et les
> pièges à connaître AVANT de modifier `mirror.sh`.

## Vue d'ensemble

`mirror.sh` est un script Bash unique, autonome (~700 lignes), qui miroite 7
dépôts APT sur un disque HDD local. Cible : Debian 13 (trixie) fraîchement
installée. Aucun fichier de configuration externe : tout se règle dans le bloc
de variables en tête de script (lignes ~30-100).

## Architecture du code

Ordre d'exécution du cas principal (`main` → `cmd_bootstrap_and_sync`) :

1. `require_root` / relance sudo
2. `acquire_lock` — flock sur `/run/lock/mirror.sh.lock`
3. `install_deps` — debmirror, rsync, gnupg, debian-archive-keyring, curl
4. `ensure_mounted` — détection/montage du disque (voir § Disque)
5. `init_log` — redirige stdout/stderr via `tee` vers le log sur le disque
6. `create_layout` — arborescence des 7 dépôts
7. `check_space` — marge libre ≥ `MIN_FREE_GB`
8. `setup_keys` — keyring Debian (paquet) + clé Proxmox (téléchargée)
9. `build_debmirror_opts` — tableau `DEBMIRROR_BASE_OPTS` (commun)
10. `run_group` → boucle sur `repos_for_group` → `sync_repo` par dépôt
11. `final_report` — statistiques + code de sortie

### Format des définitions de dépôts

`repos_for_group` émet des lignes pipe-séparées :
`nom|hôte|root|suites|sections|chemin_cible`
Parsées par `run_group` via `IFS='|' read`. Ajouter un dépôt = ajouter une
ligne + éventuellement le répertoire dans `create_layout` (les releases Ceph
sont déjà bouclées automatiquement via `CEPH_RELEASES`).

## Invariants critiques (NE JAMAIS CASSER)

1. **Le script ne formate que sous conditions explicites.** `format_new_disk`
   n'est appelée QUE si `FORMAT_DISK="yes"` ET qu'aucun disque formaté
   candidat n'existe. Un disque est éligible au formatage uniquement s'il :
   - n'est pas dans `system_disk_names` (système/monté/swap),
   - n'est pas un périphérique virtuel (`is_virtual_disk` : loop, zram, dm-,
     md, crypt, lvm, raid),
   - n'a aucun filesystem blkid,
   - a au plus UNE partition.
2. **Jamais de devine entre candidats.** Plusieurs disques (formatés ou
   vierges) de taille proche (≥ 90 % du plus grand) → liste + `return 1`.
3. **fstab idempotent** : `grep -qsE "^[^#]*UUID=..."` avant ajout, montage
   par point de montage (pas par device).
4. **`set -euo pipefail` partout**, MAIS `sync_repo` finit par `return 0` :
   l'échec d'un dépôt est volontairement non-fatal, il est capturé dans
   `FAILED_REPOS` et le code d'erreur global est porté par `run_group`.
5. **L'état UUID vit dans `/var/lib/mirror-sh/disk.uuid`** (PERSIST_STATE_DIR),
   PAS sur le disque miroir : il doit être lisible avant montage. Les
   horodatages de synchro (`*.lastsync`) vivent dans `STATE_DIR` sur le
   disque miroir.
6. **debmirror est lancé avec `GNUPGHOME="$MIRROR_ROOT/.gnupg-empty"`**
   (chemin inexistant) pour que seuls les keyrings passés via `--keyring`
   (Debian + Proxmox) soient utilisés. `--keyring` est répétable (vérifié
   dans le source debmirror). Les Release sont vérifiées (check-gpg par défaut).
7. **Interrompu = safe.** `trap on_interrupt INT TERM` ; debmirror utilise
   un fichier `Archive-Update-in-Progress-*` et ne remplace les métadonnées
   qu'à la fin : un sync interrompu laisse un miroir consistent au dernier
   état complet.

## Détails contre-intuitifs

- `lsblk -drbno NAME,SIZE` trie par taille décroissante : candidates[0] est
  TOUJOURS le plus grand disque. La comparaison d'ambiguïté ne regarde que
  sizes[0] vs sizes[1].
- `probe_disk` accepte un fs sur le disque ENTIER ou sur une partition
  unique. `$(...)` de commande sous `set -e` : les échecs blkid sont neutralisés
  par `|| true` / `|| probe=""`.
- Le compteur `REPO_TOTAL` est calculé par `repos_for_group "$groups" | wc -l`
  — si on ajoute un dépôt, la progression s'ajuste seule.
- `ELAPSED_REPO_MB` mesure `du` avant/après : c'est l'écriture disque réelle
  (débit ≠ débit réseau pur, debmirror télécharge et écrit en parallèle).
- dry-run : `debmirror --dry-run` télécharge quand même les métadonnées dans
  `.temp/` — "sans rien écrire" signifie sans paquets ni remplacement des
  métadonnées du miroir.
- `mkdir -p "$PERSIST_STATE_DIR" 2>/dev/null || true` en tête de script :
  doit survivre même si non-root (avant la relance sudo), d'où le `|| true`.

## Tests — méthode (reproduire avant de livrer)

Pas de tests automatisés dans le dépôt. La méthode utilisée : des **stubs**
de `lsblk`, `blkid`, `findmnt`, `mkfs.ext4`, `wipefs` dans `/tmp/stubs`,
préfixés au PATH, puis `eval` des fonctions extraites du script :

```bash
eval "$(sed -n '/^system_disk_names()/,/^}/p; /^detect_disk()/,/^}/p' mirror.sh)"
```

Scénarios à couvrir impérativement :
1. disque unique formaté → détecté, UUID lu ;
2. disque système monté → exclu ;
3. swap actif sur une partition du disque système → exclu (via /proc/swaps) ;
4. deux disques de taille proche → arrêt avec liste ;
5. disque vierge + FORMAT_DISK=yes → formaté ;
6. loop/dm-/md → ignorés par is_virtual_disk ;
7. `shellcheck -x mirror.sh` sans erreur + `bash -n`.

## Évolutions possibles (non implémentées volontairement)

- Serveur HTTP pour servir le LAN (nginx/apache) — hors périmètre voulu.
- Timer systemd de synchro périodique — hors périmètre voulu.
- Paquets i386/arm64 — régler `ARCHES`.
- Filtrage par priorité/section debmirror (`--limit-priority`) pour réduire
  la taille du miroir Debian.

## Conventions de commit

Messages en français, impératif, une ligne : « Progression enrichie : … ».
L'auteur des commits : Titouanlvt <Titouanlvt@users.noreply.github.com>.

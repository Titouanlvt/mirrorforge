# CLAUDE.md

Guide pour travailler sur ce dépôt avec Claude Code.

## Le projet

`mirror.sh` : script Bash unique et autonome qui miroite 7 dépôts APT
(Debian 13 trixie, Debian security, Proxmox VE/PBS/PDM, Ceph Squid/Tentacle)
sur un disque HDD local. Aucune dépendance externe au script ; toute la
configuration est un bloc de variables en tête de `mirror.sh`.

## Commandes essentielles

```bash
# Lint OBLIGATOIRE avant tout commit — doit passer sans erreur :
shellcheck -x mirror.sh

# Validation syntaxique :
bash -n mirror.sh

# Aide du script :
./mirror.sh --help

# (en sandbox, on ne peut pas lancer le script en root — tester les
# fonctions isolément, voir § Tests ci-dessous)
```

## Tests : pas de harnais, utiliser des stubs

Il n'y a pas de suite de tests automatisée. La méthode de référence :
extraire les fonctions et les exécuter avec des stubs de `lsblk`, `blkid`,
`findmnt`, `mkfs.ext4`, `wipefs` dans le PATH (voir `NOTES_FOR_AI.md` § Tests
pour les 7 scénarios à couvrir). Ne jamais lancer le vrai script sur une
machine avec des disques : le test disque passe par des stubs.

Exemple minimal :

```bash
eval "$(sed -n '/^detect_disk()/,/^}/p' mirror.sh)"
PATH="/tmp/stubs:$PATH" detect_disk
```

## Règles de modification

1. **Ne jamais affaiblir les garde-fous** listés dans `NOTES_FOR_AI.md`
   § Invariants critiques (formatage conditionnel, pas de devine entre
   disques, fstab idempotent, échec de dépôt non-fatal).
2. **Garder shellcheck à 0 erreur** (y compris warnings style).
3. Pas de commentaires superflus dans le code ; les explications vont dans
   `NOTES_FOR_AI.md`.
4. Tout changement de comportement du disque (détection/formatage/montage)
   DOIT être re-testé avec les stubs sur les scénarios 1-6.
5. Idempotence : le script doit être relançable sans effet de bord (fstab,
   détection, montage, arborescence).

## Périmètre volontairement exclu

Ne pas ajouter sans demande explicite : serveur HTTP, timer systemd,
fichier de configuration externe, dependencies hors dépôts Debian 13.

## Conventions git

- Commits en français, une ligne, impératif.
- Pousser sur `main` uniquement (pas de branche de feature pour ce dépôt).
- Vérifier `shellcheck` + `bash -n` avant de committer.

## Documentation connexe

- `README.md` — tourné vers l'utilisateur final (design badges/tableaux).
- `NOTES_FOR_AI.md` — documentation technique approfondie pour IA/développeur,
  à mettre à jour si l'architecture change.

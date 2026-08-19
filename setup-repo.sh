#!/bin/bash
# ---------------------------------------------------------------------------
# Zet de SmokePing-egg in https://github.com/yannickbm/smokeping
#
# Gebruik: leg Dockerfile, egg-smokeping.json, README.md en build-image.yml
# in een lege map, ga daarheen met je terminal en draai:
#
#   bash setup-repo.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="https://github.com/yannickbm/smokeping.git"

for f in Dockerfile egg-smokeping.json README.md build-image.yml; do
    if [ ! -f "$f" ]; then
        echo "[!] $f ontbreekt in deze map. Download alle vier de bestanden eerst."
        exit 1
    fi
done

echo "[*] Repo-structuur maken"
mkdir -p .github/workflows
[ -f .github/workflows/build-image.yml ] || mv build-image.yml .github/workflows/build-image.yml

if [ ! -d .git ]; then
    echo "[*] Git-repo initialiseren"
    git init -b main
    git remote add origin "$REPO"
    # bestaande repo-inhoud (bv. een README van GitHub zelf) ophalen
    git fetch origin main && git reset --soft origin/main || true
fi

echo "[*] Committen"
git add Dockerfile egg-smokeping.json README.md .github/workflows/build-image.yml
git commit -m "SmokePing Pterodactyl egg + image build" || echo "[*] Niets nieuws om te committen"

echo "[*] Pushen naar $REPO"
git push -u origin main

cat <<'EOF'

[*] Klaar. Nog twee dingen:

  1. Check de build:  https://github.com/yannickbm/smokeping/actions
  2. Zet het package op PUBLIC, anders kan Wings hem niet pullen:
     https://github.com/users/yannickbm/packages/container/smokeping/settings
     -> Change visibility -> Public

EOF

#!/usr/bin/env bash
#
# remove-song.sh — Borra una o más canciones del repo (mp3 + entrada
# en music/tracks.json). Funciona en el repo principal o en cualquier
# repo secundario (toma la ruta de su propio directorio).
#
# Uso:
#   ./remove-song.sh "Artista - Título.mp3"
#   ./remove-song.sh "file1.mp3" "file2.mp3" "file3.mp3"
#
# El player exporta este script automáticamente desde el botón X.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Uso: $0 \"<nombre.mp3>\" [\"<nombre2.mp3>\" ...]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSIC_DIR="$SCRIPT_DIR/music"
TRACKS="$MUSIC_DIR/tracks.json"

[ -f "$TRACKS" ] || { echo "No existe $TRACKS" >&2; exit 1; }

removed=0
missing=0
for FILE in "$@"; do
  MP3="$MUSIC_DIR/$FILE"
  HAS_JSON="$(jq --arg f "$FILE" '[.[] | select(.file == $f)] | length' "$TRACKS")"

  if [ "$HAS_JSON" -gt 0 ]; then
    TMP="$(mktemp)"
    jq --arg f "$FILE" 'map(select(.file != $f))' "$TRACKS" > "$TMP" && mv "$TMP" "$TRACKS"
  fi

  if [ -f "$MP3" ]; then
    rm -f "$MP3"
    echo "  -- $FILE"
    removed=$((removed+1))
  elif [ "$HAS_JSON" -gt 0 ]; then
    echo "  -- $FILE (solo entrada en tracks.json, sin archivo)"
    removed=$((removed+1))
  else
    echo "  ?? $FILE (no estaba)"
    missing=$((missing+1))
  fi
done

LEFT="$(jq 'length' "$TRACKS")"
echo
echo "Listo: removidos=$removed no_encontrados=$missing (quedan $LEFT canciones)"
echo "Para publicar:"
echo "  git add -A && git commit -m \"remove: $removed tracks\" && git push"

#!/usr/bin/env bash
#
# add-spotify.sh — Importa una playlist pública de Spotify.
#
# Lee la metadata desde el embed público de Spotify (sin tocar la API
# anónima, que se rate-limitea rápido) y para cada track hace
# ytsearch1 en YouTube via add-song.sh, pasando título/artista correctos
# como overrides para que tracks.json quede limpio.
#
# Uso:
#   ./add-spotify.sh "https://open.spotify.com/playlist/ID"
#   ./add-spotify.sh "https://open.spotify.com/playlist/ID" 20      # primeros 20
#
# Requisitos: yt-dlp, jq, python3, curl

set -euo pipefail

URL="${1:-}"
LIMIT="${2:-0}"
GENRE_OV="${3:-}"     # género opcional para todos los tracks; por defecto usa el nombre de la playlist

if [ -z "$URL" ]; then
  echo "Uso: $0 <url-spotify-playlist> [N] [\"Género\"]"
  echo "  N: cuántos tracks bajar (0 = todos)"
  echo "  Género: etiqueta para todos los tracks (default = nombre de la playlist)"
  exit 1
fi

# Extraer playlist ID
PID="$(echo "$URL" | sed -nE 's#.*spotify\.com/playlist/([A-Za-z0-9]+).*#\1#p')"
if [ -z "$PID" ]; then
  echo "URL no parece de playlist Spotify: $URL" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADD_SONG="$SCRIPT_DIR/add-song.sh"
[ -x "$ADD_SONG" ] || { echo "Falta $ADD_SONG ejecutable" >&2; exit 1; }

for cmd in yt-dlp jq python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Falta: $cmd" >&2; exit 1; }
done

TMP_HTML="$(mktemp)"
TMP_TSV="$(mktemp)"
trap 'rm -f "$TMP_HTML" "$TMP_TSV"' EXIT

echo "==> Leyendo metadata del embed de Spotify (playlist $PID)..."
curl -sfL -A "Mozilla/5.0" "https://open.spotify.com/embed/playlist/$PID" -o "$TMP_HTML"

PLAYLIST_NAME_FILE="$(mktemp)"
trap 'rm -f "$TMP_HTML" "$TMP_TSV" "$PLAYLIST_NAME_FILE"' EXIT

python3 - "$TMP_HTML" "$TMP_TSV" "$PLAYLIST_NAME_FILE" <<'PY'
import re, json, sys
html = open(sys.argv[1]).read()
m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.DOTALL)
if not m:
    print("ERROR: no se encontró __NEXT_DATA__ en el embed", file=sys.stderr)
    sys.exit(1)
data = json.loads(m.group(1))
try:
    entity = data['props']['pageProps']['state']['data']['entity']
    name = entity.get('name', '(sin nombre)')
    tracks = entity.get('trackList', []) or []
except Exception as e:
    print(f"ERROR: estructura inesperada: {e}", file=sys.stderr)
    sys.exit(1)

print(f"PLAYLIST_NAME={name}", file=sys.stderr)
print(f"PLAYLIST_COUNT={len(tracks)}", file=sys.stderr)

with open(sys.argv[3], 'w') as nf:
    nf.write(name)

with open(sys.argv[2], 'w') as out:
    for t in tracks:
        # subtitle usa NBSP como separador, normalizamos
        subtitle = (t.get('subtitle') or '').replace(' ', ' ').strip()
        primary = subtitle.split(',')[0].strip() if subtitle else 'Unknown'
        title = (t.get('title') or '').strip()
        if not title:
            continue
        out.write(f"{subtitle}\t{title}\t{primary}\n")
PY

# Determinar género global
if [ -z "$GENRE_OV" ]; then
  GENRE_OV="$(cat "$PLAYLIST_NAME_FILE" 2>/dev/null || echo 'Otros')"
fi
echo "==> Género asignado: $GENRE_OV"

TOTAL=$(wc -l < "$TMP_TSV" | xargs)
[ "$TOTAL" -eq 0 ] && { echo "No se extrajo ningún track." >&2; exit 1; }
echo "==> $TOTAL tracks encontrados"

if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$TOTAL" ]; then
  head -n "$LIMIT" "$TMP_TSV" > "${TMP_TSV}.lim" && mv "${TMP_TSV}.lim" "$TMP_TSV"
  TOTAL="$LIMIT"
  echo "==> Limitado a primeros $LIMIT"
fi

i=0; ok=0; skip=0; fail=0
while IFS=$'\t' read -r subtitle title primary; do
  i=$((i+1))
  artist="${subtitle:-$primary}"
  query="$primary $title"
  echo
  echo "[$i/$TOTAL] $artist — $title"
  OUT=$("$ADD_SONG" "ytsearch1:$query" "$title" "$artist" "$GENRE_OV" 2>&1) || true
  if   echo "$OUT" | grep -q "^  ok:";   then ok=$((ok+1));
  elif echo "$OUT" | grep -q "^  skip:"; then skip=$((skip+1));
  else                                          fail=$((fail+1));
       echo "$OUT" | tail -3 >&2
  fi
done < "$TMP_TSV"

echo
echo "Listo: ok=$ok skip=$skip fail=$fail (total $TOTAL)"
echo "Para publicar: git add music/ && git commit -m 'add: $TOTAL tracks de Spotify' && git push"

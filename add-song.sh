#!/usr/bin/env bash
#
# add-song.sh — Descarga audio de YouTube y lo añade al Mau Player.
#
# Uso (un solo video):
#   ./add-song.sh "https://www.youtube.com/watch?v=ID"
#   ./add-song.sh "https://youtu.be/ID" "Título personalizado"
#   ./add-song.sh "https://youtu.be/ID" "Título" "Artista"
#
# Uso (playlist — cualquier URL con list= o /playlist?list=):
#   ./add-song.sh "https://www.youtube.com/playlist?list=PL..."
#   ./add-song.sh "https://www.youtube.com/watch?v=X&list=PL..." 10   # primeros 10
#
# Convención de archivo: "Artista - Título.mp3" (coincide con el parser
# de drag-and-drop del player).

set -euo pipefail

URL="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"        # género opcional (4° posicional)

if [ -z "$URL" ]; then
  cat <<EOF
Uso:
  $0 <url-video>                                          # un solo video
  $0 <url-video> "Título"                                 # forzar título
  $0 <url-video> "Título" "Artista"                       # forzar título y artista
  $0 <url-video> "Título" "Artista" "Género"              # también género
  $0 <url-playlist>                                       # toda la playlist
  $0 <url-playlist> N                                     # primeros N tracks
  $0 <url-playlist> N "" "" "Género"                      # con género
EOF
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSIC_DIR="$SCRIPT_DIR/music"
TRACKS="$MUSIC_DIR/tracks.json"

# ---------- Dependencias ----------
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Falta: $1" >&2
    echo "Instala con: brew install $1" >&2
    exit 1
  fi
}
need yt-dlp
need jq

mkdir -p "$MUSIC_DIR"
[ -f "$TRACKS" ] || echo "[]" > "$TRACKS"

# ---------- Utilidades ----------
sanitize() {
  local s="$1"
  s="${s//\//-}"
  s="${s//\\/-}"
  s="$(echo "$s" | tr -d ':*?"<>|')"
  s="$(echo "$s" | tr -s ' ')"
  s="$(echo "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "$s"
}

# ---------- Procesar un solo video ----------
# Args: URL [title_override] [artist_override]
# Retorna 0 (ok), 1 (fail), 2 (skip duplicado).
add_one() {
  local url="$1"
  local title_ov="${2:-}"
  local artist_ov="${3:-}"
  local genre_ov="${4:-Otros}"

  local meta title artist
  meta="$(yt-dlp --dump-single-json --no-warnings "$url" 2>/dev/null || true)"
  if [ -z "$meta" ]; then
    echo "  fail: no se pudo leer metadata" >&2
    return 1
  fi

  title="$(echo "$meta" | jq -r '.title // empty')"
  artist="$(echo "$meta" | jq -r '.artist // .creator // .uploader // .channel // "Desconocido"')"

  if [ -z "$title" ]; then
    echo "  fail: sin título" >&2
    return 1
  fi

  [ -n "$title_ov" ]  && title="$title_ov"
  [ -n "$artist_ov" ] && artist="$artist_ov"

  # Limpiar sufijos típicos del canal en YouTube
  artist="$(echo "$artist" | sed -E 's/ - Topic$//; s/VEVO$//; s/Vevo$//' | xargs)"

  # Si el título ya empieza con "Artist - " lo dejamos limpio
  # (evita "Drake - Drake - Hotline Bling.mp3")
  local title_clean
  title_clean="$(echo "$title" | sed -E "s/^${artist} - //I")"

  local safe_artist safe_title filename target
  safe_artist="$(sanitize "$artist")"
  safe_title="$(sanitize "$title_clean")"
  filename="${safe_artist} - ${safe_title}.mp3"
  target="$MUSIC_DIR/$filename"

  local exists
  exists="$(jq --arg f "$filename" '[.[] | select(.file == $f)] | length' "$TRACKS")"
  if [ "$exists" -gt 0 ]; then
    echo "  skip: $filename (ya en librería)"
    return 2
  fi

  if [ ! -f "$target" ]; then
    yt-dlp -x --audio-format mp3 --audio-quality 0 \
      --no-warnings \
      --embed-thumbnail --embed-metadata \
      -o "$target" \
      "$url" >/dev/null 2>&1 || { echo "  fail: descarga falló" >&2; return 1; }
  fi

  if [ ! -f "$target" ]; then
    echo "  fail: archivo no apareció" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg file "$filename" --arg title "$title_clean" --arg artist "$artist" --arg genre "$genre_ov" \
     '. + [{file: $file, title: $title, artist: $artist, genre: $genre}]' \
     "$TRACKS" > "$tmp" && mv "$tmp" "$TRACKS"

  echo "  ok: $artist — $title_clean [$genre_ov]"
  return 0
}

# ---------- Dispatcher: playlist o video ----------
if echo "$URL" | grep -qE '[?&]list=|/playlist\?'; then
  LIMIT=""
  if [ -n "$ARG2" ] && [[ "$ARG2" =~ ^[0-9]+$ ]]; then
    LIMIT="$ARG2"
  fi

  echo "==> Playlist detectada. Extrayendo URLs..."
  YT_ARGS=(--flat-playlist --yes-playlist --no-warnings
           --print "https://www.youtube.com/watch?v=%(id)s")
  [ -n "$LIMIT" ] && YT_ARGS+=(--playlist-end "$LIMIT")

  URLS_FILE="$(mktemp)"
  yt-dlp "${YT_ARGS[@]}" "$URL" > "$URLS_FILE"
  TOTAL=$(wc -l < "$URLS_FILE" | xargs)
  echo "==> $TOTAL videos${LIMIT:+ (limitado por arg)}"

  i=0; ok=0; skip=0; fail=0
  while IFS= read -r u; do
    i=$((i+1))
    echo
    echo "[$i/$TOTAL] $u"
    rc=0
    add_one "$u" "" "" "$ARG4" || rc=$?
    case "$rc" in
      0) ok=$((ok+1));;
      2) skip=$((skip+1));;
      *) fail=$((fail+1));;
    esac
  done < "$URLS_FILE"
  rm -f "$URLS_FILE"

  echo
  echo "Listo: ok=$ok skip=$skip fail=$fail (total $TOTAL)"
  echo "Para publicar: git add music/ && git commit -m 'add: $TOTAL tracks' && git push"
  exit 0
fi

# Video único
echo "==> $URL"
rc=0
add_one "$URL" "$ARG2" "$ARG3" "$ARG4" || rc=$?
case "$rc" in
  0)
    COUNT="$(jq 'length' "$TRACKS")"
    echo
    echo "Total en librería: $COUNT"
    echo "Para publicar: git add music/ && git commit -m 'add: track' && git push"
    ;;
  2) ;; # skip, ya impreso
  *) exit 1 ;;
esac

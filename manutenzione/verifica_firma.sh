#!/bin/zsh
# Verifica pkgutil --check-signature dei pacchetti macOS scaricati (job macos-latest).
# Uso: verifica_firma.sh <elenco.json> <cartella>
set -u
ELENCO="$1"; DIR="$2"
# Lettura JSON con python3 (presente sui runner macOS; osascript può non funzionare senza sessione grafica).
J() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8-sig"))
for k in sys.argv[2].split("."):
    v=None if v is None else (v[int(k)] if isinstance(v,list) else v.get(k))
print("" if v is None else (json.dumps(v) if isinstance(v,(dict,list)) else v))' "$@"; }
N() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8-sig"))))' "$1"; }
n=$(N "$DIR/scaricati.json")
[[ "$n" == <-> ]] || { echo "::error::scaricati.json non leggibile"; exit 1; }
print -n '[' > "$DIR/verificati_macos.json"
for (( i=0; i<n; i++ )); do
  idx=$(J "$DIR/scaricati.json" "$i.indice"); file="$DIR/$(J "$DIR/scaricati.json" "$i.file")"; err=$(J "$DIR/scaricati.json" "$i.errore")
  ok=false; firma=""; motivo="$err"
  if [[ -z "$err" ]]; then
    pkg="$file"; mnt=""
    if [[ "$file" == *.dmg ]]; then
      mnt=$(mktemp -d); hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$file" >/dev/null && pkg=$(find "$mnt" -maxdepth 3 -name '*.pkg' -o -maxdepth 3 -name '*.mpkg' | head -1)
    fi
    out=$(pkgutil --check-signature "$pkg" 2>&1)
    firma=$(print -r -- "$out" | awk '/^ *1\. /{sub(/^ *1\. /,""); print; exit}')
    motivo="firmatario non ammesso o firma non valida: ${firma:-nessuna}"
    if print -r -- "$out" | grep -qE 'Status: signed (by a developer certificate issued by Apple|Apple Software)'; then
      signers=$(J "$ELENCO" "$idx.macSignerNames")
      # "Developer ID Installer: Ricoh Co., Ltd. (5KACUT3YX8)" -> "ricohcoltd", confrontato con i nomi ammessi normalizzati.
      nome=$(print -r -- "$firma" | sed -E 's/^[^:]*: *//; s/ *\([A-Z0-9]+\)$//' | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
      for s in ${(f)"$(python3 -c 'import json,sys;print("\n".join(json.loads(sys.argv[1])))' "$signers")"}; do
        n=$(print -r -- "$s" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
        [[ -n "$n" && "$nome" == "$n" ]] && { ok=true; motivo="firma valida"; }
      done
    fi
    [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null
  fi
  (( i )) && print -n ',' >> "$DIR/verificati_macos.json"
  printf '{"indice":%s,"ok":%s,"firma":"%s","motivo":"%s"}' "$idx" "$ok" "${firma//\"/}" "${motivo//\"/}" >> "$DIR/verificati_macos.json"
  echo "$file: $motivo"
done
print ']' >> "$DIR/verificati_macos.json"

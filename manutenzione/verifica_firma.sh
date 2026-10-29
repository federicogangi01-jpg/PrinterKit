#!/bin/zsh
# Verifica pkgutil --check-signature dei pacchetti macOS scaricati (job macos-latest).
# Uso: verifica_firma.sh <elenco.json> <cartella>
set -u
ELENCO="$1"; DIR="$2"
J() { osascript -l JavaScript -e "function run(a){ObjC.import('Foundation');const f=$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null).js;const v=JSON.parse(f);let x=v;for(const k of a[1].split('.')){x=x==null?null:x[k]}return x==null?'':(typeof x==='object'?JSON.stringify(x):String(x))}" "$@" }
n=$(J "$DIR/scaricati.json" length)
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
      for s in ${(f)"$(print -r -- "$signers" | tr -d '[]' | tr ',' '\n' | tr -d '"')"}; do
        [[ -n "$s" && "$firma" == *"$s"* ]] && { ok=true; motivo="firma valida"; }
      done
    fi
    [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null
  fi
  (( i )) && print -n ',' >> "$DIR/verificati_macos.json"
  printf '{"indice":%s,"ok":%s,"firma":"%s","motivo":"%s"}' "$idx" "$ok" "${firma//\"/}" "${motivo//\"/}" >> "$DIR/verificati_macos.json"
  echo "$file: $motivo"
done
print ']' >> "$DIR/verificati_macos.json"

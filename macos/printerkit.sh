#!/bin/zsh
# ==========================================================================
# PrinterKit per macOS (Intel e Apple Silicon)
# Trova le stampanti, sceglie SOLO il driver ufficiale del produttore, ne verifica la firma
# (pkgutil --check-signature, Developer ID del produttore) e crea la coda con lpadmin.
#   printerkit.sh [--range 192.168.1.1-254] [--ip 192.168.1.50,…] [--tutte] [--prova-a-secco] [--scanner]
# ==========================================================================
emulate -L zsh
setopt pipefail no_nomatch extended_glob

KIT="${0:A:h:h}"
JS="$KIT/macos/catalogo.js"
CAT_LOCAL="$KIT/catalogo/drivers.json"
WHATIF=0; ALL=0; RANGE=""; IPS=""; SCANNER=0
while (( $# )); do
  case "$1" in
    --range) RANGE="$2"; shift ;;
    --ip) IPS="$2"; shift ;;
    --tutte) ALL=1 ;;
    --prova-a-secco) WHATIF=1 ;;
    --scanner) SCANNER=1 ;;
  esac
  shift
done

# ---------- Privilegi: sudo ----------
if (( EUID != 0 )) && (( ! WHATIF )); then
  echo "PrinterKit richiede i diritti di amministratore (sudo)."
  exec sudo "$0" "${@}" ${RANGE:+--range "$RANGE"} ${IPS:+--ip "$IPS"} $( (( ALL )) && echo --tutte ) $( (( SCANNER )) && echo --scanner )
fi

js() { osascript -l JavaScript "$JS" "$@" 2>/dev/null }
cfg() { js json "$KIT/config.json" "$1" }
dialog() { osascript -e "display dialog \"$1\" buttons {\"Continua\"} default button 1 with title \"PrinterKit\"" >/dev/null 2>&1 }
ask() { osascript -e "text returned of (display dialog \"$1\" default answer \"$2\" with title \"PrinterKit\")" 2>/dev/null }
ask_secret() { osascript -e "text returned of (display dialog \"$1\" default answer \"\" with hidden answer with title \"PrinterKit\")" 2>/dev/null }
confirm() { osascript -e "button returned of (display dialog \"$1\" buttons {\"No\",\"Sì\"} default button 2 with title \"PrinterKit\")" 2>/dev/null | grep -q "Sì" }

# ---------- Sistema e utente di sessione ----------
OSVER=$(sw_vers -productVersion)
case "$(uname -m)" in arm64) ARCH=applesilicon; ARCHL="Apple Silicon" ;; *) ARCH=intel; ARCHL="Intel" ;; esac
SYSLABEL="macOS $OSVER – $ARCHL"
CONSOLE_USER=$(stat -f %Su /dev/console)
USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="$HOME"
DOWNLOADS="$USER_HOME/Downloads"
PCNAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
mkdir -p "$DOWNLOADS/PrinterKit"
SESSION_LOG="$DOWNLOADS/PrinterKit/sessione_$(date +%Y-%m-%d_%H-%M-%S).txt"
typeset -a SECRETS

log() {
  local line="$(date +%H:%M:%S) $1"
  for s in $SECRETS; do line="${line//$s/********}"; done
  print -r -- "$line" | tee -a "$SESSION_LOG"
}
log "=== PrinterKit (macOS) – sessione del $(date '+%d/%m/%Y %H:%M') ==="
log "Sistema: $SYSLABEL   Utente: $CONSOLE_USER   PC: $PCNAME"
(( WHATIF )) && log "MODALITÀ PROVA: nessuna modifica al sistema"

# ---------- Catalogo ----------
CAT="$CAT_LOCAL"
REMOTE=$(cfg catalogSource)
TMP=$(mktemp -d /tmp/printerkit.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
if [[ -n "$REMOTE" ]] && curl -fsSL --proto '=https' --max-time 20 "$REMOTE" -o "$TMP/drivers.json" 2>/dev/null; then
  if [[ "$(js valida "$TMP/drivers.json")" == ok ]]; then
    CAT="$TMP/drivers.json"; cp "$CAT" "$CAT_LOCAL" 2>/dev/null
    log "Catalogo online, aggiornato il $(js aggiornato "$CAT")"
  else
    log "!! Catalogo online non valido: uso la copia locale"
  fi
else
  log "!! Catalogo online non raggiungibile: uso la copia locale (aggiornata il $(js aggiornato "$CAT"))"
fi
[[ "$(js valida "$CAT")" == ok ]] || { log "XX Catalogo locale non valido"; exit 1; }
COMMUNITY=$(cfg snmpCommunity); [[ -z "$COMMUNITY" ]] && COMMUNITY=public

# ---------- Scansione rete ----------
expand_range() {
  # 192.168.1.1-254 | 192.168.1.0/24 (solo /24) | IP singoli separati da virgola
  local part
  for part in ${(s:,:)1}; do
    part=${part// /}
    if [[ "$part" =~ '^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)-([0-9]+)$' ]]; then
      for i in {${match[2]}..${match[3]}}; do echo "${match[1]}.$i"; done
    elif [[ "$part" =~ '^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$' ]]; then
      for i in {1..254}; do echo "${match[1]}.$i"; done
    elif [[ "$part" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
      echo "$part"
    fi
  done
}

local_ranges() {
  ifconfig | awk '/inet /{print $2}' | grep -vE '^(127\.|169\.254\.)' | awk -F. '{print $1"."$2"."$3".1-254"}' | sort -u | paste -sd, -
}

scan_ports() {
  # Connessioni TCP parallele (timeout 1 s) a 9100, 631, 515.
  expand_range "$1" | xargs -P 64 -I{} zsh -c 'p=""; for port in 9100 631 515; do nc -z -G 1 {} $port >/dev/null 2>&1 && p="$p,$port"; done; [[ -n "$p" ]] && echo "{} ${p#,}"' 2>/dev/null
}

bonjour_ips() {
  # Bonjour: _ipp._tcp e _pdl-datastream._tcp (5 secondi).
  local svc
  for svc in _ipp._tcp _pdl-datastream._tcp; do
    ( dns-sd -B "$svc" local. > "$TMP/bonjour_$svc.txt" 2>/dev/null & pid=$!; sleep 5; kill $pid 2>/dev/null )
    awk 'NR>4 && $2=="Add" {for(i=7;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"\n")}' "$TMP/bonjour_$svc.txt" | sort -u | while read -r name; do
      ( dns-sd -L "$name" "$svc" local. > "$TMP/l.txt" 2>/dev/null & pid=$!; sleep 2; kill $pid 2>/dev/null )
      host=$(grep -o 'can be reached at [^:]*' "$TMP/l.txt" | head -1 | awk '{print $5}')
      [[ -n "$host" ]] && dscacheutil -q host -a name "$host" 2>/dev/null | awk '/ip_address/{print $2; exit}'
    done
  done | sort -u
}

identify() {
  # SNMP (hrDeviceDescr, sysDescr) poi IPP con ipptool.
  local ip=$1 model="" descr=""
  if command -v snmpget >/dev/null; then
    model=$(snmpget -v2c -c "$COMMUNITY" -t 1 -r 0 -Ovq "$ip" 1.3.6.1.2.1.25.3.2.1.3.1 2>/dev/null | tr -d '"')
    descr=$(snmpget -v2c -c "$COMMUNITY" -t 1 -r 0 -Ovq "$ip" 1.3.6.1.2.1.1.1.0 2>/dev/null | tr -d '"')
  fi
  if [[ -z "$model" || "$model" == *"No Such"* ]]; then
    model=$(ipptool -T 3 -tv "ipp://$ip/ipp/print" get-printer-attributes.test 2>/dev/null | awk -F' = ' '/printer-make-and-model/{print $2; exit}')
  fi
  print -r -- "${model}|${descr}"
}

languages() {
  local ip=$1 out=""
  out=$(ipptool -T 3 -tv "ipp://$ip/ipp/print" get-printer-attributes.test 2>/dev/null | awk -F' = ' '/document-format-supported/{print $2; exit}')
  local l=""
  [[ "$out" == *postscript* ]] && l="ps"
  [[ "$out" == *pclxl* || "$out" == *PCL-XL* ]] && l="${l:+$l,}pcl6"
  print -r -- "$l"
}

existing_for_ip() { lpstat -v 2>/dev/null | grep -E "://$1(:|/|$)" | head -1 | sed -E 's/^device for ([^:]+):.*/\1/' }

clean_name() { print -r -- "$1" | sed -E 's#[/:*?"<>|\\]# #g; s/  +/ /g; s/^ +| +$//g' }

# ---------- Installazione ----------
install_one() {
  local ip=$1 ports=$2 model=$3 descr=$4
  local manline man manname sel res folder logf queue src
  local -a f
  manline=$(js marca "$CAT" "$model $descr")
  man=${manline%%$'\t'*}; manname=${manline#*$'\t'}
  local brand="$manname"; [[ "${model:u}" == "${manname:u}"* ]] && brand=""
  brand=${brand%% (*}
  if [[ -n "$model" ]]; then folder="$DOWNLOADS/$(clean_name "Driver ${brand:+$brand }$model")"; else folder="$DOWNLOADS/Driver $ip"; fi
  logf="$folder/log_$(date +%Y-%m-%d)_${PCNAME}.txt"
  local driver="nessuno" fonte="" firma="" sha="" porta="" coda="" prova="non richiesta" esito=""
  {
    if [[ -n "$(existing_for_ip "$ip")" ]]; then esito="Già installata ($(existing_for_ip "$ip")): lasciata com'è"; return 1; fi
    if [[ -z "$man" ]]; then esito="NON INSTALLATA - Modello non presente nel catalogo"; return 1; fi
    sel=$(js scegli "$CAT" "$man" "$model" "$OSVER" "$ARCH" "$(languages "$ip")")
    f=("${(@ps:\t:)sel}")
    if [[ "${f[1]}" != OK ]]; then esito="NON INSTALLATA - ${f[2]}"; return 1; fi
    local pkgid=${f[2]} family=${f[3]} version=${f[4]} url=${f[5]} expsha=${f[6]} ftype=${f[7]}
    driver="$family $version ($pkgid)"
    log "[$ip] Driver previsto: $driver"
    [[ "$(js dominio "$CAT" "$man" "$url")" == si ]] || { esito="NON INSTALLATA - link fuori dai domini ufficiali"; return 1; }
    local cache="$KIT/cache/$man/$pkgid" file
    mkdir -p "$TMP/$pkgid"
    file=$(ls "$cache"/*.(pkg|dmg) 2>/dev/null | head -1)
    if [[ -n "$file" && -n "$expsha" && "$(shasum -a 256 "$file" | awk '{print $1}')" == "$expsha" ]]; then
      fonte="cache del kit"
    else
      file="$TMP/$pkgid/${url:t}"; [[ "$file" == *.* ]] || file="$file.$ftype"
      local final
      final=$(curl -fL --proto '=https' --proto-redir '=https' --max-redirs 5 --retry 1 -A "Mozilla/5.0 PrinterKit" -w '%{url_effective}' -o "$file" "$url" 2>/dev/null) \
        || { esito="NON INSTALLATA - download non riuscito"; return 1; }
      [[ "$(js dominio "$CAT" "$man" "$final")" == si ]] || { rm -f "$file"; esito="NON INSTALLATA - redirect fuori dai domini ufficiali ($final)"; return 1; }
      fonte="$url"
    fi
    sha=$(shasum -a 256 "$file" | awk '{print $1}')
    if [[ -n "$expsha" && "$sha" != "$expsha" ]]; then rm -f "$file"; esito="NON INSTALLATA - SHA-256 diverso dal catalogo: file scartato"; return 1; fi
    # .dmg: si monta in sola lettura e si prende il .pkg contenuto.
    local pkgfile="$file" mnt=""
    if [[ "$ftype" == dmg || "$file" == *.dmg ]]; then
      mnt="$TMP/mnt_$pkgid"; mkdir -p "$mnt"
      hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$file" >/dev/null || { esito="NON INSTALLATA - immagine disco non apribile"; return 1; }
      pkgfile=$(find "$mnt" -maxdepth 3 \( -name '*.pkg' -o -name '*.mpkg' \) | head -1)
      [[ -n "$pkgfile" ]] || { hdiutil detach "$mnt" >/dev/null; esito="NON INSTALLATA - nessun .pkg nell'immagine"; return 1; }
    fi
    local sig signer ok=0
    sig=$(pkgutil --check-signature "$pkgfile" 2>&1)
    signer=$(print -r -- "$sig" | awk '/^ *1\. /{sub(/^ *1\. /,""); print; exit}')
    if print -r -- "$sig" | grep -qE 'Status: signed (by a developer certificate issued by Apple|Apple Software)'; then
      while read -r n; do [[ -n "$n" && "$signer" == *"$n"* ]] && ok=1; done <<< "$(js firmatari "$CAT" "$man")"
    fi
    if (( ! ok )); then
      [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null
      rm -f "$file"; rm -rf "$cache"
      esito="NON INSTALLATA - firma non valida o firmatario non ammesso (${signer:-nessuna firma}): file scartato"; return 1
    fi
    firma="$signer – valida"
    log "[$ip] Firma: $firma"
    if (( ! WHATIF )); then
      if [[ "$fonte" != "cache del kit" ]]; then
        mkdir -p "$cache" && cp "$file" "$cache/" && printf 'sha256=%s\nfirma=%s\nurl=%s\ndata=%s\n' "$sha" "$signer" "$url" "$(date '+%Y-%m-%d %H:%M')" > "$cache/verificato.txt"
      fi
      mkdir -p "$folder"; cp "$file" "$folder/" 2>/dev/null
      lpinfo -m 2>/dev/null | sort > "$TMP/before.txt"
      installer -pkg "$pkgfile" -target / >/dev/null 2>&1 || { [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null; esito="NON INSTALLATA - installer non riuscito"; return 1; }
      lpinfo -m 2>/dev/null | sort > "$TMP/after.txt"
    fi
    [[ -n "$mnt" ]] && hdiutil detach "$mnt" >/dev/null
    # Driver (PPD) dal pacchetto appena installato: nuovi in lpinfo -m, poi quelli del produttore.
    local code ppd
    code=$(print -r -- "$model" | grep -oE '[A-Za-z]{1,4}-?[0-9]{3,5}' | head -1 | tr -d '-')
    local -a cands
    cands=("${(@f)$(comm -13 "$TMP/before.txt" "$TMP/after.txt" 2>/dev/null)}")
    (( ${#cands} )) || cands=("${(@f)$(lpinfo -m 2>/dev/null | grep -iE "${manname%% *}")}")
    ppd=""
    for c in $cands; do [[ -n "$code" && "${c//-/}" == *(#i)$code* ]] && { ppd=${c%% *}; break; }; done
    if [[ -z "$ppd" ]]; then for c in $cands; do [[ "$c" == *(#i)(postscript|ps)* ]] && { ppd=${c%% *}; break; }; done; fi
    [[ -z "$ppd" && -n "${cands[1]}" ]] && ppd=${cands[1]%% *}
    if (( WHATIF )); then esito="OK (prova: nessuna modifica)"; return 0; fi
    [[ -n "$ppd" ]] || { esito="NON INSTALLATA - il pacchetto ufficiale non ha installato un driver per questo modello"; return 1; }
    local uri
    if [[ ",$ports," == *",9100,"* ]]; then uri="socket://$ip:9100"; porta="socket://$ip:9100 (RAW 9100)"
    elif [[ ",$ports," == *",631,"* ]]; then uri="ipp://$ip/ipp/print"; porta="$uri (IPP)"
    else uri="lpd://$ip/lp"; porta="$uri (LPR)"; fi
    queue=$(print -r -- "${brand:+$brand }$model ($ip)" | sed -E 's/[^A-Za-z0-9_.-]+/_/g; s/_+$//')
    lpadmin -p "$queue" -E -v "$uri" -m "$ppd" -D "${brand:+$brand }$model ($ip)" -L "$ip" -o printer-is-shared=false \
      || { esito="NON INSTALLATA - lpadmin non riuscito"; return 1; }
    cupsenable "$queue"; cupsaccept "$queue"
    coda="$queue"
    if [[ -f /usr/share/cups/data/testprint ]]; then lp -d "$queue" /usr/share/cups/data/testprint >/dev/null 2>&1 && prova="inviata"; fi
    esito="OK"
    return 0
  } always {
    mkdir -p "$folder"
    {
      echo "=== PrinterKit – intervento del $(date '+%d/%m/%Y %H:%M') ==="
      echo "PC: $PCNAME   Utente: $CONSOLE_USER   Sistema: $SYSLABEL"
      echo "Stampante: ${brand:+$brand }${model:-sconosciuta}   IP: $ip   Porte aperte: ${ports//,/, }"
      echo "Driver: $driver"
      [[ -n "$fonte" ]] && echo "  Fonte: $fonte   Firma: $firma" && echo "  SHA-256: $sha"
      [[ -n "$porta" ]] && echo "Porta creata: $porta"
      [[ -n "$coda" ]] && echo "Stampante creata: \"$coda\" – predefinita: no" && echo "Pagina di prova: $prova"
      echo "Esito: $esito"
      echo
    } >> "$logf"
    chown -R "$CONSOLE_USER" "$folder" 2>/dev/null
    log "[$ip] $esito"
  }
}

# ---------- Scanner su cartella (§10.4, lato Mac) ----------
setup_scanner() {
  local users_text share="$(cfg scanShareName)" suser="$(cfg scanUserDefault)"
  [[ -z "$share" ]] && share=Scansioni; [[ -z "$suser" ]] && suser=scanner
  users_text=$(ask "Utenti per la scansione, separati da virgola (es. Mario, Contabilità):" "")
  [[ -z "$users_text" ]] && return
  local root="$USER_HOME/$share" pw ip
  pw=$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom | head -c 16); SECRETS+=("$pw")
  ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)
  (( WHATIF )) && { log "[prova] creerei $root, l'utente $suser e la condivisione SMB $share"; return; }
  mkdir -p "$root"
  for u in ${(s:,:)users_text}; do u=$(clean_name "$u"); [[ -n "$u" ]] && mkdir -p "$root/$u"; done
  if ! id "$suser" >/dev/null 2>&1; then
    sysadminctl -addUser "$suser" -fullName "Scanner PrinterKit" -password "$pw" >/dev/null 2>&1
    dscl . create "/Users/$suser" IsHidden 1
    log "Utente $suser creato (nascosto)"
  else
    pw=$(ask_secret "L'utente $suser esiste già: inserisci la sua password"); SECRETS+=("$pw")
  fi
  chown -R "$CONSOLE_USER" "$root"
  chmod -R +a "everyone allow list,add_file,search,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit" "$root"
  sharing -a "$root" -S "$share" -s 001 -g 000 >/dev/null 2>&1 || sharing -e "$share" -s 001 >/dev/null 2>&1
  launchctl load -w /System/Library/LaunchDaemons/com.apple.smbd.plist 2>/dev/null
  defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server EnabledServices -array disk
  dialog "Con Everyone in lettura e scrittura, chiunque sia collegato alla rete può aprire e cancellare le scansioni."
  log "Cartella condivisa: //$ip/$share (utente $suser)"
  {
    echo "=== PrinterKit – scheda scanner $(date '+%d/%m/%Y %H:%M') ==="
    echo "Cartella: $root   Condivisione: smb://$ip/$share"
    echo "Utente: $suser   Password: $pw"
    echo "Utenti: $users_text"
    echo "Nota: in Impostazioni > Generali > Condivisione > Condivisione file > Opzioni, verificare che"
    echo "      la 'Condivisione file Windows' sia attiva per l'utente $suser (macOS lo richiede per SMB)."
  } >> "$DOWNLOADS/PrinterKit/scheda_scanner_mac.txt"
  osascript -l JavaScript "$KIT/macos/ricette.js" "$KIT" "$CAT" "$1" "$2" "$ip" "$share" "$suser" "$pw" "$users_text" 2>&1 | while read -r l; do log "$l"; done
}

# ---------- Flusso principale ----------
if [[ -n "$IPS" ]]; then
  HOSTS="$IPS"
else
  [[ -z "$RANGE" ]] && RANGE=$(cfg defaultRange)
  [[ -z "$RANGE" ]] && RANGE=$(local_ranges)
  [[ -z "$ALL" || "$ALL" == 0 ]] && RANGE=$(ask "Intervallo IP da scansionare:" "$RANGE")
  HOSTS="$RANGE"
fi
log "Scansione di $HOSTS"
scan_ports "$HOSTS" > "$TMP/found.txt"
for b in $(bonjour_ips); do grep -q "^$b " "$TMP/found.txt" || echo "$b 631" >> "$TMP/found.txt"; done
typeset -a ROWS LABELS
while read -r ip ports; do
  id=$(identify "$ip"); model=${id%%|*}; descr=${id#*|}
  ROWS+=("$ip|$ports|$model|$descr")
  LABELS+=("$ip – ${model:-modello sconosciuto}")
  log "Trovata $ip – ${model:-modello sconosciuto} [$ports]"
done < <(sort -t. -k4 -n "$TMP/found.txt")
(( ${#ROWS} )) || { log "Nessuna stampante trovata"; dialog "Nessuna stampante trovata."; exit 0; }

typeset -a CHOSEN
if (( ALL )); then
  CHOSEN=($ROWS)
else
  list=$(printf '"%s",' "${LABELS[@]}"); list="{${list%,}}"
  picked=$(osascript -e "choose from list $list with title \"PrinterKit – $SYSLABEL\" with prompt \"Stampanti da installare:\" with multiple selections allowed" 2>/dev/null)
  [[ "$picked" == false || -z "$picked" ]] && exit 0
  for r in $ROWS; do [[ ", $picked," == *", ${r%%|*} –"* ]] && CHOSEN+=("$r"); done
fi
OKN=0; KON=0
for r in $CHOSEN; do
  ip=${r%%|*}; rest=${r#*|}; ports=${rest%%|*}; rest=${rest#*|}; model=${rest%%|*}; descr=${rest#*|}
  if [[ -z "$model" ]] && (( ! ALL )); then model=$(ask "Modello della stampante $ip (non rilevato):" ""); fi
  if install_one "$ip" "$ports" "$model" "$descr"; then
    OKN=$((OKN+1))
    (( SCANNER )) && setup_scanner "$ip" "$model"
  else KON=$((KON+1)); fi
done
log "Fine: $OKN installate, $KON non installate"
[[ "$(cfg logCopyToKit)" == true ]] && mkdir -p "$KIT/log" && cp "$SESSION_LOG" "$KIT/log/" 2>/dev/null
chown -R "$CONSOLE_USER" "$DOWNLOADS/PrinterKit" 2>/dev/null
(( ALL )) || dialog "Fine: $OKN installate, $KON non installate. Log nella cartella Download."

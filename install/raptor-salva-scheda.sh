#!/usr/bin/env bash
# =====================================================================================================================
# raptor-salva-scheda.sh  -  Raptor AI  -  SALVATAGGIO COMPLETO della scheda in un solo archivio (per metterla da parte)
#
# Cosa mette nell'archivio (un solo file .tar.gz):
#   - /opt/raptor : codice, config (con i segreti), models, data (stato, statistiche, immagini Events AI, log)
#     le statistiche (SQLite) sono copiate con l'API di backup di SQLite: la copia e' coerente anche a programma acceso
#   - il sistema: /etc (senza password di sistema e chiavi host SSH), /usr/local, /var/lib/raptor-admin, cron, orangepiEnv.txt,
#     le cartelle di raptor, orangepi e root (file sotto i 20 MB, senza cache e senza chiavi private)
#   - _salva/info : fotografie in testo (pacchetti, rete, servizi, cron, NPU, versioni, ultimi registri dei servizi)
#
# Cosa NON mette: password di sistema (shadow), chiavi host SSH, chiave del nodo Tailscale, chiavi private (~/.ssh/id_*),
# i backup del pannello (data/backups) e i file sopra i 20 MB nelle cartelle personali (sono elencati nell'archivio).
#
# ATTENZIONE: l'archivio contiene SEGRETI (token Telegram, password e-mail, password Wi-Fi, impronte delle password del pannello).
# Resta privato (permessi 600): non incollarlo in chat, non metterlo in un cloud pubblico. Tienilo offline.
#
# Uso, come utente raptor (lo script si fa dare i permessi di root con su):
#     bash /home/raptor/raptor-salva-scheda.sh
#
# Opzioni:
#     --dest CARTELLA        dove scrivere l'archivio (predefinito: la tua cartella; con una chiavetta: /media/...)
#     --senza-eventi         non salva le immagini Events AI (data/events)
#     --senza-log            non salva i registri (data/logs)
#     --con-backup-pannello  salva anche i backup del pannello (data/backups)
#     --ferma-servizi        ferma i servizi Raptor durante il salvataggio e li riavvia alla fine (copia "a freddo")
#     --yes                  non chiede conferma
#     --check-only           mostra cosa salverebbe e quanto spazio serve, senza scrivere niente
#     --help
# =====================================================================================================================
set -u -o pipefail

SCRIPT_VERSION="1.0.1"
ORIG_ARGS=("$@")
FR="${RAPTOR_FAKE_ROOT:-}"                 # solo per le prove: radice finta al posto di /
FRX="${FR:-/}"
R="${RAPTOR_ROOT:-$FR/opt/raptor}"
RREL="${R#$FRX}"; RREL="${RREL#/}"         # opt/raptor
DEST=""
WITH_EVENTS=1; WITH_LOGS=1; WITH_PANEL=0; STOP_SERVICES=0
ASSUME_YES=0; CHECK_ONLY=0; ELEVATED=0
BIG_MB=20

usage() { awk 'NR==1{next} /^# =+$/{n++; if(n==2) exit; next} n==1{sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) shift; DEST="${1:-}" ;;
    --senza-eventi) WITH_EVENTS=0 ;;
    --senza-log) WITH_LOGS=0 ;;
    --con-backup-pannello) WITH_PANEL=1 ;;
    --ferma-servizi) STOP_SERVICES=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --check-only) CHECK_ONLY=1 ;;
    --elevated) ELEVATED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opzione sconosciuta: %s  (vedi --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'; else C_OK=""; C_WARN=""; C_BAD=""; C_B=""; C_0=""; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "  ${C_OK}[ OK ]${C_0} $*"; }
warn() { printf '%s\n' "  ${C_WARN}[WARN]${C_0} $*"; WARNS=$((WARNS+1)); }
bad()  { printf '%s\n' "  ${C_BAD}[FAIL]${C_0} $*"; }
die()  { bad "$*"; exit 1; }
WARNS=0

hum() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," "); i=1; while(b>=1024 && i<5){b/=1024; i++} f=(i==1)?"%d %s":"%.1f %s"; printf f, b, u[i]}'; }

# ------------------------------------------------------------------------------------------------ permessi di root
printf '%s\n' "${C_B}Raptor AI - salvataggio completo della scheda (script $SCRIPT_VERSION)${C_0}"
if [ "$(id -u)" -ne 0 ]; then
  ABS="$(readlink -f -- "$0")"
  if [ "$ELEVATED" = 1 ]; then printf 'Non sono riuscito a diventare root con su: controlla la password di root e rilancia.\n' >&2; exit 1; fi
  printf 'Servono i permessi di root (per leggere tutto): ti chiedo la password di root (su -).\n' >&2
  [ -n "$DEST" ] || DEST="${HOME:-/tmp}"
  ARGS=""; for a in "${ORIG_ARGS[@]}"; do ARGS="$ARGS $(printf '%q' "$a")"; done
  exec su - -c "bash $(printf '%q' "$ABS")$ARGS --dest $(printf '%q' "$DEST") --elevated"
fi
[ -n "$DEST" ] || { if [ -d "$FR/home/raptor" ]; then DEST="$FR/home/raptor"; else DEST="${HOME:-/root}"; fi; }

# ------------------------------------------------------------------------------------------------ 1. controlli
say ""
say "${C_B}[1/6] Controlli${C_0}"
[ -d "$R" ] || die "non trovo $R: questa non e' una scheda Raptor?"
for c in tar gzip find python3 sha256sum df awk; do command -v "$c" >/dev/null 2>&1 || die "manca il comando $c"; done
[ -d "$DEST" ] || die "la cartella di destinazione non esiste: $DEST"
[ -w "$DEST" ] || die "non posso scrivere in $DEST"
HOST="$(hostname 2>/dev/null || echo scheda)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$DEST/raptor_scheda_${HOST}_${STAMP}.tar.gz"
ok "programma in $R, destinazione $DEST"
VER="$(grep -hE '^VERSION[[:space:]]*=' "$R/web/web.py" 2>/dev/null | head -1 | sed -E 's/.*["'"'"']([^"'"'"']+)["'"'"'].*/\1/')"
[ -n "$VER" ] && ok "versione del pannello: $VER" || warn "non riesco a leggere la versione del pannello"

STAGE="$(mktemp -d "$DEST/.raptor-salva-XXXXXX")" || die "non riesco a creare la cartella di lavoro in $DEST"
chmod 700 "$STAGE"
VERIFY=""
RESTART=()
cleanup() {
  [ -n "$VERIFY" ] && rm -rf "$VERIFY" 2>/dev/null
  rm -rf "$STAGE" 2>/dev/null
  # se ho fermato dei servizi li riavvio (anche se lo script e' stato interrotto)
  if [ "${#RESTART[@]}" -gt 0 ]; then
    say "  riavvio i servizi che avevo fermato: ${RESTART[*]}"
    for u in "${RESTART[@]}"; do systemctl start "$u" >/dev/null 2>&1 || printf '  non sono riuscito a riavviare %s: fallo a mano (systemctl start %s)\n' "$u" "$u"; done
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$STAGE/_salva/info" "$STAGE/_salva/sqlite" "$STAGE/g"

# ------------------------------------------------------------------------------------------------ 2. cosa salvo
say ""
say "${C_B}[2/6] Cosa salvo${C_0}"
G=0; GNAMES=(); GFILES=()
walk() {   # walk RELATIVO [espressione find da potare...]  ->  "dimensione<TAB>percorso" separati da NUL
  local rel="$1"; shift
  [ -e "$FRX/$rel" ] || [ -L "$FRX/$rel" ] || return 0
  # socket e pipe (FIFO) non si possono archiviare (tar: "Cannot stat") e si ricreano da soli: li salto sempre
  if [ $# -gt 0 ]; then ( cd "$FRX" && find -H "$rel" \( "$@" -o -type s -o -type p \) -prune -o -printf '%s\t%p\0' 2>/dev/null )
  else ( cd "$FRX" && find -H "$rel" \( -type s -o -type p \) -prune -o -printf '%s\t%p\0' 2>/dev/null ); fi
}
group() {  # group NOME  (legge i dati da stdin)
  G=$((G+1)); GNAMES+=("$1"); GFILES+=("$STAGE/g/$G.raw"); cat >"$STAGE/g/$G.raw"
}
PYC=(-name __pycache__ -o -name '*.pyc' -o -name '*.pyo')
group "codice"          < <(walk "$RREL" "${PYC[@]}" -o -path "$RREL/venv" -o -path "$RREL/models" -o -path "$RREL/data" -o -path "$RREL/config")
group "configurazione"  < <(walk "$RREL/config" -name '.tmp-*')
group "modelli"         < <(walk "$RREL/models")
DATA_EXCL=(-path "$RREL/data/events" -o -path "$RREL/data/logs" -o -path "$RREL/data/backups" -o -name '*.db' -o -name '*.db-wal' -o -name '*.db-shm' -o -name '*.db-journal' -o -name '.tmp-*' -o -name '.db-*')
group "dati e stato"    < <(walk "$RREL/data" "${DATA_EXCL[@]}")
[ "$WITH_EVENTS" = 1 ] && group "immagini Events AI" < <(walk "$RREL/data/events" -name '.tmp-*')
[ "$WITH_LOGS" = 1 ]   && group "registri"           < <(walk "$RREL/data/logs" -name '.tmp-*')
[ "$WITH_PANEL" = 1 ]  && group "backup del pannello" < <(walk "$RREL/data/backups")
group "/etc"            < <(walk "etc" -path 'etc/shadow*' -o -path 'etc/gshadow*' -o -name 'ssh_host_*' -o -path 'etc/ssl/private' -o -path etc/machine-id -o -name '.pwd.lock')
group "/usr/local e servizi" < <( walk "usr/local" -type f -size +${BIG_MB}M; walk "var/lib/raptor-admin"; walk "var/spool/cron"; walk "boot/orangepiEnv.txt"; walk "boot/boot.cmd" )
HOME_EXCL=(-name .cache -o -name __pycache__ -o -path '*/.ssh' -o -path '*/.local/share' -o -name node_modules -o -name '.raptor-salva-*' -o -name 'raptor_scheda_*' -o -type f -size +${BIG_MB}M)
group "cartelle personali" < <(
  for h in home/raptor home/orangepi root; do
    walk "$h" "${HOME_EXCL[@]}"
    for k in authorized_keys known_hosts config; do walk "$h/.ssh/$k"; done
  done )

: >"$STAGE/list.null"
TOTAL=0; BASE=0
printf '  %-26s %10s %12s\n' "parte" "file" "dimensione"
for i in "${!GNAMES[@]}"; do
  f="${GFILES[$i]}"
  n="$(tr -cd '\0' <"$f" | wc -c)"
  s="$(awk -v RS='\0' '{i=index($0,"\t"); s+=substr($0,1,i-1)} END{printf "%d", s+0}' "$f")"
  awk -v RS='\0' -v ORS='\0' '{i=index($0,"\t"); print substr($0,i+1)}' "$f" >>"$STAGE/list.null"
  printf '  %-26s %10s %12s\n' "${GNAMES[$i]}" "$n" "$(hum "$s")"
  TOTAL=$((TOTAL+s))
  case "${GNAMES[$i]}" in codice|configurazione|modelli) BASE=$((BASE+s)) ;; esac
done
NFILES="$(tr -cd '\0' <"$STAGE/list.null" | wc -c)"
printf '  %-26s %10s %12s\n' "TOTALE" "$NFILES" "$(hum "$TOTAL")"
[ "$WITH_EVENTS" = 1 ] || say "  (immagini Events AI escluse: --senza-eventi)"
[ "$WITH_LOGS" = 1 ]   || say "  (registri esclusi: --senza-log)"
[ "$WITH_PANEL" = 1 ]  || say "  (backup del pannello esclusi: sono copie di cio' che c'e' gia' qui; --con-backup-pannello per includerli)"
( cd "$FRX" && find home root -type f -size +${BIG_MB}M ! -name 'raptor_scheda_*' -printf '%s\t%p\n' 2>/dev/null | sort -rn ) >"$STAGE/_salva/info/file-grandi-esclusi.txt"
NBIG="$(wc -l <"$STAGE/_salva/info/file-grandi-esclusi.txt")"
if [ "$NBIG" -gt 0 ]; then
  warn "$NBIG file sopra i ${BIG_MB} MB nelle cartelle personali NON entrano nell'archivio (pacchetti, vecchi backup...): elenco qui sotto, copiali a parte se ti servono"
  head -n 12 "$STAGE/_salva/info/file-grandi-esclusi.txt" | awk -F'\t' '{printf "         %10.1f MB  %s\n", $1/1048576, $2}'
fi

# ------------------------------------------------------------------------------------------------ 3. spazio
say ""
say "${C_B}[3/6] Spazio sul disco di destinazione${C_0}"
AVAIL="$(df -PB1 "$DEST" 2>/dev/null | awk 'NR==2{print $4}')"; AVAIL="${AVAIL:-0}"
NEED=$((TOTAL + BASE + 100*1048576))      # archivio (nel caso peggiore non si comprime: JPEG e modelli) + copia di controllo di codice, config e modelli + margine
printf '  libero: %s   serve (al massimo): %s\n' "$(hum "$AVAIL")" "$(hum "$NEED")"
if [ "$AVAIL" -lt "$NEED" ]; then
  bad "spazio insufficiente in $DEST"
  say "      Soluzioni: una chiavetta USB (  --dest /media/NOME  ),  --senza-eventi  (le immagini sono la parte grossa),  oppure libera spazio."
  exit 1
fi
ok "lo spazio basta"
if [ "$CHECK_ONLY" = 1 ]; then say ""; say "Solo controllo: non ho scritto niente."; exit 0; fi

if [ "$ASSUME_YES" != 1 ]; then
  say ""
  printf '  Archivio che creo: %s\n' "$ARCHIVE"
  printf '  Procedo? [S/n] '
  read -r ans </dev/tty 2>/dev/null || ans="s"
  case "${ans:-s}" in n|N|no|NO) say "Annullato: non ho scritto niente."; exit 0 ;; esac
fi

if [ "$STOP_SERVICES" = 1 ]; then
  say ""
  say "  Fermo i servizi Raptor (copia a freddo)..."
  for u in raptor-watchdog raptor-alarm-monitor raptor-detector raptor-notifications raptor-web; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      systemctl stop "$u" >/dev/null 2>&1 && RESTART=("$u" "${RESTART[@]}") || warn "non riesco a fermare $u"
    fi
  done
  ok "fermati: ${RESTART[*]:-nessuno, erano già fermi}"
fi

# ------------------------------------------------------------------------------------------------ 4. fotografie e database
say ""
say "${C_B}[4/6] Fotografie del sistema e copia coerente dei database${C_0}"
INFO="$STAGE/_salva/info"
cap() {   # cap FILE comando...   (non fallisce mai: tutto quello che il comando scrive va nel file)
  local f="$INFO/$1"; shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } >>"$f" || true
}
capsh() { local f="$INFO/$1"; { printf '$ %s\n' "$2"; bash -c "$2" 2>&1; } >>"$f" || true; }
: >"$INFO/sistema.txt"
capsh sistema.txt "tr -d '\\0' <$FR/proc/device-tree/model; echo"
cap sistema.txt uname -a; capsh sistema.txt "cat $FR/etc/os-release $FR/etc/orangepi-release 2>&1"
cap sistema.txt date; cap sistema.txt hostnamectl; cap sistema.txt timedatectl; cap sistema.txt uptime; cap sistema.txt free -m
cap sistema.txt lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT; cap sistema.txt df -h
capsh utenti.txt "getent passwd | awk -F: '\$3==0 || (\$3>=1000 && \$3<60000)'; for u in raptor orangepi root; do id \$u; done; getent group video dialout gpio i2c spi render sudo raptor"
capsh pacchetti.txt "apt-mark showmanual"; capsh pacchetti-tutti.txt "dpkg --get-selections"; capsh pip.txt "pip3 list --format=freeze"
capsh rete.txt "ip addr; ip route; nmcli connection show; nmcli device; ss -ltnup"
capsh servizi.txt "systemctl list-unit-files --no-pager"; capsh servizi.txt "systemctl list-units --all --no-pager 'raptor*'"
capsh servizi.txt "systemctl cat 'raptor-*' --no-pager"; capsh servizi.txt "systemctl list-timers --all --no-pager"
capsh cron.txt "for u in \$(cut -d: -f1 $FR/etc/passwd); do crontab -l -u \$u 2>/dev/null | sed \"s/^/[\$u] /\"; done; ls -l $FR/etc/cron.d"
capsh npu.txt "ls -l $FR/dev | grep -iE 'vip|npu|galcore|cedar|video|dri|gpiochip'; lsmod; ldconfig -p | grep -iE 'viplite|VIPhal|NBGlinker|vipnano|cedarc|ovxlib|openvx|libGAL|libraptor'; dmesg | grep -iE 'vip|npu|galcore' | tail -20"
capsh npu.txt "for l in \$(ldconfig -p | grep -iE 'libVIPhal|libNBGlinker|libraptor_npu' | awk '{print \$NF}' | sort -u); do sha256sum \$l; done"
if command -v tailscale >/dev/null 2>&1; then
  capsh tailscale.txt "tailscale version; tailscale status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"BackendState:\", d.get(\"BackendState\"))'"
else echo "tailscale non installato" >"$INFO/tailscale.txt"; fi
capsh versioni.txt "cd $R && grep -rIn --include='*.py' -E '^VERSION[[:space:]]*=' . | grep -v /tests/"
capsh versioni.txt "cd $R && find . -path ./venv -prune -o -path ./models -prune -o -path ./data -prune -o -path ./config -prune -o -name __pycache__ -prune -o -type f ! -name '*.pyc' -print0 | sort -z | xargs -0 sha256sum"
capsh cartelle-personali.txt "ls -la --time-style=long-iso $FR/home/raptor $FR/home/orangepi $FR/root 2>&1"
capsh journal-raptor.txt "journalctl -u 'raptor-*' --no-pager -n 5000"
capsh modelli.txt "ls -l $R/models; cat $R/models/index.json 2>/dev/null | head -c 20000"
ok "fotografie scritte in _salva/info ($(ls "$INFO" | wc -l) file)"

# database SQLite: copia coerente con l'API di backup (anche a programma acceso)
SQL_OK=0; SQL_BAD=0
: >"$STAGE/dbs.null"
( cd "$FRX" && find -H "$RREL" \( -path "$RREL/venv" -o -name __pycache__ \) -prune -o -type f -name '*.db' -print0 2>/dev/null ) >"$STAGE/dbs.null"
while IFS= read -r -d '' rel; do
  dst="$STAGE/_salva/sqlite/$rel"
  res="$(python3 - "$FRX/$rel" "$dst" <<'PY' 2>&1
import os, sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(dst), exist_ok=True)
last = None
for opener in (lambda: sqlite3.connect("file:%s?mode=ro" % src, uri=True, timeout=30), lambda: sqlite3.connect(src, timeout=30)):
    try:
        a = opener(); b = sqlite3.connect(dst); a.backup(b)
        r = b.execute("PRAGMA integrity_check").fetchone()[0]
        b.close(); a.close()
        print("ok" if r == "ok" else "integrity:" + str(r)); sys.exit(0)
    except Exception as e:
        last = e
print("errore:", type(last).__name__, last)
PY
)"
  if [ "$res" = "ok" ]; then ok "database $rel copiato e controllato"; SQL_OK=$((SQL_OK+1)); else bad "database $rel: $res"; SQL_BAD=$((SQL_BAD+1)); fi
done <"$STAGE/dbs.null"
[ "$SQL_OK$SQL_BAD" = "00" ] && warn "non ho trovato nessun database SQLite (statistics.db): e' normale solo se la scheda non ha mai contato niente"
[ "$SQL_BAD" -eq 0 ] || die "un database non e' stato copiato bene: l'archivio non sarebbe completo"

# ------------------------------------------------------------------------------------------------ 5. archivio
say ""
say "${C_B}[5/6] Creo l'archivio${C_0}"
cat >"$STAGE/_salva/LEGGIMI.txt" <<EOF
RAPTOR AI - SALVATAGGIO DELLA SCHEDA $HOST
Creato il $(date '+%Y-%m-%d %H:%M:%S %z') con raptor-salva-scheda.sh $SCRIPT_VERSION  (pannello $VER)

ATTENZIONE: questo archivio contiene SEGRETI (token Telegram, password e-mail, password Wi-Fi, impronte delle password del pannello).
Tienilo offline e privato. Non incollarlo in una chat, non metterlo in un cloud pubblico.

COSA C'E'
  opt/raptor/            codice, config/ (configurazione), models/ (modelli), data/ (stato, statistiche, Events AI, registri)
  etc/                   la configurazione del sistema (senza shadow, senza chiavi host SSH)
  usr/local/  var/lib/raptor-admin/  var/spool/cron/  boot/orangepiEnv.txt
  home/raptor  home/orangepi  root/   le cartelle personali (file sotto i ${BIG_MB} MB)
  _salva/info/           fotografie in testo: pacchetti, rete, servizi, cron, NPU, versioni, ultimi registri
  _salva/sqlite/         copia coerente dei database (usa queste, non i .db sotto opt/raptor/data)
  _salva/MANIFEST.sha256 impronte dei file principali (codice, config, modelli, database)

COSA NON C'E'
  password di sistema (shadow), chiavi host SSH, chiave del nodo Tailscale, chiavi private in ~/.ssh,
  backup del pannello (se non chiesti), file sopra i ${BIG_MB} MB nelle cartelle personali (elenco in _salva/info/file-grandi-esclusi.txt)

COME SI LEGGE (senza toccare niente)
  mkdir /tmp/vecchia && tar -xzf FILE.tar.gz -C /tmp/vecchia --no-same-owner
  una cosa sola:  tar -xzf FILE.tar.gz -C /tmp/vecchia --no-same-owner opt/raptor/config
  controllo delle impronte (dopo aver estratto codice, config, modelli e _salva):
                  cd /tmp/vecchia && sha256sum -c --quiet _salva/MANIFEST.sha256

NON ripristinare tutto sopra una scheda nuova: serve per consultare e riprendere pezzi singoli.
Per una scheda nuova si usa la procedura di installazione, poi il ripristino dal pannello (Settings > Maintenance).
EOF
# impronte dei file principali: codice, config, modelli (letti ora dal disco) + le copie dei database
{
  for i in "${!GNAMES[@]}"; do
    case "${GNAMES[$i]}" in codice|configurazione|modelli)
      awk -v RS='\0' -v ORS='\0' '{i=index($0,"\t"); print substr($0,i+1)}' "${GFILES[$i]}" ;;
    esac
  done | ( cd "$FRX" && xargs -0 -r sh -c 'for f; do if [ -f "$f" ] && [ ! -L "$f" ]; then sha256sum -b -- "$f"; fi; done' _ )
  ( cd "$STAGE" && find _salva/sqlite -type f -print0 2>/dev/null | xargs -0 -r sha256sum -b )
} >"$STAGE/_salva/MANIFEST.sha256"
NMAN="$(wc -l <"$STAGE/_salva/MANIFEST.sha256")"

# l'elenco e' stato fatto prima di fermare i servizi: alcuni file (socket, pid, temporanei) spariscono quando un servizio si ferma.
# Tolgo dall'elenco quelli che non ci sono piu', cosi' tar non si ferma su un file che non esiste.
N0="$NFILES"
( cd "$FRX" && xargs -0 -r sh -c 'for f; do if [ -e "$f" ] || [ -L "$f" ]; then printf "%s\0" "$f"; fi; done' _ <"$STAGE/list.null" ) >"$STAGE/list2.null"
mv -f "$STAGE/list2.null" "$STAGE/list.null"
NFILES="$(tr -cd '\0' <"$STAGE/list.null" | wc -c)"
[ "$NFILES" -lt "$N0" ] && say "  (file spariti da soli dopo l'elenco, per esempio perche' un servizio e' stato fermato: $((N0-NFILES)); li salto)"

PART="$ARCHIVE.part"
( umask 077; : >"$PART" )
GZ=(gzip -3); command -v pigz >/dev/null 2>&1 && GZ=(pigz -3)
say "  scrivo $(basename "$ARCHIVE") ($NFILES file, $(hum "$TOTAL") prima della compressione)..."
( set -o pipefail; tar -c --null --no-recursion --numeric-owner -f - -C "$FRX" -T "$STAGE/list.null" --recursion -C "$STAGE" _salva | "${GZ[@]}" >"$PART" )
RC=$?
if [ "$RC" -eq 0 ]; then ok "archivio scritto"
elif [ "$RC" -eq 1 ]; then warn "alcuni file sono cambiati mentre li leggevo (normale a servizi accesi: sono registri o stato). Per una copia perfetta usa --ferma-servizi"
else rm -f "$PART"; die "tar e' fallito (codice $RC): archivio non creato. Spazio finito? Permessi?"; fi
mv -f "$PART" "$ARCHIVE" && chmod 600 "$ARCHIVE"

# ------------------------------------------------------------------------------------------------ 6. verifica
say ""
say "${C_B}[6/6] Verifica dell'archivio${C_0}"
if gzip -t "$ARCHIVE" 2>/dev/null; then ok "il file compresso e' integro"; else die "il file compresso e' danneggiato: rifai il salvataggio"; fi
NENT="$(tar -tzf "$ARCHIVE" 2>/dev/null | wc -l)"
if [ "$NENT" -ge "$NFILES" ]; then ok "$NENT voci nell'archivio (attese almeno $NFILES)"; else die "nell'archivio ci sono $NENT voci ma ne attendevo $NFILES"; fi
VERIFY="$(mktemp -d "$DEST/.raptor-verifica-XXXXXX")"
if tar -xzf "$ARCHIVE" -C "$VERIFY" --no-same-owner --exclude="$RREL/data/events" --exclude="$RREL/data/logs" --exclude="$RREL/data/backups" "$RREL" _salva 2>/dev/null; then
  BADN=0
  while read -r h p; do
    p="${p#\*}"
    [ -f "$VERIFY/$p" ] || { BADN=$((BADN+1)); continue; }
    [ "$(sha256sum -b "$VERIFY/$p" | cut -c1-64)" = "$h" ] || BADN=$((BADN+1))
  done < <(grep -v '^$' "$STAGE/_salva/MANIFEST.sha256")
  if [ "$BADN" -eq 0 ]; then ok "impronte controllate: $NMAN file principali (codice, config, modelli, database) identici all'originale"
  else warn "$BADN file principali dell'archivio non coincidono con l'originale (cambiati mentre li copiavo?): rifai con --ferma-servizi"; fi
else
  warn "non sono riuscito a estrarre l'archivio per il controllo delle impronte (poco spazio?): il file e' comunque integro"
fi
rm -rf "$VERIFY"; VERIFY=""

( cd "$DEST" && sha256sum -b "$(basename "$ARCHIVE")" >"$(basename "$ARCHIVE").sha256" )
OWNER="$(stat -c '%u:%g' "$DEST")"
chown "$OWNER" "$ARCHIVE" "$ARCHIVE.sha256" 2>/dev/null || true
chmod 600 "$ARCHIVE" "$ARCHIVE.sha256" 2>/dev/null || true

say ""
say "${C_B}FATTO${C_0}"
say "  Archivio : $ARCHIVE   ($(hum "$(stat -c %s "$ARCHIVE")"))"
say "  sha256   : $(cut -c1-64 "$ARCHIVE.sha256")"
say ""
say "  Contiene SEGRETI: resta privato, non incollarlo in chat. Portalo sul tuo computer con FileZilla (sftp, utente raptor)"
say "  e controlla l'impronta:  sha256sum -c $(basename "$ARCHIVE").sha256"
say "  Copia anche a parte i file grandi elencati sopra (se ce ne sono)."
[ "$WARNS" -eq 0 ] || say "  Avvisi: $WARNS (vedi le righe [WARN])"

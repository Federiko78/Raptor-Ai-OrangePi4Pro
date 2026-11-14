#!/usr/bin/env bash
# =====================================================================================================================
# raptor-02-installa.sh  -  Raptor AI 0.16.10  -  PASSO 2 di 2: password, ambiente e installazione di Raptor dal pacchetto
#
# Prima di questo hai fatto:  raptor-01-utente.sh  (l'utente raptor e le sue cartelle). Ora sei entrato come RAPTOR e hai copiato
# in /home/raptor: questo script, il pacchetto raptor_full_0.16.10_*.tar.gz (con il suo .sha256) e, se il pacchetto e' quello
# "senza modelli", i modelli in /opt/raptor/models.
#
# Cosa fa, in dodici passi (e dice sempre cosa sta facendo):
#    1. controlla l'ambiente e il pacchetto (non cambia nulla); poi ti chiede conferma
#    2. cambia le password di root e orangepi (oggi sono quelle di fabbrica): le scrivi TU, nascoste
#    3. nome della scheda, fuso orario, sincronizzazione dell'ora (chrony)
#    4. blocca gli aggiornamenti automatici del sistema (apt-daily/unattended-upgrades) e il pacchetto del kernel
#    5. installa i pacchetti che mancano (ffmpeg, numpy, opencv, yaml, cryptography, gcc, nftables, ...)
#    6. crea l'ambiente virtuale Python
#    7. installa Tailscale (assistenza remota dal pannello): di serie si', --no-tailscale per non installarlo
#    8. verifica il pacchetto, lo estrae in /opt/raptor e controlla ogni file (MANIFEST.sha256)
#    9. compila la libreria NPU (libraptor_npu.so)
#   10. controlla i modelli (quelli del pacchetto, o copiati con FileZilla) e li sistema
#   11. installa raptor-auth e raptor-admin; Telegram (se vuoi: token del bot e destinatari, digitati da te)
#   12. installa e avvia i 5 servizi, controlla che tutto sia acceso e ti dice l'indirizzo del pannello
#
# L'amministratore del pannello NON lo crea lo script: lo crei dalla pagina web di Raptor (prima la licenza, poi la password).
# Non fa "apt upgrade", e dal passo 4 blocca anche gli aggiornamenti automatici in background: su queste schede un
# aggiornamento del kernel o dei driver (anche se arriva da solo di notte) puo' rompere l'NPU -- deve essere sempre
# una scelta esplicita, mai qualcosa che succede senza che nessuno lo decida.
# Si puo' rilanciare: se Raptor e' gia' installato con la stessa versione rifa' i passi (config, dati e modelli non si toccano);
# con un'altra versione si ferma: per aggiornare usa il pacchetto di aggiornamento, oppure --force.
#
# Uso (sulla scheda, come utente raptor: lo script si fa dare i permessi di root chiedendoti la password di root,
# che su una scheda nuova e' quella di fabbrica; il passo 2 la cambia subito):
#     bash /home/raptor/raptor-02-installa.sh
#
# Opzioni:
#     --check-only         controlla e basta (nessuna modifica, nessuna domanda)
#     --tar FILE           il pacchetto da installare (di serie lo cerco da solo: raptor_full_*.tar.gz accanto allo script)
#     --hostname NOME      nome della scheda, senza chiederlo (minuscole, cifre e trattino; es. raptor-02)
#     --timezone ZONA      fuso orario (predefinito: Europe/Rome)
#     --no-passwords       non cambia le password di root e orangepi (le controlla soltanto)
#     --no-tailscale       non installare Tailscale
#     --telegram           configura Telegram senza chiederlo          --no-telegram: non chiederlo
#     --no-npu-build       non compilare la libreria NPU
#     --yes                risponde con la scelta predefinita alle domande si/no (password, nome e Telegram restano a te)
#     --force              prosegue anche se la scheda non sembra una Orange Pi 4 Pro con Debian 12, o se Raptor c'e' gia'
#     --help
#
# Un registro (senza password ne' token) resta in /root/raptor-installa-DATA.log
# =====================================================================================================================
set -u -o pipefail

SCRIPT_VERSION="3.0.0"
ORIG_ARGS=("$@")
ELEVATED=0
RAPTOR_USER="raptor"
R="${RAPTOR_ROOT:-/opt/raptor}"
PANEL_PORT="${RAPTOR_PANEL_PORT:-5000}"
TIMEZONE="Europe/Rome"
WANT_HOSTNAME=""
TAR=""
CHECK_ONLY=0
TAILSCALE="yes"                        # yes (di serie) | no
TELEGRAM="ask"                         # ask | yes | no
NPU_BUILD=1
ASSUME_YES=0
FORCE=0
NSTEPS=12
SKIP_PASSWORDS=0

# librerie NPU dell'immagine della scheda di riferimento (solo per dire se sono uguali o diverse)
REF_VIPHAL="648444a26a1aeaec0182c0ba348b7a453134b8ccdf8282a211ce4c0f5e5e51a0"
REF_NBGLINKER="de93bb4a7d86af67bc4ca597d12228b9b21b062601b18f33ca30393a2af4a842"

PKGS=(ca-certificates curl openssl iproute2 iputils-ping nftables chrony network-manager
      python3 python3-venv python3-numpy python3-opencv python3-yaml python3-cryptography
      ffmpeg gcc libc6-dev)

usage() { awk 'NR==1{next} /^# =+$/{n++; if(n==2) exit; next} n==1{sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --tar) shift; TAR="${1:-}" ;;
    --hostname) shift; WANT_HOSTNAME="${1:-}" ;;
    --timezone) shift; TIMEZONE="${1:-}" ;;
    --no-passwords|--skip-passwords) SKIP_PASSWORDS=1 ;;
    --no-tailscale) TAILSCALE="no" ;;
    --with-tailscale) TAILSCALE="yes" ;;          # gia' il comportamento di serie
    --telegram) TELEGRAM="yes" ;;
    --no-telegram) TELEGRAM="no" ;;
    --no-npu-build) NPU_BUILD=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    --elevated) ELEVATED=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'Opzione sconosciuta: %s  (vedi --help)\n' "$1" >&2; exit 2 ;;
    *) if [ -z "$TAR" ]; then TAR="$1"; else printf 'Un solo pacchetto alla volta: "%s" di troppo.\n' "$1" >&2; exit 2; fi ;;
  esac
  shift
done

# ------------------------------------------------------------------------------------------------ voci a video e nel registro
if [ -t 1 ]; then C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'; else C_OK=""; C_WARN=""; C_BAD=""; C_B=""; C_0=""; fi
LOG="/dev/null"
N_OK=0; N_WARN=0; N_BAD=0
WARNS=(); BADS=()

emit()  { printf '%s\n' "$1"; printf '%s\n' "$2" | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG" 2>/dev/null || true; }
say()   { emit "$*" "$*"; }
head1() { emit "" ""; emit "${C_B}== $* ==${C_0}" "== $* =="; }
step()  { head1 "Passo $1 di $NSTEPS - $2"; }
ok()    { N_OK=$((N_OK+1));     emit "  ${C_OK}[ OK ]${C_0} $*" "  [ OK ] $*"; }
warn()  { N_WARN=$((N_WARN+1)); WARNS+=("$*"); emit "  ${C_WARN}[WARN]${C_0} $*" "  [WARN] $*"; }
bad()   { N_BAD=$((N_BAD+1));   BADS+=("$*");  emit "  ${C_BAD}[FAIL]${C_0} $*" "  [FAIL] $*"; }
info()  { emit "         $*" "         $*"; }
die()   { emit "${C_BAD}ERRORE:${C_0} $*" "ERRORE: $*"; exit 1; }

ask_yn() {      # ask_yn "domanda" s|n   -> 0 = si
  local q="$1" def="${2:-n}" a hint="[s/N]"
  [ "$def" = s ] && hint="[S/n]"
  if [ "$ASSUME_YES" = 1 ]; then [ "$def" = s ]; return; fi
  printf '  %s %s ' "$q" "$hint" >&2
  IFS= read -r a || a=""
  printf '%s %s -> %s\n' "$q" "$hint" "${a:-(predefinito: $def)}" >>"$LOG" 2>/dev/null || true
  case "${a:-$def}" in s|S|si|SI|Si|y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask_text() {    # ask_text "domanda" "predefinito" -> $REPLY_TEXT   (le risposte NON segrete vanno nel registro)
  local q="$1" def="${2:-}" a
  printf '  %s%s ' "$q" "${def:+ [INVIO = $def]}" >&2
  IFS= read -r a || a=""
  REPLY_TEXT="${a:-$def}"
  printf '%s -> %s\n' "$q" "$REPLY_TEXT" >>"$LOG" 2>/dev/null || true
}

ask_private() { # come ask_text ma la risposta NON va nel registro (chat ID)
  local q="$1" a
  printf '  %s ' "$q" >&2
  IFS= read -r a || a=""
  REPLY_TEXT="$a"
}

ask_secret() {  # ask_secret "domanda" -> $SECRET_TEXT (non va mai nel registro)
  local a
  printf '  %s ' "$1" >&2
  IFS= read -rs a || a=""; printf '\n' >&2
  SECRET_TEXT="$a"
}

as_raptor() { ( cd / && runuser -u "$RAPTOR_USER" -- env RAPTOR_ROOT="$R" "$@" ); }

todo() {        # todo bad|warn "testo" PASSO: con --check-only e' un problema; altrimenti lo sistema il passo indicato, quindi non conta
  if [ "$CHECK_ONLY" = 1 ]; then "$1" "$2"; else info "[lo sistemo al passo $3] $2"; fi
}

pw_state() {    # pw_state UTENTE -> default | custom | locked | none | missing | unknown
  local user="$1"
  python3 - "$user" <<'PY' 2>/dev/null || echo unknown
import sys
user = sys.argv[1]
defaults = {"root": ["orangepi", "root", "orangepi4pro"], "orangepi": ["orangepi"], "raptor": ["raptor", "orangepi"]}.get(user, [user])
try:
    import crypt
except ImportError:
    print("unknown"); sys.exit(0)
try:
    lines = open("/etc/shadow", encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    print("unknown"); sys.exit(0)
for line in lines:
    f = line.split(":")
    if f[0] != user:
        continue
    h = f[1] if len(f) > 1 else ""
    if h == "":
        print("none"); sys.exit(0)
    if h[0] in "!*":
        print("locked"); sys.exit(0)
    for d in defaults:
        try:
            if crypt.crypt(d, h) == h:
                print("default"); sys.exit(0)
        except Exception:
            print("unknown"); sys.exit(0)
    print("custom"); sys.exit(0)
print("missing")
PY
}

# ------------------------------------------------------------------------------------------------ password
PW_DEFAULTS="orangepi root raptor password 12345678 123456789 orangepi4pro admin"
PW_RESULT=""
pw_problem() {  # pw_problem UTENTE PASSWORD -> scrive il problema, vuoto se va bene
  local who="$1" pw="$2" d
  if [ "${#pw}" -lt 8 ]; then printf 'troppo corta (almeno 8 caratteri, meglio 12 o piu)'; return; fi
  if [ "${#pw}" -gt 128 ]; then printf 'troppo lunga (al massimo 128 caratteri)'; return; fi
  if [ "$pw" = "$who" ]; then printf 'uguale al nome utente'; return; fi
  for d in $PW_DEFAULTS; do
    if [ "$pw" = "$d" ]; then printf 'e'"'"' una password troppo comune o di fabbrica'; return; fi
  done
  printf ''
}

ask_new_password() {   # ask_new_password UTENTE  -> 0 e $PW_RESULT; 1 = saltata (INVIO a vuoto)
  local who="$1" tries=0 p1 p2 prob
  PW_RESULT=""
  while [ "$tries" -lt 3 ]; do
    tries=$((tries+1))
    printf '  Nuova password per %s (INVIO a vuoto = salta): ' "$who" >&2
    IFS= read -rs p1 || p1=""; printf '\n' >&2
    [ -z "$p1" ] && { printf 'password di %s: saltata\n' "$who" >>"$LOG" 2>/dev/null || true; return 1; }
    prob="$(pw_problem "$who" "$p1")"
    if [ -n "$prob" ]; then printf '  Non va bene: %s. Riprova.\n' "$prob" >&2; continue; fi
    printf '  Ripetila: ' >&2
    IFS= read -rs p2 || p2=""; printf '\n' >&2
    if [ "$p1" != "$p2" ]; then printf '  Le due password non sono uguali. Riprova.\n' >&2; continue; fi
    PW_RESULT="$p1"
    return 0
  done
  return 1
}

set_password() {   # set_password UTENTE PASSWORD
  printf '%s:%s\n' "$1" "$2" | chpasswd
}

# ------------------------------------------------------------------------------------------------ inizio
printf '%s\n' "${C_B}Raptor AI - passo 2 di 2: password, ambiente e installazione (script $SCRIPT_VERSION)${C_0}"
[ "$(id -u)" -eq 0 ] || {
  ABS="$(readlink -f -- "$0")"
  if [ "$ELEVATED" = 1 ]; then printf 'Non sono riuscito a diventare root con su: controlla la password di root e rilancia.\n' >&2; exit 1; fi
  printf 'Servono i permessi di root: ti chiedo la password di root (su -).\n' >&2
  ARGS=""; for a in "${ORIG_ARGS[@]}"; do ARGS="$ARGS $(printf '%q' "$a")"; done
  exec su - -c "bash $(printf '%q' "$ABS")$ARGS --elevated"
}
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
LOG="/root/raptor-installa-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG" && chmod 600 "$LOG"
say "Registro (senza password ne' token): $LOG"
[ "$CHECK_ONLY" = 1 ] && say "Modo --check-only: controllo e basta, non cambio nulla."
on_interrupt() { printf '\nInterrotto: quello che e'"'"' gia'"'"' stato fatto resta; puoi rilanciare lo script.\n' >&2; exit 130; }
trap on_interrupt INT TERM

# ================================================================================================ 1. controlli
step 1 "Controllo dell'ambiente e del pacchetto"

ARCH="$(uname -m)"
if [ "$ARCH" = "aarch64" ]; then ok "architettura aarch64"
elif [ "$FORCE" = 1 ]; then warn "architettura $ARCH, non aarch64 (--force: continuo lo stesso)"
else bad "architettura $ARCH (serve aarch64: questa non e' una Orange Pi 4 Pro)"; fi

MODEL=""
[ -r /proc/device-tree/model ] && MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
case "$MODEL" in
  *[Oo]range*) ok "scheda: $MODEL" ;;
  *sun60iw2*)  ok "scheda: $MODEL (e' il nome del processore Allwinner A733 della Orange Pi 4 Pro)" ;;
  "") warn "il modello della scheda non e' leggibile (/proc/device-tree/model)" ;;
  *) warn "scheda: $MODEL (non riconosco il nome: controlla che sia una Orange Pi 4 Pro)" ;;
esac

OSNAME="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-sconosciuto}")"
OSID="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
OSVER="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
if [ "$OSID" = "debian" ] && [ "$OSVER" = "12" ]; then ok "sistema: $OSNAME (Debian 12, come la scheda di riferimento)"
elif [ "$FORCE" = 1 ]; then warn "sistema: $OSNAME, non Debian 12 (--force: continuo lo stesso)"
else bad "sistema: $OSNAME (Raptor e' provato su Debian 12 'bookworm')"; fi

if command -v sshd >/dev/null 2>&1; then
  PRL="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')"
  case "$PRL" in
    yes) warn "SSH: root puo' entrare con la password (PermitRootLogin yes). Consigliato 'no' dopo aver cambiato la password: non lo modifico io" ;;
    "") : ;;
    *) ok "SSH: PermitRootLogin $PRL" ;;
  esac
fi

KERNEL="$(uname -r)"
case "$KERNEL" in
  *sun60iw2*) ok "kernel $KERNEL (BSP Allwinner A733, quello con i driver NPU)" ;;
  *) warn "kernel $KERNEL: non e' il BSP sun60iw2 della scheda di riferimento (l'NPU potrebbe non esserci)" ;;
esac

MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${MEM_MB:-0}" -ge 3500 ]; then ok "memoria ${MEM_MB} MB"; else warn "memoria ${MEM_MB} MB (la scheda di riferimento ne ha circa 5800)"; fi

mkdir -p "$(dirname "$R")" 2>/dev/null || true
FREE_MB=$(df -Pm "$(dirname "$R")" 2>/dev/null | awk 'NR==2{print $4}')
if [ "${FREE_MB:-0}" -ge 8000 ]; then ok "spazio libero su $(dirname "$R"): ${FREE_MB} MB"
elif [ "${FREE_MB:-0}" -ge 3000 ]; then warn "spazio libero su $(dirname "$R"): ${FREE_MB} MB (poco: filmati e foto degli eventi crescono)"
else bad "spazio libero su $(dirname "$R"): ${FREE_MB:-?} MB (servono almeno 3000)"; fi

PYV="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
case "$PYV" in
  3.9|3.1[0-9]) ok "python3 $PYV" ;;
  "") bad "python3 non trovato" ;;
  *) warn "python3 $PYV (provato con 3.11)" ;;
esac

YEAR="$(date +%Y)"
if [ "$YEAR" -ge 2026 ]; then ok "data e ora del sistema: $(date '+%Y-%m-%d %H:%M %Z')"
else bad "l'orologio dice $(date '+%Y-%m-%d %H:%M'): e' sbagliato. apt e i certificati falliranno. Imposta l'ora:  date -s 'AAAA-MM-GG HH:MM:SS'  e rilancia"; fi

NET=0
if getent hosts deb.debian.org >/dev/null 2>&1 && timeout 6 bash -c 'exec 3<>/dev/tcp/deb.debian.org/80' 2>/dev/null; then
  NET=1; ok "rete e DNS: deb.debian.org raggiungibile"
else
  warn "rete o DNS: deb.debian.org non raggiungibile (servono per installare i pacchetti che mancano)"
fi

# NPU
if [ -e /sys/module/vipcore ] || lsmod 2>/dev/null | grep '^vipcore' >/dev/null; then ok "driver NPU (vipcore) caricato"; else bad "driver NPU 'vipcore' non caricato: senza non c'e' inferenza"; fi
if [ -c /dev/vipcore ]; then ok "/dev/vipcore presente"; else bad "/dev/vipcore manca"; fi
for lib in libVIPhal.so libNBGlinker.so; do
  p="/usr/lib/$lib"
  if [ -f "$p" ]; then
    sum="$(sha256sum "$p" | cut -d' ' -f1)"
    ref="$REF_VIPHAL"; [ "$lib" = libNBGlinker.so ] && ref="$REF_NBGLINKER"
    if [ "$sum" = "$ref" ]; then ok "$p presente, identica a quella della scheda di riferimento"
    else warn "$p presente ma DIVERSA da quella della scheda di riferimento (immagine piu' recente?): dopo l'installazione provo l'NPU"; fi
  else
    bad "$p manca (viene dall'immagine della scheda: Raptor non la porta)"
  fi
done
if [ -c /dev/cedar_dev ]; then ok "/dev/cedar_dev presente (decodifica video hardware, non ancora usata da Raptor)"; else info "/dev/cedar_dev non presente (non serve)"; fi
if ls /dev/gpiochip* >/dev/null 2>&1; then ok "GPIO: $(ls /dev/gpiochip* | tr '\n' ' ')"; else warn "nessun /dev/gpiochip*: allarme e relè non funzioneranno"; fi
for d in /sys/class/devfreq/*npu*; do [ -e "$d" ] && info "NPU devfreq: $(basename "$d") $(cat "$d/governor" 2>/dev/null) $(awk '{printf "%d MHz", $1/1000000}' "$d/cur_freq" 2>/dev/null)"; done

# il passo 1 (utenti e cartelle)
PREREQ=1
if getent group "$RAPTOR_USER" >/dev/null && id "$RAPTOR_USER" >/dev/null 2>&1; then ok "utente e gruppo $RAPTOR_USER presenti"
else bad "manca l'utente $RAPTOR_USER: lancia prima  bash $SCRIPT_DIR/raptor-01-utente.sh  (da orangepi)"; PREREQ=0; fi
if [ -d "$R/config" ] && [ -d "$R/data" ] && [ -d "$R/models" ]; then ok "cartelle di $R presenti (config, data, models)"
else bad "mancano le cartelle di $R: lancia prima  bash $SCRIPT_DIR/raptor-01-utente.sh  (da orangepi)"; PREREQ=0; fi
for u in root orangepi; do
  id "$u" >/dev/null 2>&1 || continue
  case "$(pw_state "$u")" in
    default) todo warn "la password di $u e' ancora quella di fabbrica" 2 ;;
    custom)  ok "la password di $u non e' quella di fabbrica" ;;
  esac
done

# il pacchetto
find_tar() {
  local d f
  [ -n "$TAR" ] && return 0
  for d in "$SCRIPT_DIR" "$(pwd)" "/home/$RAPTOR_USER" /home/orangepi /root; do
    [ -d "$d" ] || continue
    for f in "$d"/raptor_full_*_con_modelli.tar.gz; do [ -f "$f" ] && { TAR="$f"; return 0; }; done     # il pacchetto con i modelli, se c'e', e' il piu' completo
    for f in $(ls -t "$d"/raptor_full_*.tar.gz 2>/dev/null); do TAR="$f"; return 0; done
  done
  return 1
}
HAS_MANIFEST=0; VER=""; NB_TAR0=$N_BAD; TAR_MODELS=0
if ! find_tar; then
  bad "non trovo il pacchetto raptor_full_*.tar.gz (cercato in $SCRIPT_DIR). Copialo con FileZilla in quella cartella, insieme al file .sha256, e rilancia"
elif [ ! -f "$TAR" ]; then
  bad "il file '$TAR' non esiste"
else
  TAR="$(readlink -f -- "$TAR")"
  NTAR="$(ls "$(dirname "$TAR")"/raptor_full_*.tar.gz 2>/dev/null | wc -l)"
  [ "$NTAR" -gt 1 ] && warn "in $(dirname "$TAR") ci sono $NTAR pacchetti raptor_full_*.tar.gz: uso $(basename "$TAR") (di preferenza quello con i modelli). Per sceglierne un altro:  --tar FILE"
  if ! tar tzf "$TAR" >/dev/null 2>&1; then
    bad "'$TAR' non e' un archivio .tar.gz valido (copia incompleta? ricopialo con FileZilla in modo binario)"
  else
    ok "pacchetto: $TAR ($(du -h "$TAR" | cut -f1))"
    SUMFILE="$TAR.sha256"
    GOT="$(sha256sum "$TAR" | cut -d' ' -f1)"
    if [ -f "$SUMFILE" ]; then
      WANT="$(awk '{print $1; exit}' "$SUMFILE")"
      if [ "$GOT" = "$WANT" ]; then ok "somma sha256 del pacchetto uguale a quella del file .sha256"
      else bad "la somma sha256 del pacchetto NON corrisponde (copia danneggiata?): attesa $WANT, trovata $GOT. Ricopialo con FileZilla in modo binario"; fi
    else
      warn "manca $SUMFILE: non posso verificare la copia. Somma calcolata: $GOT"
    fi
    LIST="$(tar tzf "$TAR")"
    if grep -Ev '^opt(/|$)' <<<"$LIST" >/dev/null; then bad "il pacchetto contiene percorsi fuori da opt/: non e' un pacchetto Raptor"
    elif grep -E '(^|/)\.\.(/|$)|^/' <<<"$LIST" >/dev/null; then bad "il pacchetto contiene percorsi pericolosi (.. o assoluti): non lo installo"
    else
      MISS=""
      for f in opt/raptor/web/web.py opt/raptor/services/raptor_services.py opt/raptor/services/admin/install.py opt/raptor/bin/raptor-auth opt/raptor/bin/raptor-models opt/raptor/detector/engine.py opt/raptor/detector/npu/build.sh; do
        grep -qx "$f" <<<"$LIST" || MISS="$MISS $f"
      done
      if [ -n "$MISS" ]; then bad "nel pacchetto mancano:$MISS (non e' un pacchetto Raptor completo)"
      else
        VER="$(tar -xzOf "$TAR" opt/raptor/web/web.py 2>/dev/null | sed -n 's/^VERSION *= *"\(.*\)".*/\1/p' | head -1)"
        if [ -n "$VER" ]; then ok "pacchetto Raptor versione $VER"; else bad "non riesco a leggere la versione dal pacchetto"; fi
        grep -qx 'opt/raptor/MANIFEST.sha256' <<<"$LIST" && HAS_MANIFEST=1
        TAR_MODELS="$(grep -cE '^opt/raptor/models/[^/]+/model\.nb$' <<<"$LIST")"
        if [ "$TAR_MODELS" -gt 0 ]; then ok "il pacchetto contiene $TAR_MODELS modelli"; else info "il pacchetto non contiene modelli (e' quello \"senza modelli\"): devono stare in $R/models, copiati con FileZilla"; fi
        grep -qx 'opt/raptor/native/vendor/include/vip_lite.h' <<<"$LIST" && ok "il pacchetto contiene le intestazioni del produttore per l'NPU" || warn "il pacchetto non contiene vip_lite.h: la libreria NPU non si potra' compilare"
      fi
    fi
  fi
fi

TAR_PROBLEMS=$((N_BAD - NB_TAR0))

if [ -f "$R/web/web.py" ]; then
  OLD="$(sed -n 's/^VERSION *= *"\(.*\)".*/\1/p' "$R/web/web.py" | head -1)"
  if [ -n "$VER" ] && [ "${OLD:-}" = "$VER" ]; then
    info "Raptor $OLD e' gia' installato in $R (stessa versione del pacchetto): rifaccio i passi; il programma viene riscritto uguale, config, dati e modelli non si toccano"
  elif [ "$FORCE" != 1 ] && [ "$CHECK_ONLY" != 1 ]; then
    die "in $R c'e' gia' Raptor ${OLD:-?}, il pacchetto e' la ${VER:-?}. Questo script e' per la prima installazione.
       Per aggiornare:   usa il pacchetto di aggiornamento della versione (non questo script)
       Per sostituire il programma con questo pacchetto (config, dati e modelli restano):  rilancia con --force"
  else
    warn "Raptor ${OLD:-?} e' gia' installato in $R: con --force lo sostituisco con la ${VER:-?} (config, dati e modelli non si toccano)"
  fi
fi

MISSING=()
for p in "${PKGS[@]}"; do
  [ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] || MISSING+=("$p")
done
if [ "${#MISSING[@]}" -eq 0 ]; then ok "tutti i pacchetti necessari sono gia' installati"
else todo warn "pacchetti da installare: ${MISSING[*]}" 4; fi

NMODELS_NOW="$(find "$R/models" -maxdepth 3 \( -name '*.nb' \) 2>/dev/null | wc -l)"
if [ "$NMODELS_NOW" -gt 0 ]; then ok "in $R/models ci sono $NMODELS_NOW file .nb"
elif [ "$TAR_MODELS" -gt 0 ]; then info "in $R/models non ci sono ancora modelli: arrivano dal pacchetto"
else warn "in $R/models non ci sono modelli e il pacchetto non li contiene: copiali con FileZilla (senza modelli non c'e' rilevamento). Puoi anche farlo dopo: rilanciando questo script rifa' solo quello che manca"; fi

if [ "$CHECK_ONLY" = 1 ]; then
  head1 "Riepilogo (--check-only: nessuna modifica fatta)"
  say "OK: $N_OK   da guardare: $N_WARN   problemi: $N_BAD"
  for w in "${BADS[@]:-}"; do [ -n "$w" ] && say "  [FAIL] $w"; done
  for w in "${WARNS[@]:-}"; do [ -n "$w" ] && say "  [WARN] $w"; done
  exit $([ "$N_BAD" -eq 0 ] && echo 0 || echo 1)
fi

# i problemi che rendono inutile andare avanti
STOP=0
[ "$PREREQ" = 1 ] || die "manca il lavoro del passo 1. Lancia prima, da orangepi:  bash $SCRIPT_DIR/raptor-01-utente.sh"
[ -n "$VER" ] && [ -f "$TAR" ] || die "manca il pacchetto, o non e' valido (vedi sopra)."
[ "$TAR_PROBLEMS" -eq 0 ] || die "il pacchetto non passa i controlli (vedi sopra)."
case "$ARCH" in aarch64) ;; *) STOP=1 ;; esac
{ [ "$OSID" = "debian" ] && [ "$OSVER" = "12" ]; } || STOP=1
if [ "$STOP" = 1 ] && [ "$FORCE" != 1 ]; then
  die "questa non sembra una Orange Pi 4 Pro con Debian 12. Se sai cosa fai, rilancia con --force."
fi
if [ "$YEAR" -lt 2026 ] && [ "$FORCE" != 1 ]; then die "l'orologio e' sbagliato: sistemalo (date -s ...) e rilancia."; fi
if [ ! -f /usr/lib/libVIPhal.so ] || [ ! -f /usr/lib/libNBGlinker.so ]; then
  warn "senza le librerie NPU dell'immagine la libreria NPU non si compila e il motore parte senza NPU"
fi

say ""
say "  Installo Raptor $VER in $R, con i 5 servizi all'avvio della scheda."
say "  Pacchetto: $TAR"
ask_yn "Procedo?" s || die "interrotto, non ho cambiato nulla"

# ================================================================================================ 2. password
step 2 "Password di root e orangepi"
if [ "$SKIP_PASSWORDS" = 1 ]; then
  say "  (--no-passwords: non cambio nessuna password)"
else
  say "  Scrivi tu le nuove password: restano nascoste e non finiscono nel registro. Almeno 8 caratteri; le password comuni (orangepi, root, password...) vengono rifiutate."
  for u in root orangepi; do
    id "$u" >/dev/null 2>&1 || continue
    st="$(pw_state "$u")"
    case "$st" in
      default) say "  $u: la password e' ancora quella di fabbrica: va cambiata." ;;
      locked|none) say "  $u: non ha una password utilizzabile: ne serve una." ;;
      custom) ask_yn "$u ha gia' una password diversa da quella di fabbrica. La cambio lo stesso?" n || { ok "password di $u lasciata com'e'"; continue; } ;;
      *) ask_yn "Non riesco a verificare la password di $u. La cambio?" s || continue ;;
    esac
    if ask_new_password "$u"; then
      if set_password "$u" "$PW_RESULT"; then ok "password di $u cambiata"; else bad "chpasswd ha fallito per $u"; fi
    else
      case "$st" in
        default|locked|none) bad "password di $u NON cambiata: e' ancora quella di fabbrica o inutilizzabile. Rilancia lo script oppure usa:  passwd $u" ;;
        *) info "password di $u lasciata com'e'" ;;
      esac
    fi
    PW_RESULT=""
  done
fi

# ================================================================================================ 3. nome, fuso, ora
step 3 "Nome della scheda, fuso orario, ora"
CUR_HOST="$(hostname)"
NEW_HOST="$WANT_HOSTNAME"
if [ -z "$NEW_HOST" ]; then
  if [ "$ASSUME_YES" = 1 ]; then NEW_HOST="$CUR_HOST"
  else
    [ "$CUR_HOST" = "orangepi4pro" ] && say "  Il nome e' quello di fabbrica ('orangepi4pro'): se hai un'altra scheda Raptor in rete, dagli un nome diverso (es. raptor-02)."
    ask_text "Nome di questa scheda" "$CUR_HOST"; NEW_HOST="$REPLY_TEXT"
  fi
fi
if ! printf '%s' "$NEW_HOST" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; then
  bad "nome '$NEW_HOST' non valido (solo minuscole, cifre e trattino): lascio '$CUR_HOST'"; NEW_HOST="$CUR_HOST"
fi
if [ "$NEW_HOST" != "$CUR_HOST" ]; then
  if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOST/" /etc/hosts; else printf '127.0.1.1\t%s\n' "$NEW_HOST" >>/etc/hosts; fi
  if hostnamectl set-hostname "$NEW_HOST" 2>/dev/null || { printf '%s\n' "$NEW_HOST" >/etc/hostname && hostname "$NEW_HOST"; }; then ok "nome della scheda: $NEW_HOST"
  else bad "non sono riuscito a cambiare il nome in $NEW_HOST"; fi
else
  ok "nome della scheda: $CUR_HOST (invariato)"
fi

if [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then bad "fuso orario '$TIMEZONE' inesistente (esempio: Europe/Rome)"
else
  CUR_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")"
  if [ "$CUR_TZ" = "$TIMEZONE" ]; then ok "fuso orario $TIMEZONE (gia' impostato)"
  elif timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then ok "fuso orario impostato a $TIMEZONE"
  else bad "non riesco a impostare il fuso orario $TIMEZONE"; fi
fi

if systemctl enable --now chrony >/dev/null 2>&1; then ok "chrony (sincronizzazione dell'ora) attivo e abilitato all'avvio"
else warn "chrony non si e' avviato: l'ora potrebbe non sincronizzarsi (la licenza e i log dipendono dall'ora)"; fi
if command -v chronyc >/dev/null 2>&1; then
  if [ "$NET" = 1 ]; then chronyc -a makestep >/dev/null 2>&1 || true; sleep 2; fi
  TR="$(chronyc tracking 2>/dev/null | awk -F': ' '/Leap status/{print $2}')"
  if [ "$TR" = "Normal" ]; then ok "ora sincronizzata (chrony: $(chronyc tracking 2>/dev/null | awk -F': ' '/System time/{print $2}'))"
  else warn "l'ora non e' ancora sincronizzata (chrony: ${TR:-sconosciuto}); riprova tra qualche minuto con:  chronyc tracking"; fi
fi

# ================================================================================================ 4. aggiornamenti automatici
step 4 "Blocco degli aggiornamenti automatici (il kernel non deve cambiare da solo)"
# apt-daily/apt-daily-upgrade sono i timer di sistema che fanno scattare un "apt update/upgrade" in background: sono
# loro a far partire unattended-upgrades anche quando nessuno lo ha mai configurato esplicitamente. Su una scheda con
# driver NPU legati a un kernel preciso, un riavvio notturno che installa un kernel diverso puo' lasciare la scheda
# senza NPU (vedi la nota sul kernel BSP qui sopra): un aggiornamento deve essere sempre una scelta esplicita.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
systemctl mask apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1
if ! systemctl is-enabled apt-daily.timer >/dev/null 2>&1 && ! systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
  ok "timer apt-daily disattivati (niente piu' 'apt update/upgrade' in background)"
else
  warn "non sono riuscito a disattivare del tutto i timer apt-daily: controllali a mano con 'systemctl list-timers'"
fi
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Raptor: nessun aggiornamento automatico. Un aggiornamento del kernel o dei driver puo' rompere l'NPU: deve essere
// sempre una scelta esplicita, mai qualcosa che succede da solo di notte.
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
ok "unattended-upgrades disattivato (/etc/apt/apt.conf.d/20auto-upgrades)"
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ] && grep -q 'Unattended-Upgrade::Automatic-Reboot "true"' /etc/apt/apt.conf.d/50unattended-upgrades; then
  sed -i 's/Unattended-Upgrade::Automatic-Reboot "true"/Unattended-Upgrade::Automatic-Reboot "false"/' /etc/apt/apt.conf.d/50unattended-upgrades
  ok "riavvio automatico disattivato anche in 50unattended-upgrades"
fi
KPKGS="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(linux-image|linux-headers|linux-dtb|linux-u-boot|linux-firmware-image|flash-kernel)' || true)"
if [ -n "$KPKGS" ]; then
  # shellcheck disable=SC2086
  apt-mark hold $KPKGS >/dev/null 2>&1
  ok "pacchetti del kernel/bootloader bloccati (apt-mark hold): $(printf '%s' "$KPKGS" | tr '\n' ' ')"
else
  warn "nessun pacchetto kernel/bootloader riconosciuto da bloccare: controlla a mano con 'dpkg -l | grep linux-image'"
fi

# ================================================================================================ 5. pacchetti
step 5 "Pacchetti"
if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "niente da installare"
elif [ "$NET" != 1 ]; then
  bad "mancano ${MISSING[*]} e la rete non c'e': collega la scheda a Internet e rilancia"
else
  export DEBIAN_FRONTEND=noninteractive
  say "  apt-get update ..."
  apt-get update -o DPkg::Lock::Timeout=300 2>&1 | tee -a "$LOG" | tail -n 3
  [ "${PIPESTATUS[0]}" -eq 0 ] || warn "apt-get update ha avuto problemi (un deposito non risponde?): provo a installare lo stesso"
  say "  installo: ${MISSING[*]}"
  apt-get install -y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${MISSING[@]}" 2>&1 | tee -a "$LOG" | tail -n 4
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then ok "pacchetti installati"; else bad "apt-get install e' fallito (vedi il registro $LOG)"; fi
fi
for m in numpy cv2 yaml cryptography; do
  if python3 -c "import $m" >/dev/null 2>&1; then ok "python3: import $m"; else bad "python3 non riesce a importare '$m' (pacchetto mancante o rotto)"; fi
done
command -v ffprobe >/dev/null 2>&1 && ok "ffprobe presente" || bad "ffprobe manca (pacchetto ffmpeg)"
if command -v ffmpeg >/dev/null 2>&1; then
  ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"     # prima tutto l'elenco, poi grep: con "| grep -q" ffmpeg muore per SIGPIPE e pipefail dice no
  if printf '%s\n' "$ENCODERS" | grep -w libx264 >/dev/null; then ok "ffmpeg con libx264 (serve alla copia live H.264)"; else bad "ffmpeg senza libx264: il Live Stream non funzionerebbe"; fi
else bad "ffmpeg manca"; fi
command -v gcc >/dev/null 2>&1 && ok "gcc presente (serve a compilare la libreria NPU)" || bad "gcc manca"
command -v nft >/dev/null 2>&1 && ok "nftables presente (assistenza remota)" || warn "nft manca: l'assistenza remota non si potra' attivare"
if [ "$N_BAD" -gt 0 ] && { ! command -v runuser >/dev/null 2>&1 || ! python3 -c "import numpy, cv2, yaml, cryptography" >/dev/null 2>&1; }; then
  die "mancano pacchetti indispensabili (vedi sopra): non vado avanti. Sistemali e rilancia."
fi

# ================================================================================================ 6. ambiente virtuale
step 6 "Ambiente virtuale Python"
if [ -x "$R/venv/bin/python" ]; then ok "ambiente virtuale gia' presente: $R/venv"
elif as_raptor python3 -m venv --system-site-packages "$R/venv" >>"$LOG" 2>&1; then
  ok "ambiente virtuale creato: $R/venv (con i pacchetti di sistema)"
  as_raptor "$R/venv/bin/python" -c "import numpy, cv2, yaml" >/dev/null 2>&1 \
    && ok "il venv vede numpy, opencv e yaml" || warn "il venv non vede numpy/opencv/yaml"
else
  bad "non sono riuscito a creare l'ambiente virtuale (python3-venv?)"
fi
info "nota: i servizi Raptor usano il Python di sistema (/usr/bin/python3); il venv serve solo per strumenti e prove a mano"

# ================================================================================================ 7. Tailscale
step 7 "Tailscale (assistenza remota)"
if command -v tailscale >/dev/null 2>&1; then
  ok "Tailscale gia' installato: $(tailscale version 2>/dev/null | head -1)"
elif [ "$TAILSCALE" = no ]; then
  info "Tailscale non installato (--no-tailscale). Puoi farlo dopo:  curl -fsSL https://tailscale.com/install.sh | sh"
elif [ "$NET" != 1 ]; then
  warn "niente rete: Tailscale non installato. Quando la rete c'e':  curl -fsSL https://tailscale.com/install.sh | sh"
else
  say "  Installo Tailscale con lo script ufficiale di tailscale.com (aggiunge il suo deposito apt) ..."
  if curl -fsSL https://tailscale.com/install.sh | sh >>"$LOG" 2>&1 && command -v tailscale >/dev/null 2>&1; then
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    ok "Tailscale installato: $(tailscale version 2>/dev/null | head -1). Non e' ancora collegato: il collegamento lo fai dal pannello (Settings > Application > Tailscale)"
  else
    warn "installazione di Tailscale fallita (vedi il registro). Raptor funziona lo stesso; riprova con:  curl -fsSL https://tailscale.com/install.sh | sh"
  fi
fi

# ================================================================================================ 8. programma
step 8 "Programma in $R"
PARENT="$(dirname "$R")"
if tar -xzf "$TAR" -C "$PARENT" --strip-components=1 --no-same-owner --no-overwrite-dir >>"$LOG" 2>&1; then ok "programma estratto in $R"; else die "estrazione fallita (disco pieno? vedi il registro)"; fi
for d in alarm bin common detector install native notifications services tests watchdog web; do
  [ -e "$R/$d" ] || continue
  chown -R "$RAPTOR_USER:$RAPTOR_USER" "$R/$d" && chmod -R u=rwX,g=rX,o=rX "$R/$d"
done
for f in "$R"/*.sha256 "$R"/*.md; do [ -f "$f" ] && chown "$RAPTOR_USER:$RAPTOR_USER" "$f"; done
for d in config data data/state data/logs data/events data/system_events data/alarm_events run models native/vendor/include; do
  install -d -o "$RAPTOR_USER" -g "$RAPTOR_USER" -m 0755 "$R/$d"
done
for d in config data data/state data/logs data/events data/system_events data/alarm_events run models; do chmod 2775 "$R/$d"; done
ok "proprietario $RAPTOR_USER e permessi a posto"
if [ "$HAS_MANIFEST" = 1 ] && [ -f "$R/MANIFEST.sha256" ]; then
  if (cd "$R" && sha256sum -c --quiet MANIFEST.sha256 >>"$LOG" 2>&1); then ok "verifica di ogni file del programma (MANIFEST.sha256): tutti integri"
  else bad "qualche file del programma non corrisponde al MANIFEST (vedi il registro): disco o copia danneggiati"; fi
fi
INSTALLED_VER="$(sed -n 's/^VERSION *= *"\(.*\)".*/\1/p' "$R/web/web.py" | head -1)"
[ "$INSTALLED_VER" = "$VER" ] && ok "versione installata: $INSTALLED_VER" || bad "versione installata '$INSTALLED_VER' diversa da quella del pacchetto '$VER'"

# ================================================================================================ 9. libreria NPU
step 9 "Libreria NPU (libraptor_npu.so)"
if [ "$NPU_BUILD" != 1 ]; then info "saltata (--no-npu-build)"
elif [ ! -f "$R/native/vendor/include/vip_lite.h" ]; then warn "manca $R/native/vendor/include/vip_lite.h: libreria NPU non compilata"
elif [ ! -f /usr/lib/libVIPhal.so ]; then warn "manca /usr/lib/libVIPhal.so: libreria NPU non compilata"
elif as_raptor bash "$R/detector/npu/build.sh" >>"$LOG" 2>&1 && [ -f "$R/detector/npu/libraptor_npu.so" ]; then ok "libraptor_npu.so compilata"
else bad "compilazione della libreria NPU fallita (vedi il registro): il motore funzionera' senza NPU finche' non la sistemi"; fi

# ================================================================================================ 10. modelli
step 10 "Modelli (in $R/models)"
MODELS="$R/models"
# a) la cartella copiata invece del suo contenuto: models/models/<id>/... -> models/<id>/...
if [ -d "$MODELS/models" ]; then
  MOVED=0
  while IFS= read -r -d '' it; do
    base="$(basename "$it")"
    if [ -e "$MODELS/$base" ]; then
      info "$base e' gia' in $MODELS: lascio quello e non sposto $it"
    else
      mv -n "$it" "$MODELS/$base" && MOVED=$((MOVED+1))
    fi
  done < <(find "$MODELS/models" -mindepth 1 -maxdepth 1 -print0)
  rmdir "$MODELS/models" 2>/dev/null || true
  [ "$MOVED" -gt 0 ] && ok "i modelli erano in $MODELS/models (cartella dentro la cartella): li ho spostati un livello su ($MOVED elementi)"
fi
# b) proprietario e permessi (il pacchetto li estrae come root)
chown -R "$RAPTOR_USER:$RAPTOR_USER" "$MODELS"
find "$MODELS" -type d -exec chmod 2775 {} +
find "$MODELS" -type f -exec chmod 664 {} +
# c) file .nb sciolti direttamente in models/: raptor-models li registra e li mette ognuno nella sua cartella
LOOSE="$(find "$MODELS" -maxdepth 1 -type f -name '*.nb' 2>/dev/null | wc -l)"
if [ "$LOOSE" -gt 0 ]; then
  say "  registro $LOOSE file .nb copiati direttamente in models/ ..."
  as_raptor python3 -I "$R/bin/raptor-models" 2>&1 | tee -a "$LOG" | tail -n 12
fi
# d) meta.json mancanti e index.json di tutti i modelli (i modelli che raptor-models non riconosce dal nome del grafo,
#    ma hanno gia' il loro meta.json, restano come sono)
if [ -n "$(find "$MODELS" -mindepth 2 -maxdepth 2 -name model.nb 2>/dev/null | head -n 1)" ]; then
  as_raptor python3 -I "$R/bin/raptor-models" --refresh 2>&1 | tee -a "$LOG" | tail -n 1 | sed 's/^/         /'
fi
# e) ogni modello: model.nb e meta.json devono andare d'accordo (somma sha256)
CHECK="$(as_raptor python3 -I -c '
import hashlib, json, os, sys
models = sys.argv[1]
good = bad = 0
for mid in sorted(os.listdir(models)):
    d = os.path.join(models, mid)
    nb, mp = os.path.join(d, "model.nb"), os.path.join(d, "meta.json")
    if not os.path.isfile(nb):
        continue
    if not os.path.isfile(mp):
        print("MANCA_META %s" % mid); bad += 1; continue
    try:
        meta = json.load(open(mp, encoding="utf-8"))
        with open(nb, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
    except Exception as exc:
        print("ERRORE %s (%s)" % (mid, type(exc).__name__)); bad += 1; continue
    if meta.get("id") != mid or meta.get("sha256") != digest:
        print("DIVERSO %s" % mid); bad += 1
    else:
        print("OK %s" % mid); good += 1
print("totale:%d:%d" % (good, bad))
' "$MODELS" 2>&1 | tee -a "$LOG")"
N_GOOD="$(sed -n 's/^totale:\([0-9]*\):.*/\1/p' <<<"$CHECK")"; N_BADM="$(sed -n 's/^totale:[0-9]*:\([0-9]*\)/\1/p' <<<"$CHECK")"
while IFS= read -r line; do
  case "$line" in
    DIVERSO\ *)   bad "modello ${line#DIVERSO }: model.nb non corrisponde al suo meta.json (copia incompleta o danneggiata? ricopia il pacchetto o il modello con FileZilla in modo binario)" ;;
    MANCA_META\ *) bad "modello ${line#MANCA_META }: manca meta.json e raptor-models non riconosce il file. Copia anche meta.json della scheda vecchia" ;;
    ERRORE\ *)    bad "modello ${line#ERRORE }" ;;
  esac
done <<<"$CHECK"
if [ "${N_GOOD:-0}" -gt 0 ]; then
  ok "${N_GOOD} modelli a posto in $MODELS"
  as_raptor python3 -I "$R/bin/raptor-models" --list 2>&1 | sed 's/^/         /' | tee -a "$LOG"
  [ -f "$MODELS/yolo26s_det_640/model.nb" ] && ok "il modello predefinito (yolo26s_det_640) c'e'" || warn "manca yolo26s_det_640, il modello predefinito: sceglilo dal pannello (Intrusion AI) o in config/settings.yaml (npu.model)"
elif [ "${N_BADM:-0}" -eq 0 ]; then
  warn "nessun modello in $MODELS: senza non c'e' rilevamento. Copiali con FileZilla in $MODELS e rilancia questo script (rifa' solo quello che manca)"
fi

# ================================================================================================ 11. root e Telegram
step 11 "Programmi di root e Telegram"
if python3 -I "$R/bin/raptor-auth" install >>"$LOG" 2>&1 && [ -x /usr/local/sbin/raptor-auth ]; then ok "raptor-auth installato in /usr/local/sbin (recupero password del pannello)"
else bad "installazione di raptor-auth fallita"; fi
if python3 -I "$R/services/admin/install.py" >>"$LOG" 2>&1; then ok "raptor-admin installato (rete, ora, spegnimento, assistenza remota dal pannello)"
else bad "installazione di raptor-admin fallita (vedi il registro; ricontrolla con: python3 -I $R/services/admin/install.py status)"; fi
if [ -f "$R/config/auth.yaml" ]; then ok "gli accessi del pannello esistono gia' ($R/config/auth.yaml): non li tocco"
else info "l'amministratore del pannello lo crei dalla pagina web, non da riga di comando (vedi in fondo)"; fi

DO_TG=0
case "$TELEGRAM" in
  yes) DO_TG=1 ;;
  no) DO_TG=0 ;;
  *) if [ -f "$R/config/notifications.yaml" ]; then info "esiste gia' una configurazione delle notifiche: la lascio"
     else ask_yn "Configuro adesso Telegram (token del bot e destinatari)? Altrimenti lo fai dal pannello, pagina Notifications." s && DO_TG=1; fi ;;
esac
if [ "$DO_TG" = 1 ]; then
  say "  Il token lo prendi da @BotFather (quello del bot che usi gia'). Non viene mostrato ne' scritto nel registro."
  ask_secret "Token del bot (INVIO a vuoto = salta):"
  TG_TOKEN="$SECRET_TEXT"; SECRET_TEXT=""
  if [ -z "$TG_TOKEN" ]; then
    info "Telegram saltato: lo configuri dal pannello (Notifications)"
  elif printf '%s' "$TG_TOKEN" | grep -Eq '[[:space:]]' || [ "${#TG_TOKEN}" -gt 200 ]; then
    bad "il token non sembra valido (contiene spazi o e' troppo lungo): Telegram non configurato"
  else
    BOT="$(printf '%s' "$TG_TOKEN" | python3 -I -c '
import json, sys, urllib.request
t = sys.stdin.read().strip()
try:
    with urllib.request.urlopen("https://api.telegram.org/bot%s/getMe" % t, timeout=12) as r:
        d = json.load(r)
    print("OK:" + str(d["result"].get("username", "")) if d.get("ok") else "NO:risposta negativa")
except Exception as e:
    print("NO:" + type(e).__name__)
' 2>/dev/null)"
    TG_SAVE=1
    case "$BOT" in
      OK:*) ok "token valido: bot @${BOT#OK:}" ;;
      NO:HTTPError) bad "Telegram ha rifiutato il token (sbagliato o revocato)"; ask_yn "Lo salvo lo stesso?" n || TG_SAVE=0 ;;
      *) warn "non riesco a verificare il token adesso (${BOT#NO:}: rete assente?)"; ask_yn "Lo salvo lo stesso?" s || TG_SAVE=0 ;;
    esac
    if [ "$TG_SAVE" = 1 ]; then
      RECIPIENTS=""
      while :; do
        ask_private "Chat ID del destinatario (numero, es. 123456789; INVIO a vuoto = finito):"
        CHAT="$REPLY_TEXT"; [ -z "$CHAT" ] && break
        if ! printf '%s' "$CHAT" | grep -Eq '^-?[0-9]{1,20}$'; then say "  Il chat ID e' un numero (anche negativo per i gruppi). Riprova."; continue; fi
        ask_text "Nome del destinatario (come lo vedi nel pannello)" "Destinatario $(( $(printf '%s' "$RECIPIENTS" | grep -c .) + 1 ))"
        RNAME="$REPLY_TEXT"
        RECIPIENTS="${RECIPIENTS}${CHAT}|${RNAME}"$'\n'
        ok "destinatario aggiunto: $RNAME"
        ask_yn "Un altro destinatario?" n || break
      done
      PYTG='
import os, sys, yaml
path = sys.argv[1]
lines = sys.stdin.read().split("\n")
token = lines[0].strip()
recips = []
for row in lines[1:]:
    if "|" in row:
        chat, name = row.split("|", 1)
        recips.append({"name": name.strip()[:80], "chat_id": chat.strip(), "enabled": True, "override": False, "event_ai": True,
                       "alarm_status": True, "camera_status": True, "alarm_input": True, "rtsp_status": True, "system_status": True, "time": False})
cfg = {"version": 3, "enabled": True,
       "telegram": {"enabled": bool(recips), "bot_token": token, "recipients": recips},
       "email": {"enabled": False, "smtp_host": "", "smtp_port": 587, "security": "starttls", "username": "", "password": "",
                 "from_email": "", "from_name": "RAPTOR AI Security", "recipients": []}}
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False, allow_unicode=True, default_flow_style=False, indent=2, width=120)
    fh.flush(); os.fsync(fh.fileno())
os.replace(tmp, path); os.chmod(path, 0o600)
print("scritto:%d" % len(recips))
'
      if OUT="$(printf '%s\n%s' "$TG_TOKEN" "$RECIPIENTS" | as_raptor python3 -I -c "$PYTG" "$R/config/notifications.yaml" 2>&1)"; then
        ok "Telegram configurato ($R/config/notifications.yaml, permessi 600): ${OUT#scritto:} destinatari"
        [ "${OUT#scritto:}" = 0 ] && warn "nessun destinatario: aggiungine uno dalla pagina Notifications del pannello (Telegram resta spento finche' non c'e')"
        info "i messaggi attivi per ogni destinatario: eventi AI, allarme, telecamere, RTSP, sistema (cambiabili dal pannello); prova con il tasto TEST"
      else bad "scrittura della configurazione Telegram fallita"; fi
    fi
  fi
  TG_TOKEN=""; RECIPIENTS=""
fi

# ================================================================================================ 12. servizi e controlli
step 12 "Servizi (partono anche a ogni avvio della scheda) e controlli finali"
python3 -I "$R/services/raptor_services.py" install 2>&1 | tee -a "$LOG" | sed 's/^/         /'
RC="${PIPESTATUS[0]}"
if [ "$RC" -eq 0 ]; then ok "5 servizi installati, abilitati e avviati; controllo di indipendenza superato"; else bad "l'installazione dei servizi ha segnalato problemi (sopra)"; fi

for u in detector web watchdog notifications alarm-monitor; do
  st="inactive"
  for _ in 1 2 3 4 5 6 7 8 9 10; do st="$(systemctl is-active "raptor-$u" 2>/dev/null)"; [ "$st" = active ] && break; sleep 1; done
  en="$(systemctl is-enabled "raptor-$u" 2>/dev/null)"
  if [ "$st" = active ] && [ "$en" = enabled ]; then ok "raptor-$u: attivo e abilitato all'avvio"
  else bad "raptor-$u: $st / $en   (guarda:  journalctl -u raptor-$u -n 30 --no-pager)"; fi
done
systemctl is-active raptor-admin.socket >/dev/null 2>&1 && ok "raptor-admin.socket in ascolto" || warn "raptor-admin.socket non attivo: i pulsanti di sistema del pannello non funzioneranno"

PANEL_MODE=""; FIRST_START=0
for _ in $(seq 1 40); do
  PANEL_MODE="$(curl -s --max-time 3 "http://127.0.0.1:$PANEL_PORT/api/auth/state" 2>/dev/null | python3 -I -c 'import json, sys
try:
    print(json.load(sys.stdin).get("mode", ""))
except Exception:
    print("")' 2>/dev/null)"
  [ -n "$PANEL_MODE" ] && break
  sleep 1
done
case "$PANEL_MODE" in
  setup)  ok "il pannello risponde su http://127.0.0.1:$PANEL_PORT/ e aspetta la prima configurazione (licenza e password admin dalla pagina)"; FIRST_START=1 ;;
  login|locked|active) ok "il pannello risponde su http://127.0.0.1:$PANEL_PORT/ (gli accessi esistono gia')" ;;
  open)   warn "il pannello risponde ma senza accessi (modalita' aperta): non e' normale per una installazione di produzione" ;;
  broken) bad "il pannello risponde ma config/auth.yaml non e' utilizzabile: su - -c \"raptor-auth reset-admin\"" ;;
  *)      bad "il pannello non risponde su http://127.0.0.1:$PANEL_PORT/: journalctl -u raptor-web -n 30 --no-pager" ;;
esac

sleep 3
NPU_LINE="$(journalctl -u raptor-detector -n 60 --no-pager 2>/dev/null | grep -iE 'NPU (ready|not|disabled|unavailable)|npu' | tail -n 1 | sed 's/^.*raptor-detector\[[0-9]*\]: //')"
[ -n "$NPU_LINE" ] && info "motore, ultima riga sull'NPU: $NPU_LINE" || info "motore: nessuna riga sull'NPU nel giornale (normale se non ci sono telecamere/modelli)"

HWID="$(as_raptor python3 -I "$R/bin/raptor-license" hwid 2>&1 | head -n 8)"
if [ -n "$HWID" ]; then say ""; say "  ID di questa scheda per la licenza (raptor-license hwid):"; printf '%s\n' "$HWID" | sed 's/^/         /' | tee -a "$LOG"; fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
head1 "Riepilogo"
say "OK: $N_OK   da guardare: $N_WARN   problemi: $N_BAD"
for w in "${BADS[@]:-}"; do [ -n "$w" ] && say "  [FAIL] $w"; done
for w in "${WARNS[@]:-}"; do [ -n "$w" ] && say "  [WARN] $w"; done
say ""
say "Raptor $INSTALLED_VER: pannello su  http://${IP:-<indirizzo-della-scheda>}:$PANEL_PORT"
if [ "$FIRST_START" = 1 ]; then
  say ""
  say "  ADESSO apri quell'indirizzo dal browser di un computer della stessa rete. La prima schermata ti guida:"
  say "     1) attivazione della licenza di QUESTA scheda (codice di attivazione, oppure il file della licenza se la scheda non ha Internet)"
  say "     2) scelta della password dell'amministratore (utente: admin)"
  say "  Fallo subito: finche' non e' fatto, chi apre per primo la pagina sceglie lui la password."
fi
say "Poi, dal pannello: telecamere, Notifications > TEST, Settings > Application > Tailscale (assistenza remota)."
say "Registro: $LOG"
if [ "$N_BAD" -eq 0 ]; then exit 0; fi
say "${C_BAD}Ci sono problemi (sopra).${C_0} Sistemali e rilancia: lo script e' ripetibile, rifa' solo quello che manca."
exit 1

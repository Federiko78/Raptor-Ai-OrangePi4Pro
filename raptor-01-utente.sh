#!/usr/bin/env bash
# =====================================================================================================================
# raptor-01-utente.sh  -  Raptor AI 0.16.10  -  PASSO 1 di 2: l'utente raptor e le sue cartelle (scheda Orange Pi 4 Pro NUOVA)
#
# E' la prima cosa da fare su una scheda nuova, quando c'e' ancora solo l'utente di fabbrica (orangepi). Cosa fa:
#   1. controlla che sia una Orange Pi 4 Pro con Debian 12                                   (non cambia nulla)
#   2. crea l'utente raptor (cartella personale /home/raptor) e ti chiede la sua password     (la scrivi tu, nascosta)
#   3. prepara /opt/raptor con le sue cartelle (config, data, models, ...), tutte di proprieta' di raptor
#
# Poi esci e rientri come RAPTOR (ssh e FileZilla con l'utente raptor): da quel momento tutto si fa da raptor, e tutti i file
# che copi (il passo 2, il pacchetto, i modelli) finiscono nella sua cartella /home/raptor.
# Le password di root e orangepi NON le cambia questo script: le cambia il passo 2 (raptor-02-installa.sh), come prima cosa.
#
# Si puo' rilanciare quante volte vuoi: quello che c'e' gia' lo lascia com'e'.
#
# Uso (sulla scheda, come utente orangepi: lo script si fa dare i permessi di root chiedendoti la password di root,
# che su una scheda nuova e' quella di fabbrica):
#     bash /home/orangepi/raptor-01-utente.sh
#
# Opzioni:
#     --check-only         guarda e basta: nessuna modifica, nessuna domanda
#     --no-password        non chiede la password di raptor (l'utente resta senza accesso con password: solo per prove)
#     --yes                risponde con la scelta predefinita alle domande si/no (la password resta a te)
#     --force              prosegue anche se la scheda o il sistema non sembrano una Orange Pi 4 Pro con Debian 12
#     --help
#
# Un registro (senza password) resta in /root/raptor-utente-DATA.log
# =====================================================================================================================
set -u -o pipefail

SCRIPT_VERSION="3.0.0"
ORIG_ARGS=("$@")
ELEVATED=0
RAPTOR_USER="raptor"
R="${RAPTOR_ROOT:-/opt/raptor}"
CHECK_ONLY=0
NO_PASSWORD=0
ASSUME_YES=0
FORCE=0

usage() { awk 'NR==1{next} /^# =+$/{n++; if(n==2) exit; next} n==1{sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --no-password|--skip-passwords) NO_PASSWORD=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    --elevated) ELEVATED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opzione sconosciuta: %s  (vedi --help)\n' "$1" >&2; exit 2 ;;
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

ask_new_password() {   # ask_new_password UTENTE  -> 0 e $PW_RESULT; 1 = non impostata (3 tentativi o INVIO a vuoto)
  local who="$1" tries=0 p1 p2 prob
  PW_RESULT=""
  while [ "$tries" -lt 3 ]; do
    tries=$((tries+1))
    printf '  Scegli la password di %s (almeno 8 caratteri, nascosta): ' "$who" >&2
    IFS= read -rs p1 || p1=""; printf '\n' >&2
    [ -z "$p1" ] && { printf 'password di %s: non scritta\n' "$who" >>"$LOG" 2>/dev/null || true; return 1; }
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

set_password() {   # set_password UTENTE PASSWORD
  printf '%s:%s\n' "$1" "$2" | chpasswd
}

# ------------------------------------------------------------------------------------------------ inizio
printf '%s\n' "${C_B}Raptor AI - passo 1 di 2: l'utente raptor e le sue cartelle (script $SCRIPT_VERSION)${C_0}"
[ "$(id -u)" -eq 0 ] || {
  ABS="$(readlink -f -- "$0")"
  if [ "$ELEVATED" = 1 ]; then printf 'Non sono riuscito a diventare root con su: controlla la password di root e rilancia.\n' >&2; exit 1; fi
  printf 'Servono i permessi di root: ti chiedo la password di root (su -). Su una scheda nuova e'"'"' quella di fabbrica.\n' >&2
  ARGS=""; for a in "${ORIG_ARGS[@]}"; do ARGS="$ARGS $(printf '%q' "$a")"; done
  exec su - -c "bash $(printf '%q' "$ABS")$ARGS --elevated"
}
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
LOG="/root/raptor-utente-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG" && chmod 600 "$LOG"
say "Registro (senza password): $LOG"
if [ "$CHECK_ONLY" = 1 ]; then
  say "Modo --check-only: guardo e basta, non cambio nulla."
else
  say ""
  say "Questo script fa tre cose, in quest'ordine:"
  say "   1. controlla la scheda"
  say "   2. crea l'utente raptor e ti chiede la sua password"
  say "   3. prepara la cartella /opt/raptor, tutta di proprieta' di raptor"
  say "Non installa Raptor e non cambia le password di root e orangepi: lo fa il passo 2, lanciato da raptor."
fi

# ================================================================================================ 1. controllo
head1 "Passo 1 di 3 - Controllo della scheda"
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

if id "$RAPTOR_USER" >/dev/null 2>&1; then
  ok "l'utente $RAPTOR_USER esiste gia'"
  case "$(pw_state "$RAPTOR_USER")" in
    custom) ok "la password di $RAPTOR_USER e' gia' stata scelta" ;;
    default|locked|none) info "la password di $RAPTOR_USER manca o e' di fabbrica: te la chiedo" ;;
  esac
else
  info "l'utente $RAPTOR_USER non esiste ancora: lo creo"
fi
[ -d "$R" ] && ok "$R presente" || info "$R: da creare"

if [ "$CHECK_ONLY" = 1 ]; then
  head1 "Riepilogo (--check-only: nessuna modifica fatta)"
  say "OK: $N_OK   da guardare: $N_WARN   problemi: $N_BAD"
  for w in "${BADS[@]:-}"; do [ -n "$w" ] && say "  [FAIL] $w"; done
  for w in "${WARNS[@]:-}"; do [ -n "$w" ] && say "  [WARN] $w"; done
  exit $([ "$N_BAD" -eq 0 ] && echo 0 || echo 1)
fi

STOP=0
[ "$ARCH" = "aarch64" ] || STOP=1
{ [ "$OSID" = "debian" ] && [ "$OSVER" = "12" ]; } || STOP=1
if [ "$STOP" = 1 ] && [ "$FORCE" != 1 ]; then
  die "questa non sembra una Orange Pi 4 Pro con Debian 12. Se sai cosa fai, rilancia con --force."
fi
say ""
ask_yn "Procedo con i passi 2 e 3 (utente raptor e cartelle)?" s || die "interrotto, non ho cambiato nulla"

# ================================================================================================ 2. utente raptor
head1 "Passo 2 di 3 - Utente raptor"
getent group "$RAPTOR_USER" >/dev/null || { groupadd --system "$RAPTOR_USER" && ok "gruppo $RAPTOR_USER creato"; }
if ! id "$RAPTOR_USER" >/dev/null 2>&1; then
  if useradd --gid "$RAPTOR_USER" --create-home --home-dir "/home/$RAPTOR_USER" --shell /bin/bash --comment "Raptor AI" "$RAPTOR_USER"; then ok "utente $RAPTOR_USER creato (home /home/$RAPTOR_USER, shell bash)"
  else bad "non riesco a creare l'utente $RAPTOR_USER"; fi
else
  ok "utente $RAPTOR_USER gia' presente"
fi
for g in video dialout; do   # video: /dev/dma_heap (NPU/VPU); dialout: porte seriali (Arduino)
  if getent group "$g" >/dev/null; then usermod -aG "$g" "$RAPTOR_USER" 2>/dev/null && ok "$RAPTOR_USER e' nel gruppo $g"; fi
done
if [ -d "/home/$RAPTOR_USER" ]; then
  chown "$RAPTOR_USER:$RAPTOR_USER" "/home/$RAPTOR_USER" && ok "cartella /home/$RAPTOR_USER di proprieta' di $RAPTOR_USER (e' qui che copierai i file con FileZilla)"
fi

if id "$RAPTOR_USER" >/dev/null 2>&1; then
  if [ "$NO_PASSWORD" = 1 ]; then
    info "--no-password: non chiedo la password di $RAPTOR_USER (senza, non potrai entrare come raptor con ssh o FileZilla)"
  else
    PWST="$(pw_state "$RAPTOR_USER")"
    SET_PW=1
    if [ "$PWST" = custom ]; then
      ask_yn "$RAPTOR_USER ha gia' una password scelta. La cambio lo stesso?" n || { SET_PW=0; ok "password di $RAPTOR_USER lasciata com'e'"; }
    fi
    if [ "$SET_PW" = 1 ]; then
      say "  La password di $RAPTOR_USER serve per entrare da ssh e FileZilla: da qui in poi lavori come raptor. Resta nascosta e non finisce nel registro."
      if ask_new_password "$RAPTOR_USER"; then
        if set_password "$RAPTOR_USER" "$PW_RESULT"; then ok "password di $RAPTOR_USER impostata"; else bad "chpasswd ha fallito per $RAPTOR_USER"; fi
      else
        bad "password di $RAPTOR_USER NON impostata: senza non puoi entrare come raptor. Rilancia lo script"
      fi
      PW_RESULT=""
    fi
  fi
fi

# ================================================================================================ 3. cartelle
head1 "Passo 3 di 3 - Cartelle di $R"
if id "$RAPTOR_USER" >/dev/null 2>&1; then
  mkdir -p "$R"
  MODELS_NEW=0; [ -d "$R/models" ] || MODELS_NEW=1
  for d in bin config data data/state data/logs data/events data/system_events data/alarm_events run models native native/vendor/include tests; do
    install -d -o "$RAPTOR_USER" -g "$RAPTOR_USER" -m 0755 "$R/$d"
  done
  for d in config data data/state data/logs data/events data/system_events data/alarm_events run models; do chmod 2775 "$R/$d"; done
  chown "$RAPTOR_USER:$RAPTOR_USER" "$R"; chmod 0755 "$R"
  ok "cartelle di $R pronte (proprietario $RAPTOR_USER)"
  if [ -d "$R/models" ]; then
    ok "cartella $R/models $([ "$MODELS_NEW" = 1 ] && echo creata || echo "gia' presente"): se il pacchetto non ha i modelli, ce li copi con FileZilla come raptor"
  else
    bad "la cartella $R/models non esiste: FileZilla non avrebbe dove copiare i modelli"
  fi
else
  bad "senza l'utente $RAPTOR_USER non posso preparare $R"
fi

# ================================================================================================ riepilogo
head1 "Riepilogo"
say "OK: $N_OK   da guardare: $N_WARN   problemi: $N_BAD"
for w in "${BADS[@]:-}"; do [ -n "$w" ] && say "  [FAIL] $w"; done
for w in "${WARNS[@]:-}"; do [ -n "$w" ] && say "  [WARN] $w"; done
say ""
if [ "$N_BAD" -ne 0 ]; then
  say "${C_BAD}Ci sono problemi (elencati sopra).${C_0} Sistemali e rilancia questo script: rifa' solo quello che manca."
  say "Registro: $LOG"
  exit 1
fi
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "${C_OK}Passo 1 finito.${C_0} Da qui in poi lavori come ${C_B}raptor${C_0}, non piu' come orangepi."
say ""
say "  1) FileZilla: connessione NUOVA, protocollo SFTP, porta 22, indirizzo ${IP:-<indirizzo della scheda>}, utente ${C_B}raptor${C_0} e la password che hai appena scelto."
say "     Copia nella sua cartella  /home/$RAPTOR_USER  questi file (trasferimento Auto o Binario, mai ASCII):"
say "        - raptor-02-installa.sh"
say "        - il pacchetto  raptor_full_0.16.10_con_modelli.tar.gz  e il suo .sha256"
say "          (se hai il pacchetto  _senza_modelli  copia anche i modelli: il CONTENUTO della cartella models della scheda vecchia,"
say "           dentro  $R/models)"
say "  2) Terminale: ssh $RAPTOR_USER@${IP:-<indirizzo della scheda>}   e poi, da qualunque cartella:"
say "        bash /home/$RAPTOR_USER/raptor-02-installa.sh"
say "     Il passo 2 ti chiede la password di root (di fabbrica), la cambia insieme a quella di orangepi, e poi installa tutto."
say ""
say "Registro: $LOG"
exit 0

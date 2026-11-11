#!/usr/bin/env bash
# =====================================================================================================================
# raptor-00-verifica.sh  -  Raptor AI 0.16.10  -  PASSO 0: verifica dei prerequisiti (prima di scaricare o copiare nulla)
#
# Si lancia per primo, su una scheda appena accesa con il sistema operativo che forniamo noi. Guarda soltanto: non
# installa nulla, non cambia nulla, non chiede nulla. Alla fine dice "procedi" oppure cosa non va e perche'.
# Pensato per essere lanciato con un solo comando, prima ancora di aprire FileZilla o scaricare il pacchetto: cosi' un
# problema (sistema operativo sbagliato, kernel sbagliato, poco spazio, NPU non pronta) si scopre subito, non a meta'
# installazione.
#
# Uso (una riga, copiata dal nostro GitHub, sulla scheda appena accesa - non servono permessi di root):
#     curl -fsSL https://raw.githubusercontent.com/<ORG>/<REPO>/main/install/raptor-00-verifica.sh | bash
#
# oppure, se il file e' gia' sulla scheda:
#     bash raptor-00-verifica.sh
#
# Uscita:  0 = nessun problema bloccante, si puo' procedere con raptor-01-utente.sh.
#          1 = almeno un [FAIL]: elencato sotto, con il motivo. Un [WARN] non blocca, ma vale la pena guardarlo.
#
# Opzioni:
#     --force     non fermarsi sui [FAIL] (resta comunque l'elenco: solo per chi sa cosa sta facendo)
#     --help
#
# Un registro (senza segreti: qui non ne leggiamo nessuno) resta in /tmp/raptor-verifica-<data>.log se /tmp e' scrivibile.
# =====================================================================================================================
set -u -o pipefail

SCRIPT_VERSION="1.0.0"
FORCE=0

usage() { awk 'NR==1{next} /^# =+$/{n++; if(n==2) exit; next} n==1{sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opzione sconosciuta: %s  (vedi --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------------------------------------ voci a video e nel registro
if [ -t 1 ]; then C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'; else C_OK=""; C_WARN=""; C_BAD=""; C_B=""; C_0=""; fi
LOG="/dev/null"
if [ -w /tmp ]; then LOG="/tmp/raptor-verifica-$(date +%Y%m%d-%H%M%S).log"; : >"$LOG" 2>/dev/null || LOG="/dev/null"; fi
N_OK=0; N_WARN=0; N_BAD=0
WARNS=(); BADS=()

emit()  { printf '%s\n' "$1"; printf '%s\n' "$2" >>"$LOG" 2>/dev/null || true; }
say()   { emit "$*" "$*"; }
head1() { emit "" ""; emit "${C_B}== $* ==${C_0}" "== $* =="; }
ok()    { N_OK=$((N_OK+1));     emit "  ${C_OK}[ OK ]${C_0} $*" "  [ OK ] $*"; }
warn()  { N_WARN=$((N_WARN+1)); WARNS+=("$*"); emit "  ${C_WARN}[WARN]${C_0} $*" "  [WARN] $*"; }
bad()   { N_BAD=$((N_BAD+1));   BADS+=("$*");  emit "  ${C_BAD}[FAIL]${C_0} $*" "  [FAIL] $*"; }
info()  { emit "         $*" "         $*"; }

# ------------------------------------------------------------------------------------------------ punti di prova (per --force
#   e per i collaudi automatici: RAPTOR_VERIFY_ROOT ridirige /proc, /etc, /sys, /dev, /usr/lib dentro una cartella finta;
#   RAPTOR_VERIFY_ARCH, RAPTOR_VERIFY_KERNEL, RAPTOR_VERIFY_YEAR sostituiscono uname/data; RAPTOR_VERIFY_SKIP_NET=1 salta
#   le prove di rete. Su una scheda vera nessuna di queste variabili e' impostata: si leggono i file reali.)
ROOT="${RAPTOR_VERIFY_ROOT:-}"
p() { printf '%s%s' "$ROOT" "$1"; }   # p /proc/meminfo -> il percorso vero, o quello dentro ROOT durante i collaudi

say "${C_B}Raptor AI - verifica prerequisiti (script $SCRIPT_VERSION)${C_0}"
say "Guardo soltanto: nessuna modifica, nessuna domanda."

# ================================================================================================ scheda e sistema
head1 "Scheda e sistema operativo"

ARCH="${RAPTOR_VERIFY_ARCH:-$(uname -m)}"
if [ "$ARCH" = "aarch64" ]; then ok "architettura aarch64"
else bad "architettura $ARCH (serve aarch64: questa non e' una Orange Pi 4 Pro)"; fi

MODEL=""
MODEL_FILE="$(p /proc/device-tree/model)"
[ -r "$MODEL_FILE" ] && MODEL="$(tr -d '\0' <"$MODEL_FILE" 2>/dev/null || true)"
case "$MODEL" in
  *[Oo]range*) ok "scheda: $MODEL" ;;
  *sun60iw2*)  ok "scheda: $MODEL (e' il nome del processore Allwinner A733 della Orange Pi 4 Pro)" ;;
  "") warn "il modello della scheda non e' leggibile ($MODEL_FILE)" ;;
  *) warn "scheda: $MODEL (non riconosco il nome: controlla che sia una Orange Pi 4 Pro)" ;;
esac

OS_RELEASE="$(p /etc/os-release)"
OSNAME="$(. "$OS_RELEASE" 2>/dev/null; echo "${PRETTY_NAME:-sconosciuto}")"
OSID="$(. "$OS_RELEASE" 2>/dev/null; echo "${ID:-}")"
OSVER="$(. "$OS_RELEASE" 2>/dev/null; echo "${VERSION_ID:-}")"
if [ "$OSID" = "debian" ] && [ "$OSVER" = "12" ]; then ok "sistema: $OSNAME (Debian 12, come la scheda di riferimento)"
else bad "sistema: $OSNAME (Raptor e' provato su Debian 12 'bookworm': con un sistema diverso l'installazione puo' rompersi a meta')"; fi

KERNEL="${RAPTOR_VERIFY_KERNEL:-$(uname -r)}"
case "$KERNEL" in
  *sun60iw2*) ok "kernel $KERNEL (BSP Allwinner A733, quello con i driver NPU)" ;;
  *) bad "kernel $KERNEL: non e' il BSP sun60iw2 della scheda di riferimento. Con un kernel diverso l'NPU puo' non esserci o dare risultati sbagliati: abbiamo gia' avuto problemi reali per questo. Riflasha l'immagine che forniamo noi" ;;
esac

# ================================================================================================ risorse
head1 "Memoria e spazio"

MEMINFO="$(p /proc/meminfo)"
MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' "$MEMINFO" 2>/dev/null || echo 0)
if [ "${MEM_MB:-0}" -ge 3500 ]; then ok "memoria ${MEM_MB} MB"; else warn "memoria ${MEM_MB} MB (la scheda di riferimento ne ha circa 5800: Raptor puo' comunque funzionare, con meno margine)"; fi

DF_PATH="${ROOT:-/opt}"
mkdir -p "$DF_PATH" 2>/dev/null || true
FREE_MB=$(df -Pm "$DF_PATH" 2>/dev/null | awk 'NR==2{print $4}')
if [ "${FREE_MB:-0}" -ge 8000 ]; then ok "spazio libero: ${FREE_MB} MB"
elif [ "${FREE_MB:-0}" -ge 3000 ]; then warn "spazio libero: ${FREE_MB} MB (poco: filmati e foto degli eventi crescono in fretta)"
else bad "spazio libero: ${FREE_MB:-?} MB (servono almeno 3000 solo per installare, prima ancora dei dati)"; fi

# ================================================================================================ NPU
head1 "NPU (necessaria per il rilevamento)"

VIPCORE_SYS="$(p /sys/module/vipcore)"
VIPCORE_DEV="$(p /dev/vipcore)"
if [ -e "$VIPCORE_SYS" ] || { [ -z "$ROOT" ] && lsmod 2>/dev/null | grep -q '^vipcore'; }; then ok "driver NPU (vipcore) caricato"
else bad "driver NPU 'vipcore' non caricato: senza non c'e' rilevamento. Viene dall'immagine che forniamo noi: riflashala"; fi
if [ -e "$VIPCORE_DEV" ]; then ok "dispositivo NPU presente"
else bad "il dispositivo NPU manca"; fi
for lib in libVIPhal.so libNBGlinker.so; do
  if [ -f "$(p "/usr/lib/$lib")" ]; then ok "/usr/lib/$lib presente"
  else bad "/usr/lib/$lib manca (viene dall'immagine della scheda: senza, la libreria NPU di Raptor non si compila)"; fi
done

# ================================================================================================ orologio e rete
head1 "Orologio e rete"

YEAR="${RAPTOR_VERIFY_YEAR:-$(date +%Y)}"
if [ "$YEAR" -ge 2026 ]; then ok "data e ora del sistema plausibili"
else bad "l'orologio e' sbagliato (anno $YEAR): i certificati HTTPS per scaricare da GitHub e i pacchetti falliranno. Impostalo: date -s 'AAAA-MM-GG HH:MM:SS'"; fi

if [ "${RAPTOR_VERIFY_SKIP_NET:-0}" = 1 ]; then
  info "prove di rete saltate (RAPTOR_VERIFY_SKIP_NET=1)"
else
  if getent hosts raw.githubusercontent.com >/dev/null 2>&1 && timeout 6 bash -c 'exec 3<>/dev/tcp/raw.githubusercontent.com/443' 2>/dev/null; then
    ok "rete e DNS: raw.githubusercontent.com raggiungibile (da qui si scarica il pacchetto)"
  else
    bad "raw.githubusercontent.com non raggiungibile: senza non si puo' scaricare né il pacchetto né la prova di 14 giorni. Controlla la rete della scheda"
  fi
  if getent hosts deb.debian.org >/dev/null 2>&1 && timeout 6 bash -c 'exec 3<>/dev/tcp/deb.debian.org/80' 2>/dev/null; then
    ok "rete e DNS: deb.debian.org raggiungibile"
  else
    warn "deb.debian.org non raggiungibile (serve piu' avanti, per i pacchetti che mancano: puo' essere un problema temporaneo)"
  fi
fi

# ================================================================================================ riepilogo
head1 "Riepilogo"
say "OK: $N_OK   da guardare: $N_WARN   problemi: $N_BAD"
for w in "${BADS[@]:-}"; do [ -n "$w" ] && say "  [FAIL] $w"; done
for w in "${WARNS[@]:-}"; do [ -n "$w" ] && say "  [WARN] $w"; done
say ""
[ "$LOG" != /dev/null ] && say "Registro: $LOG"

if [ "$N_BAD" -ne 0 ]; then
  if [ "$FORCE" = 1 ]; then
    say "${C_WARN}Ci sono problemi bloccanti (sopra), ma --force: procedo comunque. Sconsigliato.${C_0}"
    exit 0
  fi
  say "${C_BAD}Questa scheda non e' pronta per Raptor (problemi sopra).${C_0} Risolvili e rilancia questo script."
  exit 1
fi
say "${C_OK}Tutto a posto: puoi procedere con l'installazione.${C_0}"
exit 0

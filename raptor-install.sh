#!/usr/bin/env bash
# =====================================================================================================================
# raptor-install.sh  -  Raptor AI  -  installazione automatica su una Orange Pi 4 Pro NUOVA
#
# Un solo comando, lanciato come utente orangepi su una scheda appena flashata con la nostra immagine:
#
#     curl -fsSL https://raw.githubusercontent.com/Federiko78/Raptor-Ai-OrangePi4Pro-Ver.0.16.10/main/raptor-install.sh -o raptor-install.sh && bash raptor-install.sh
#
# (NON con "curl | bash": lo script deve riattaccare l'input al terminale vero per chiedere le password piu' avanti,
#  e se arriva tramite una pipe quel riattacco interrompe anche la lettura del resto dello script da quella stessa
#  pipe -- si blocca in silenzio, senza errori, proprio nel punto dell'exec. Scaricarlo su file ed eseguirlo evita
#  del tutto il problema: resta comunque un solo comando da copiare e lanciare.)
#
# Fa tutto da solo: scarica ed esegue raptor-01-utente.sh (crea l'utente raptor), poi scarica il pacchetto compilato
# e raptor-02-installa.sh e li esegue come raptor (installazione vera). Niente FileZilla, niente passaggi a mano:
# resta interattivo solo per quello che DEVE chiederti (le password, il nome della scheda, Telegram).
#
# Senza modelli YOLO: il pannello funziona da subito (parte il trial), ma il detector non rileva nulla finche' non
# copi i tuoi file .nb in /opt/raptor/models (con FileZilla, come utente raptor) -- questo script non li tocca.
#
# Opzioni (passate dopo lo script, es. con --tar locale per le prove):
#     --repo URL            repo pubblico da cui scaricare gli script (di serie questo stesso repo)
#     --package URL         pacchetto da scaricare (di serie l'ultima release di questo stesso repo)
#     --help
# =====================================================================================================================
set -u -o pipefail

DEFAULT_REPO_RAW="https://raw.githubusercontent.com/Federiko78/Raptor-Ai-OrangePi4Pro-Ver.0.16.10/main"
DEFAULT_PACKAGE_URL="https://github.com/Federiko78/Raptor-Ai-OrangePi4Pro-Ver.0.16.10/releases/latest/download/raptor_full_compiled.tar.gz"
REPO_RAW="$DEFAULT_REPO_RAW"
PACKAGE_URL="$DEFAULT_PACKAGE_URL"

C_B=""; C_0=""; C_OK=""; C_BAD=""
[ -t 1 ] && { C_B="\033[1m"; C_0="\033[0m"; C_OK="\033[32m"; C_BAD="\033[31m"; }
say()  { printf '%b\n' "$*"; }
ok()   { say "  ${C_OK}[ OK ]${C_0} $*"; }
bad()  { say "  ${C_BAD}[FAIL]${C_0} $*"; }
die()  { say "${C_BAD}ERRORE:${C_0} $*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_RAW="${2:?manca l'URL dopo --repo}"; shift 2 ;;
    --package) PACKAGE_URL="${2:?manca l'URL dopo --package}"; shift 2 ;;
    --help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

say "${C_B}Raptor AI - installazione automatica${C_0}"
say ""

# --------------------------------------------------------------------------------------------------- un terminale vero
# Per sicurezza, se qualcuno lo lancia comunque con "curl | bash": riattacca l'ingresso al terminale vero prima di
# qualsiasi domanda (password, nome scheda, ...). Il controllo si fa in una sottoshell, con il suo "2>/dev/null" tutto
# per se' (solo per non mostrare l'errore "No such device" se /dev/tty non esiste) -- SENZA toccare lo stderr DI QUESTA
# shell: un "exec ... 2>/dev/null" diretto qui lo azzererebbe per il resto dello script e di tutto cio' che lancia,
# nascondendo anche i prompt delle password piu' avanti (visti scritti con '>&2', non spariti: solo mai arrivati sullo
# schermo). Capitato una volta, da qui non si ripete.
( exec < /dev/tty ) 2>/dev/null || die "questo script ha bisogno di un terminale interattivo (ti chiedera' delle password): lancialo da una sessione ssh o dalla console della scheda, non da un contesto senza terminale (es. uno script non interattivo)."
exec < /dev/tty

[ "$(id -u)" -eq 0 ] && die "lancia questo script come utente orangepi, non come root (e non con sudo): e' lui che si fa dare i permessi quando servono."
[ "$(id -un)" = "orangepi" ] || say "nota: di solito questo script si lancia come 'orangepi' su una scheda nuova; procedo comunque come $(id -un)."

command -v curl >/dev/null 2>&1 || die "manca 'curl'. Su Debian: su -c 'apt-get update && apt-get install -y curl'"

WORK="$(mktemp -d /tmp/raptor-install.XXXXXX)" || die "non riesco a creare una cartella temporanea"
trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"   # il passo 3 gira come raptor via "su": deve poter leggere lo script qui dentro, anche se la cartella e' di orangepi

fetch() {   # fetch URL DEST
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || die "scaricamento fallito: $1
       Controlla la connessione di rete della scheda e riprova (puoi rilanciare questo stesso comando)."
}

# ========================================================================================= 1. la scheda e' pronta?
say "${C_B}1/3 - verifica della scheda${C_0}"
fetch "$REPO_RAW/raptor-install-check.sh" "$WORK/raptor-install-check.sh"
chmod +x "$WORK/raptor-install-check.sh"
bash "$WORK/raptor-install-check.sh" || die "la scheda non e' pronta (vedi sopra): risolvi quello che e' segnato [FAIL] e rilancia questo stesso comando."
say ""

# ========================================================================================= 2. l'utente raptor
say "${C_B}2/3 - preparazione (utente raptor)${C_0}"
fetch "$REPO_RAW/raptor-01-utente.sh" "$WORK/raptor-01-utente.sh"
chmod +x "$WORK/raptor-01-utente.sh"
bash "$WORK/raptor-01-utente.sh" --no-next-steps || die "il passo 1 ha avuto problemi (vedi sopra): correggili e rilancia questo stesso comando, riparte solo da dove serve."
say ""

# ========================================================================================= 3. l'installazione vera
# Da qui in poi si lavora come raptor: lo script si scarica da solo, nella sua cartella, il pacchetto e il
# programma di installazione, poi li lancia. Se orangepi non ha i permessi per usare "su" (caso anomalo), lo dice
# chiaramente invece di restare a metta'.
say "${C_B}3/3 - installazione${C_0}"
PHASE2="$WORK/raptor-fase2.sh"
cat > "$PHASE2" << 'PHASE2_EOF'
#!/usr/bin/env bash
set -u -o pipefail
DEST="$HOME"
curl -fsSL --retry 3 --retry-delay 2 -o "$DEST/raptor-02-installa.sh" "$1" || { echo "scaricamento di raptor-02-installa.sh fallito"; exit 1; }
curl -fsSL --retry 3 --retry-delay 2 -o "$DEST/raptor_full_compiled.tar.gz" "$2" || { echo "scaricamento del pacchetto fallito"; exit 1; }
chmod +x "$DEST/raptor-02-installa.sh"
exec bash "$DEST/raptor-02-installa.sh"
PHASE2_EOF
chmod 755 "$PHASE2"   # leggibile da raptor (lo esegue "su - raptor"), non solo da orangepi che l'ha creato

say "Ora ti chiedo la ${C_B}password di raptor${C_0} (quella appena scelta nel passo 2) per continuare da quell'utente."
if ! su - raptor -c "bash '$PHASE2' '$REPO_RAW/raptor-02-installa.sh' '$PACKAGE_URL'"; then
  die "il passo 2 ha avuto problemi (vedi sopra). Puoi rilanciare solo questa parte entrando come raptor:
       ssh raptor@$(hostname -I 2>/dev/null | awk '{print $1}')
   poi:
       curl -fsSL '$REPO_RAW/raptor-02-installa.sh' -o raptor-02-installa.sh
       curl -fsSL '$PACKAGE_URL' -o raptor_full_compiled.tar.gz
       bash raptor-02-installa.sh"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say ""
ok "Installazione finita."
say ""
say "Ora da un browser: ${C_B}http://${IP:-<indirizzo della scheda>}:5000${C_0}"
say "La prima pagina e' gia' usabile in trial (30 giorni, 1 telecamera): scegli subito tu la password dell'amministratore,"
say "prima che lo faccia qualcun altro che apre quella pagina."
say ""
say "Per il rilevamento servono i modelli: come utente raptor, copia i tuoi file .nb (con FileZilla) dentro /opt/raptor/models."

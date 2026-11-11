#!/usr/bin/env bash
# =====================================================================================================================
# raptor-pacchetto-con-modelli.sh  -  Raptor AI 0.16.10  -  fa il pacchetto "CON MODELLI" partendo da quello "senza modelli"
#
# I modelli (.nb) non stanno nel pacchetto base: sono tuoi e pesano. Questo script, da lanciare sulla scheda che li ha
# (la vecchia scheda di sviluppo), prende il pacchetto  raptor_full_0.16.10_senza_modelli.tar.gz  e ci aggiunge i modelli
# di /opt/raptor/models, producendo  raptor_full_0.16.10_con_modelli.tar.gz  (+ il suo .sha256): un solo pacchetto da
# copiare sulla scheda nuova, senza ricopiare a mano la cartella models.
#
# Cosa fa:
#   1. trova il pacchetto senza modelli e ne controlla la somma sha256
#   2. controlla i modelli: ogni model.nb deve corrispondere al suo meta.json (somma sha256); quelli rotti restano fuori
#   3. crea il pacchetto nuovo (il pacchetto base non viene toccato)
#   4. lo verifica: archivio integro e ogni modello dentro identico a quello della scheda
#
# Non serve root. Non modifica niente in /opt/raptor: legge soltanto.
#
# Uso, come utente raptor sulla scheda che ha i modelli:
#     bash /home/raptor/raptor-pacchetto-con-modelli.sh
#
# Opzioni:
#     --senza FILE     il pacchetto senza modelli (di serie: raptor_full_*_senza_modelli.tar.gz accanto allo script o in /home/raptor)
#     --modelli DIR    la cartella dei modelli (di serie: /opt/raptor/models)
#     --out FILE       il pacchetto da creare (di serie: accanto a quello di partenza, con _con_modelli al posto di _senza_modelli)
#     --yes            non chiede conferma
#     --help
# =====================================================================================================================
set -u -o pipefail

SCRIPT_VERSION="1.0.1"
MODELS="${RAPTOR_ROOT:-/opt/raptor}/models"
BASE=""
OUT=""
ASSUME_YES=0

usage() { awk 'NR==1{next} /^# =+$/{n++; if(n==2) exit; next} n==1{sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --senza) shift; BASE="${1:-}" ;;
    --modelli) shift; MODELS="${1:-}" ;;
    --out) shift; OUT="${1:-}" ;;
    --yes|-y) ASSUME_YES=1 ;;
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

printf '%s\n' "${C_B}Raptor AI - pacchetto con i modelli (script $SCRIPT_VERSION)${C_0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
for c in tar gzip python3 sha256sum df awk; do command -v "$c" >/dev/null 2>&1 || die "manca il comando $c"; done

# ------------------------------------------------------------------------------------------------ 1. pacchetto di partenza
say ""
say "${C_B}[1/4] Il pacchetto senza modelli${C_0}"
if [ -z "$BASE" ]; then
  for d in "$SCRIPT_DIR" "$(pwd)" /home/raptor; do
    for f in $(ls -t "$d"/raptor_full_*_senza_modelli.tar.gz 2>/dev/null); do BASE="$f"; break 2; done
  done
fi
[ -n "$BASE" ] || die "non trovo raptor_full_*_senza_modelli.tar.gz (cercato accanto allo script e in /home/raptor). Copialo qui con FileZilla (con il suo .sha256) oppure usa --senza FILE"
[ -f "$BASE" ] || die "il file '$BASE' non esiste"
BASE="$(readlink -f -- "$BASE")"
tar -tzf "$BASE" >/dev/null 2>&1 || die "'$BASE' non e' un archivio .tar.gz valido (copia incompleta? ricopialo in modo binario)"
ok "pacchetto: $BASE ($(hum "$(stat -c %s "$BASE")"))"
if [ -f "$BASE.sha256" ]; then
  GOT="$(sha256sum "$BASE" | cut -d' ' -f1)"; WANT="$(awk '{print $1; exit}' "$BASE.sha256")"
  if [ "$GOT" = "$WANT" ]; then ok "somma sha256 uguale a quella del file .sha256"; else die "la somma sha256 del pacchetto NON corrisponde (copia danneggiata?): attesa $WANT, trovata $GOT"; fi
else
  warn "manca $BASE.sha256: non posso verificare la copia"
fi
LIST="$(tar -tzf "$BASE")"
grep -qx 'opt/raptor/web/web.py' <<<"$LIST" || die "non sembra un pacchetto Raptor completo (manca opt/raptor/web/web.py)"
if grep -E '^opt/raptor/models/[^/]+/model\.nb$' <<<"$LIST" >/dev/null; then die "questo pacchetto contiene gia' dei modelli: serve quello 'senza modelli'"; fi
VER="$(tar -xzOf "$BASE" opt/raptor/web/web.py 2>/dev/null | sed -n 's/^VERSION *= *"\(.*\)".*/\1/p' | head -1)"
[ -n "$VER" ] && ok "versione del programma nel pacchetto: $VER" || warn "non riesco a leggere la versione dal pacchetto"
if [ -z "$OUT" ]; then
  case "$BASE" in
    *_senza_modelli.tar.gz) OUT="${BASE%_senza_modelli.tar.gz}_con_modelli.tar.gz" ;;
    *) OUT="${BASE%.tar.gz}_con_modelli.tar.gz" ;;
  esac
fi
OUTDIR="$(dirname "$OUT")"
[ -d "$OUTDIR" ] && [ -w "$OUTDIR" ] || die "non posso scrivere in $OUTDIR"

# ------------------------------------------------------------------------------------------------ 2. modelli
say ""
say "${C_B}[2/4] I modelli in $MODELS${C_0}"
[ -d "$MODELS" ] || die "non trovo la cartella dei modelli: $MODELS"
GOODFILE="$(mktemp "$OUTDIR/.modelli-ok-XXXXXX")"
trap 'rm -f "$GOODFILE"; [ -n "${TMPTAR:-}" ] && rm -f "$TMPTAR"; [ -n "${VERIFY:-}" ] && rm -rf "$VERIFY"' EXIT
CHECKOUT="$(python3 -I - "$MODELS" "$GOODFILE" <<'PY'
import hashlib, json, os, sys
models, out = sys.argv[1], sys.argv[2]
good, bad = [], []
for mid in sorted(os.listdir(models)):
    d = os.path.join(models, mid)
    if not os.path.isdir(d):
        continue
    nb, mp = os.path.join(d, "model.nb"), os.path.join(d, "meta.json")
    if not os.path.isfile(nb):
        continue
    if not os.path.isfile(mp):
        bad.append((mid, "manca meta.json")); continue
    try:
        meta = json.load(open(mp, encoding="utf-8"))
        h = hashlib.sha256()
        with open(nb, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except Exception as exc:
        bad.append((mid, "non leggibile (%s)" % type(exc).__name__)); continue
    if meta.get("id") != mid:
        bad.append((mid, "meta.json dice id '%s'" % meta.get("id"))); continue
    if meta.get("sha256") != h.hexdigest():
        bad.append((mid, "model.nb non corrisponde al suo meta.json (danneggiato?)")); continue
    good.append((mid, os.path.getsize(nb)))
with open(out, "w", encoding="utf-8") as fh:
    for mid, size in good:
        fh.write("%s\t%d\n" % (mid, size))
for mid, size in good:
    print("OK %s %d" % (mid, size))
for mid, why in bad:
    print("BAD %s %s" % (mid, why))
PY
)"
RC=$?
[ "$RC" -eq 0 ] || die "il controllo dei modelli e' fallito"
while IFS= read -r line; do
  case "$line" in
    BAD\ *) rest="${line#BAD }"; warn "modello ${rest%% *} ESCLUSO dal pacchetto: ${rest#* }" ;;
  esac
done <<<"$CHECKOUT"
NGOOD="$(wc -l <"$GOODFILE")"
[ "$NGOOD" -gt 0 ] || die "in $MODELS non c'e' nessun modello registrato e integro (cartelle <id>/model.nb + meta.json). Se hai file .nb sciolti, registrali prima:  python3 /opt/raptor/bin/raptor-models"
MSIZE="$(awk -F'\t' '{s+=$2} END{printf "%d", s}' "$GOODFILE")"
while IFS=$'\t' read -r mid size; do printf '         %-22s %10s\n' "$mid" "$(hum "$size")"; done <"$GOODFILE"
ok "$NGOOD modelli integri, $(hum "$MSIZE") in tutto"
NLOOSE="$(find "$MODELS" -maxdepth 1 -type f -name '*.nb' 2>/dev/null | wc -l)"
[ "$NLOOSE" -eq 0 ] || warn "$NLOOSE file .nb sciolti in $MODELS non sono registrati e NON entrano nel pacchetto (registrali con:  python3 /opt/raptor/bin/raptor-models)"
[ -f "$MODELS/index.json" ] || warn "manca $MODELS/index.json: il passo 2 dell'installazione lo rigenera"

# ------------------------------------------------------------------------------------------------ 3. pacchetto nuovo
say ""
say "${C_B}[3/4] Creo il pacchetto con i modelli${C_0}"
AVAIL="$(df -PB1 "$OUTDIR" 2>/dev/null | awk 'NR==2{print $4}')"; AVAIL="${AVAIL:-0}"
BSIZE="$(stat -c %s "$BASE")"
NEED=$((BSIZE*3 + MSIZE*2 + 50*1048576))        # archivio non compresso + archivio finale + copia per il controllo
printf '  libero in %s: %s   serve (al massimo): %s\n' "$OUTDIR" "$(hum "$AVAIL")" "$(hum "$NEED")"
[ "$AVAIL" -ge "$NEED" ] || die "spazio insufficiente in $OUTDIR"
printf '  Pacchetto che creo: %s\n' "$OUT"
if [ "$ASSUME_YES" != 1 ]; then
  printf '  Procedo? [S/n] '
  read -r ans </dev/tty 2>/dev/null || ans="s"
  case "${ans:-s}" in n|N|no|NO) say "Annullato: non ho scritto niente."; exit 0 ;; esac
fi
if [ -e "$OUT" ]; then warn "$(basename "$OUT") esiste gia': lo sostituisco"; fi

TMPTAR="$OUTDIR/.raptor-con-modelli-$$.tar"
gzip -dc "$BASE" >"$TMPTAR" || die "non riesco a decomprimere il pacchetto di partenza"
MPARENT="$(dirname "$MODELS")"; MBASE="$(basename "$MODELS")"
{ [ -f "$MODELS/index.json" ] && printf '%s\n' "$MBASE/index.json"
  while IFS=$'\t' read -r mid size; do printf '%s\n%s\n' "$MBASE/$mid/model.nb" "$MBASE/$mid/meta.json"; done <"$GOODFILE"; } >"$OUTDIR/.raptor-elenco-$$.txt"
if tar -rf "$TMPTAR" --owner=0 --group=0 --numeric-owner -C "$MPARENT" --transform "s,^$MBASE/,opt/raptor/models/," -T "$OUTDIR/.raptor-elenco-$$.txt"; then ok "modelli aggiunti all'archivio"
else rm -f "$OUTDIR/.raptor-elenco-$$.txt"; die "tar non e' riuscito ad aggiungere i modelli"; fi
rm -f "$OUTDIR/.raptor-elenco-$$.txt"
GZ=(gzip -3); command -v pigz >/dev/null 2>&1 && GZ=(pigz -3)     # i modelli si comprimono poco: livello 3 = molto piu' veloce e quasi uguale
say "  comprimo (puo' volerci qualche minuto)..."
( umask 022; "${GZ[@]}" -c "$TMPTAR" >"$OUT.part" ) || { rm -f "$OUT.part"; die "compressione fallita (spazio finito?)"; }
rm -f "$TMPTAR"; TMPTAR=""
mv -f "$OUT.part" "$OUT"
ok "creato $(basename "$OUT") ($(hum "$(stat -c %s "$OUT")"))"

# ------------------------------------------------------------------------------------------------ 4. verifica
say ""
say "${C_B}[4/4] Verifica${C_0}"
gzip -t "$OUT" 2>/dev/null && ok "il file compresso e' integro" || die "il pacchetto creato e' danneggiato: rifai"
LIST2="$(tar -tzf "$OUT")"
N2="$(grep -cE '^opt/raptor/models/[^/]+/model\.nb$' <<<"$LIST2")"
[ "$N2" -eq "$NGOOD" ] && ok "$N2 modelli nel pacchetto (attesi $NGOOD)" || die "nel pacchetto ci sono $N2 modelli ma ne attendevo $NGOOD"
grep -qx 'opt/raptor/web/web.py' <<<"$LIST2" && grep -qx 'opt/raptor/MANIFEST.sha256' <<<"$LIST2" && ok "il programma e il MANIFEST sono ancora tutti nel pacchetto" || die "nel pacchetto nuovo manca parte del programma"
VERIFY="$(mktemp -d "$OUTDIR/.raptor-verifica-XXXXXX")"
if tar -xzf "$OUT" -C "$VERIFY" --no-same-owner --wildcards 'opt/raptor/models/*' 2>/dev/null; then
  BADN=0
  while IFS=$'\t' read -r mid size; do
    a="$(sha256sum "$VERIFY/opt/raptor/models/$mid/model.nb" 2>/dev/null | cut -c1-64)"
    b="$(sha256sum "$MODELS/$mid/model.nb" | cut -c1-64)"
    [ -n "$a" ] && [ "$a" = "$b" ] || { bad "modello $mid: diverso dall'originale"; BADN=$((BADN+1)); }
  done <"$GOODFILE"
  [ "$BADN" -eq 0 ] && ok "ogni modello nel pacchetto e' identico a quello della scheda" || die "$BADN modelli non coincidono: non usare questo pacchetto"
else
  warn "non sono riuscito a estrarre i modelli per il controllo finale (poco spazio?): il file e' comunque integro"
fi
rm -rf "$VERIFY"; VERIFY=""
( cd "$OUTDIR" && sha256sum -b "$(basename "$OUT")" >"$(basename "$OUT").sha256" )
chmod 644 "$OUT" "$OUT.sha256" 2>/dev/null || true

say ""
say "${C_B}FATTO${C_0}"
say "  Pacchetto : $OUT   ($(hum "$(stat -c %s "$OUT")"))"
say "  sha256    : $(cut -c1-64 "$OUT.sha256")"
say ""
say "  Sulla scheda nuova copialo (insieme al suo .sha256) in /home/raptor, accanto a raptor-02-installa.sh: lo trova da solo."
say "  Non c'e' piu' bisogno di copiare a mano la cartella dei modelli."
[ "$WARNS" -eq 0 ] || say "  Avvisi: $WARNS (vedi le righe [WARN])"

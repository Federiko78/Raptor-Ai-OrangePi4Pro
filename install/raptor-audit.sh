#!/usr/bin/env bash
# =====================================================================================================================
# raptor-audit.sh  -  Raptor AI  -  FOTOGRAFIA della scheda (solo lettura): cosa e' installato, cosa e' stato cambiato
#
# Serve a vedere, sulla scheda di sviluppo, tutto quello che conta per rifare un'installazione da zero identica:
# utenti, SSH, versione e proprietari di /opt/raptor, nomi dei file di configurazione, modelli, servizi e unit systemd,
# porte, rete, Tailscale, cron, pacchetti, librerie NPU. Con --pacchetto confronta il codice installato con un pacchetto .tar.gz.
#
# NON modifica niente (nessuna scrittura tranne il file del report) e NON contiene segreti: niente password, token, chiavi,
# niente contenuto dei file di configurazione (solo i nomi, i permessi e i NOMI delle voci YAML). Le righe che sembrano
# contenere un segreto (token, password, chiave, psk, secret) sono comunque coperte con <omesso>.
#
# Uso, come utente raptor (non serve root):
#     bash /home/raptor/raptor-audit.sh
#     bash /home/raptor/raptor-audit.sh --pacchetto /home/raptor/raptor_engine_npu_0.16.10.tar.gz
#
# Opzioni:
#     --pacchetto FILE   confronta il codice installato con questo pacchetto (.tar.gz con opt/raptor/...)
#     --out FILE         dove scrivere il report (predefinito: ~/raptor-audit-NOMESCHEDA-DATA.txt)
#     --help
#
# Il report e' un file di testo: scaricalo con FileZilla e mandalo, oppure  cat  del file e incolla.
# =====================================================================================================================
set -u -o pipefail

SCRIPT_VERSION="1.0.0"
FR="${RAPTOR_FAKE_ROOT:-}"                 # solo per le prove: radice finta al posto di /
R="${RAPTOR_ROOT:-$FR/opt/raptor}"
PKG=""
OUT=""
LIMIT=60                                   # righe massime per ogni elenco lungo

usage() { awk 'NR==1{next} /^# =+$/{n++; if(n==2) exit; next} n==1{sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pacchetto|--package) shift; PKG="${1:-}" ;;
    --out) shift; OUT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opzione sconosciuta: %s  (vedi --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$PKG" ] && [ ! -r "$PKG" ]; then printf 'Non trovo il pacchetto: %s\n' "$PKG" >&2; exit 2; fi

HOST="$(hostname 2>/dev/null || echo scheda)"
STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT" ] || OUT="${HOME:-/tmp}/raptor-audit-$HOST-$STAMP.txt"
(umask 077; : >"$OUT") 2>/dev/null || { printf 'Non posso scrivere il report in %s\n' "$OUT" >&2; exit 1; }

exec 3>&1                                  # lo schermo (il report va su file)

# ------------------------------------------------------------------------------------------------ strumenti del report
# copre il valore delle righe che sembrano contenere un segreto
mask() {
  sed -E 's/(([Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][A-Za-z]*|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Ss][Kk]|[Kk][Ee][Yy]|[Aa][Uu][Tt][Hh][Kk]?)[A-Za-z0-9_.-]*[[:space:]]*[=:][[:space:]]*).*/\1<omesso>/'
}
sec() { printf '\n=== %s ===\n' "$1"; printf '  %s\n' "$1" >&3; }
sub() { printf '\n--- %s\n' "$1"; }
# esegue un comando e ne mostra l'uscita (coperta, limitata); non fallisce mai
run() {
  printf '$ %s\n' "$*"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ -n "$out" ]; then printf '%s\n' "$out" | mask | head -n "$LIMIT"; fi
  [ "$rc" -eq 0 ] || printf '(uscita %s)\n' "$rc"
  return 0
}
# come run, ma per una pipeline scritta come stringa
runsh() {
  printf '$ %s\n' "$1"
  local out
  out="$(bash -c "$1" 2>&1)"
  if [ -n "$out" ]; then printf '%s\n' "$out" | mask | head -n "${2:-$LIMIT}"; fi
  return 0
}
have() { command -v "$1" >/dev/null 2>&1; }
show_file() {   # contenuto (coperto) di un file piccolo
  if [ -r "$1" ]; then printf '$ cat %s\n' "$1"; mask <"$1" | head -n "${2:-40}"; else printf '(non c'"'"'e'"'"' o non e'"'"' leggibile: %s)\n' "$1"; fi
}

report() {
printf 'Raptor AI - audit della scheda  (script %s)\n' "$SCRIPT_VERSION"
printf 'Data: %s   Utente: %s (uid %s)   Cartella programma: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(id -un)" "$(id -u)" "$R"
printf 'Nessun segreto in questo file: password, token, chiavi e contenuto dei file di configurazione non vengono letti.\n'

# ---------------------------------------------------------------------------------------------------------------- 1
sec "1. La scheda e il sistema"
runsh "tr -d '\\0' <$FR/proc/device-tree/model; echo"
runsh "tr '\\0' ' ' <$FR/proc/device-tree/compatible; echo"
run uname -a
runsh "grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)=' $FR/etc/os-release"
show_file "$FR/etc/orangepi-release"
runsh "nproc; free -m | head -3"
runsh "df -h / $FR/opt 2>/dev/null | sort -u"
run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
run uptime
run date
run hostnamectl
run timedatectl
show_file "$FR/boot/orangepiEnv.txt" 30

# ---------------------------------------------------------------------------------------------------------------- 2
sec "2. Utenti, gruppi, sudo, SSH"
runsh "getent passwd | awk -F: '\$3==0 || (\$3>=1000 && \$3<60000 && \$7 !~ /nologin|false/) {print \$1\":uid=\"\$3\":gid=\"\$4\":home=\"\$6\":shell=\"\$7}'"
for u in raptor orangepi root; do runsh "id $u"; done
runsh "getent group video dialout gpio i2c spi render systemd-journal sudo raptor"
runsh "command -v sudo || echo 'sudo: non installato'"
runsh "ls -l $FR/etc/sudoers.d 2>&1"
runsh "passwd -S \"\$(id -un)\" 2>&1"
sub "sshd (valori impostati)"
runsh "grep -hE '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|ListenAddress|Banner)' $FR/etc/ssh/sshd_config $FR/etc/ssh/sshd_config.d/*.conf 2>/dev/null"
runsh "systemctl is-active ssh sshd 2>&1"
sub "chiavi autorizzate (solo quante, mai il contenuto)"
for h in $FR/home/raptor $FR/home/orangepi $FR/root; do
  f="$h/.ssh/authorized_keys"
  if [ -r "$f" ]; then printf '%s: %s chiavi\n' "$f" "$(grep -cvE '^\s*(#|$)' "$f")"; else printf '%s: nessuna (o non leggibile)\n' "$f"; fi
done

# ---------------------------------------------------------------------------------------------------------------- 3
sec "3. Il programma in $R"
runsh "ls -ld $R"
runsh "stat -c '%U:%G %a %n' $R/* 2>/dev/null"
sub "versioni dichiarate nel codice (righe VERSION =)"
runsh "cd $R 2>/dev/null && grep -rIn --include='*.py' -E '^VERSION[[:space:]]*=' . 2>/dev/null | grep -v '/tests/' | head -20"
sub "dimensioni"
runsh "cd $R 2>/dev/null && du -sk * 2>/dev/null | sort -rn"
sub "il file MANIFEST (se c'e') e le cartelle di appoggio"
runsh "ls -l $R/MANIFEST.sha256 $R/install $R/native 2>&1 | head -30"
runsh "ls -l $R/native/*.so $R/native/build 2>&1 | head -20"
runsh "ls -d $R/venv $R/.git 2>&1"
if [ -x "$R/venv/bin/python" ]; then run "$R/venv/bin/python" -V; fi

sub "config/: nomi, proprietari, permessi (MAI il contenuto)"
runsh "stat -c '%U:%G %a %s byte  %y  %n' $R/config/* 2>/dev/null | sed 's#$R/##'"
if have python3; then
python3 - "$R/config" <<'PY' 2>&1 | head -80
import glob, os, sys
try:
    import yaml
except Exception:
    print("(PyYAML non disponibile: salto l'elenco delle voci)"); sys.exit(0)
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yaml"))):
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception as e:
        print("%s: non leggibile (%s)" % (os.path.basename(f), type(e).__name__)); continue
    if isinstance(d, dict):
        parts = []
        for k, v in d.items():
            t = type(v).__name__
            parts.append("%s[%s%s]" % (k, t, ("=%d" % len(v)) if isinstance(v, (list, dict)) else ""))
        print("%s: %s" % (os.path.basename(f), ", ".join(parts)[:300]))
    else:
        print("%s: %s" % (os.path.basename(f), type(d).__name__))
PY
fi

sub "modelli"
runsh "stat -c '%U:%G %a %n' $R/models $R/models/* 2>/dev/null | sed 's#$R/##' | head -80"
if have python3 && [ -f "$R/models/index.json" ]; then
python3 - "$R/models" <<'PY' 2>&1 | head -80
import hashlib, json, os, sys
m = sys.argv[1]
try:
    idx = json.load(open(os.path.join(m, "index.json"), encoding="utf-8"))
except Exception as e:
    print("index.json non leggibile:", type(e).__name__); sys.exit(0)
items = idx.get("models", idx) if isinstance(idx, dict) else idx
if isinstance(items, dict):
    items = list(items.values())
print("modelli registrati nell'indice:", len(items))
bad = 0
for it in items:
    mid = it.get("id") if isinstance(it, dict) else str(it)
    nb = os.path.join(m, mid, "model.nb")
    meta = os.path.join(m, mid, "meta.json")
    state = []
    if not os.path.isfile(nb):
        state.append("MANCA model.nb")
    else:
        try:
            want = json.load(open(meta, encoding="utf-8")).get("sha256")
            h = hashlib.sha256(open(nb, "rb").read()).hexdigest()
            state.append("sha256 ok" if want == h else "sha256 DIVERSO dal meta.json")
            if want != h: bad += 1
        except Exception as e:
            state.append("meta.json non leggibile (%s)" % type(e).__name__); bad += 1
        state.append("%d byte" % os.path.getsize(nb))
    print("  %-22s %s" % (mid, ", ".join(state)))
print("modelli con problemi:", bad)
PY
else
  echo "(nessun models/index.json)"
fi
runsh "ls $R/models 2>&1 | head -60"
runsh "find $R/models -maxdepth 3 -type f \\( -name '*.nb' -o -name '*.onnx' -o -name '*.tflite' \\) -printf '%s %P\\n' 2>/dev/null | sort -k2 | head -80"

# ---------------------------------------------------------------------------------------------------------------- 4
sec "4. Confronto del codice installato con il pacchetto"
if [ -z "$PKG" ]; then
  echo "(non richiesto: rilancia con --pacchetto FILE.tar.gz per il confronto)"
elif ! have python3; then
  echo "(serve python3)"
else
  printf 'Pacchetto: %s\n' "$(basename "$PKG")"
  python3 - "$PKG" "$R" <<'PY' 2>&1
import hashlib, os, re, sys, tarfile
pkg, root = sys.argv[1], sys.argv[2]
SKIP_TOP = {"config", "data", "models", "venv"}
VER = re.compile(rb'^VERSION\s*=\s*["\']([^"\']+)["\']', re.M)

def strip(name):
    n = os.path.normpath(name).lstrip("/")
    for pre in ("opt/raptor/", "raptor/"):
        if n.startswith(pre):
            return n[len(pre):]
    return n

pk = {}
with tarfile.open(pkg, "r:*") as t:
    for m in t:
        if not m.isfile():
            continue
        rel = strip(m.name)
        if not rel or rel.split("/")[0] in SKIP_TOP or rel == "MANIFEST.sha256" or rel.endswith(".pyc"):
            continue
        d = t.extractfile(m).read()
        pk[rel] = (hashlib.sha256(d).hexdigest(), len(d), (VER.search(d).group(1).decode() if rel.endswith(".py") and VER.search(d) else None))
print("file nel pacchetto (senza config/data/models):", len(pk))

same = diff = 0
different, missing = [], []
for rel, (h, size, ver) in sorted(pk.items()):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        missing.append(rel); continue
    d = open(p, "rb").read()
    if hashlib.sha256(d).hexdigest() == h:
        same += 1
    else:
        v2 = VER.search(d).group(1).decode() if rel.endswith(".py") and VER.search(d) else None
        different.append((rel, v2, ver, len(d), size))
extra = []
for dp, dn, fn in os.walk(root):
    rp = os.path.relpath(dp, root)
    top = rp.split(os.sep)[0] if rp != "." else ""
    if top in SKIP_TOP or "__pycache__" in dp.split(os.sep) or top == ".git":
        dn[:] = []; continue
    for f in fn:
        rel = os.path.normpath(os.path.join(rp, f))
        if f.endswith((".pyc", ".pyo")) or rel in pk or rel == "MANIFEST.sha256" or f.startswith((".tmp-", ".db-")):
            continue
        extra.append(rel)
print("uguali al pacchetto :", same)
print("DIVERSI             :", len(different))
for rel, v2, ver, a, b in different[:60]:
    print("    %-52s scheda %s%s  pacchetto %s%s" % (rel, a, (" (VERSION %s)" % v2) if v2 else "", b, (" (VERSION %s)" % ver) if ver else ""))
def by_folder(names):
    out = {}
    for n in names:
        top = n.split("/")[0]
        out[top] = out.get(top, 0) + 1
    return ", ".join("%s: %d" % kv for kv in sorted(out.items()))
print("MANCANO sulla scheda:", len(missing), ("(" + by_folder(missing) + ")") if missing else "")
no_tests = [m for m in missing if "/tests/" not in m]
print("   di cui fuori dalle cartelle tests:", len(no_tests))
for rel in no_tests[:60]:
    print("    " + rel)
print("IN PIU' sulla scheda (non sono nel pacchetto):", len(extra), ("(" + by_folder(extra) + ")") if extra else "")
for rel in sorted(extra)[:60]:
    print("    " + rel)
PY
fi

# ---------------------------------------------------------------------------------------------------------------- 5
sec "5. Dati (solo dimensioni e nomi)"
runsh "cd $R/data 2>/dev/null && du -sk * 2>/dev/null | sort -rn"
runsh "stat -c '%U:%G %a %n' $R/data $R/data/* 2>/dev/null | sed 's#$R/##'"
runsh "ls $R/data/events 2>/dev/null | wc -l | sed 's/^/file in data\\/events: /'"
runsh "ls $R/data/events 2>/dev/null | sort | sed -n '1p;\$p'"
runsh "ls -l $R/data/state $R/data/backups 2>&1 | head -40"
runsh "ls $R/data/logs 2>/dev/null | wc -l | sed 's/^/file in data\\/logs: /'"
DB="$R/data/statistics/statistics.db"
if have python3 && [ -f "$DB" ]; then
python3 - "$DB" <<'PY' 2>&1
import sqlite3, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=5)
    print("statistics.db integrity:", c.execute("PRAGMA integrity_check").fetchone()[0])
    for (n,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").fetchall():
        print("  tabella %-24s righe %d" % (n, c.execute('SELECT COUNT(*) FROM "%s"' % n.replace('"', '')).fetchone()[0]))
except Exception as e:
    print("statistics.db: non leggibile (%s)" % type(e).__name__)
PY
fi

# ---------------------------------------------------------------------------------------------------------------- 6
sec "6. Servizi e unit systemd"
UNITS="raptor-detector.service raptor-web.service raptor-watchdog.service raptor-notifications.service raptor-alarm-monitor.service raptor-admin.socket raptor-assistance.service raptor-network-guard.timer"
for u in $UNITS; do
  printf '%-34s enabled=%-10s active=%s\n' "$u" "$(systemctl is-enabled "$u" 2>&1 | head -1)" "$(systemctl is-active "$u" 2>&1 | head -1)"
done
run systemctl --failed --no-legend --no-pager
sub "dati di esecuzione (utente, riavvii, avvio)"
for u in raptor-detector raptor-web raptor-watchdog raptor-notifications raptor-alarm-monitor; do
  runsh "systemctl show $u -p User -p Group -p NRestarts -p ActiveEnterTimestamp -p MainPID 2>&1 | tr '\\n' ' '; echo"
done
sub "unit installate in /etc/systemd/system confrontate con quelle del programma"
for f in $FR/etc/systemd/system/raptor-*; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  if [ -d "$f" ]; then printf '%s/  (cartella)\n' "$b"; ls -l "$f" | tail -n +2; continue; fi
  src=""
  for d in "$R/services/units" "$R/services/admin"; do [ -f "$d/$b" ] && src="$d/$b"; done
  if [ -n "$src" ]; then
    if cmp -s "$f" "$src"; then printf '%-34s uguale a %s\n' "$b" "${src#$R/}"; else printf '%-34s DIVERSA da %s:\n' "$b" "${src#$R/}"; diff <(mask <"$src") <(mask <"$f") | head -20; fi
  else
    printf '%-34s (nessun originale nel programma)\n' "$b"
  fi
done
sub "drop-in e unit non Raptor messe a mano in /etc/systemd/system"
runsh "find $FR/etc/systemd/system -maxdepth 2 \\( -type f -o -type d -name '*.d' \\) ! -name 'raptor-*' ! -path '*/raptor-*' -printf '%y %P\\n' 2>/dev/null | head -40"
runsh "ls -l $FR/etc/systemd/system/raptor-*.service.d/* 2>&1 | head -20"
runsh "cat $FR/etc/systemd/system/raptor-*.service.d/*.conf 2>/dev/null | head -60"
sub "regola udev, sysctl, helper di amministrazione"
show_file "$FR/etc/udev/rules.d/60-raptor-gpio.rules" 10
runsh "ls $FR/etc/udev/rules.d"
show_file "$FR/etc/sysctl.d/99-raptor-assistance.conf" 10
runsh "ls -l $FR/usr/local/sbin $FR/var/lib/raptor-admin 2>&1 | head -20"
if [ -f "$FR/usr/local/sbin/raptor-admin" ] && [ -f "$R/services/admin/raptor_admin.py" ]; then
  if cmp -s "$FR/usr/local/sbin/raptor-admin" "$R/services/admin/raptor_admin.py"; then echo "raptor-admin: uguale a services/admin/raptor_admin.py"; else echo "raptor-admin: DIVERSO da services/admin/raptor_admin.py"; fi
fi

# ---------------------------------------------------------------------------------------------------------------- 7
sec "7. Porte, rete, Tailscale, orologio"
run ss -ltnH
run ip -br addr
run ip route
run nmcli -t -f NAME,TYPE,DEVICE connection show
run nmcli -t -f DEVICE,TYPE,STATE device
sub "regole del firewall (file, se presente)"
show_file "$FR/etc/nftables.conf" 60
runsh "systemctl is-enabled nftables 2>&1; systemctl is-active nftables 2>&1"
sub "Tailscale"
if have tailscale; then
  run tailscale version
  runsh "tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"BackendState:\", d.get(\"BackendState\"), \" Self online:\", (d.get(\"Self\") or {}).get(\"Online\"))'"
  runsh "systemctl is-enabled tailscaled 2>&1; systemctl is-active tailscaled 2>&1"
else
  echo "tailscale: non installato"
fi
sub "chrony"
runsh "chronyc tracking 2>&1 | head -4"
runsh "grep -vE '^[[:space:]]*(#|$)' $FR/etc/chrony/chrony.conf 2>/dev/null | head -30"
runsh "ls $FR/etc/chrony/sources.d 2>&1"

# ---------------------------------------------------------------------------------------------------------------- 8
sec "8. Cron e timer"
run crontab -l
runsh "ls -l $FR/etc/cron.d 2>&1"
runsh "systemctl list-timers --all --no-legend --no-pager 2>&1 | head -20"

# ---------------------------------------------------------------------------------------------------------------- 9
sec "9. Pacchetti e Python"
for p in ca-certificates curl openssl iproute2 iputils-ping nftables chrony network-manager python3 python3-venv python3-numpy python3-opencv python3-yaml python3-cryptography ffmpeg gcc libc6-dev; do
  v="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
  printf '%-22s %s\n' "$p" "${v:-NON INSTALLATO}"
done
if have python3; then
  python3 - <<'PY' 2>&1
import importlib
for m in ("yaml", "numpy", "cv2", "cryptography", "sqlite3", "PIL", "flask", "requests", "onnxruntime", "psutil"):
    try:
        mod = importlib.import_module(m)
        print("python3: %-13s %s" % (m, getattr(mod, "__version__", getattr(mod, "version", "ok"))))
    except Exception as e:
        print("python3: %-13s assente" % m)
PY
  run python3 -V
fi
run ffmpeg -hide_banner -version
sub "pacchetti scelti a mano (apt-mark showmanual)"
runsh "apt-mark showmanual 2>/dev/null | tr '\\n' ' '; echo" 200
runsh "dpkg -l 2>/dev/null | grep -c '^ii' | sed 's/^/pacchetti installati in tutto: /'"
sub "pip di sistema"
runsh "pip3 list --format=freeze 2>/dev/null | head -60"

# ---------------------------------------------------------------------------------------------------------------- 10
sec "10. NPU e librerie del produttore"
runsh "ls -l $FR/dev 2>/dev/null | grep -iE 'vip|npu|galcore|cedar|video|dri|gpiochip|ttyS|ttyUSB' | head -30"
runsh "lsmod | grep -iE 'vip|npu|gal|cedar|ve' | head"
runsh "ldconfig -p 2>/dev/null | grep -iE 'viplite|VIPhal|NBGlinker|vipnano|cedarc|ovxlib|openvx|libGAL|libraptor' | head -20"
for lib in $(ldconfig -p 2>/dev/null | grep -iE 'libVIPhal|libNBGlinker|libraptor_npu' | awk '{print $NF}' | sort -u | head -6); do
  [ -r "$lib" ] && printf '%s  %s\n' "$(sha256sum "$lib" | cut -c1-64)" "$lib"
done
runsh "ls -l $FR/usr/lib/libVIP* $FR/usr/lib/libNBG* $FR/usr/lib/libraptor* $FR/usr/local/lib/lib* 2>/dev/null | head -20"
runsh "dmesg 2>/dev/null | grep -iE 'vip|npu|galcore' | tail -8"

# ---------------------------------------------------------------------------------------------------------------- 11
sec "11. Cartelle personali (solo nomi e dimensioni)"
for h in $FR/home/raptor $FR/home/orangepi; do
  [ -d "$h" ] || continue
  sub "$h"
  runsh "ls -la --time-style=long-iso $h | head -80" 80
done
sub "pacchetti e archivi grandi nella cartella di raptor"
runsh "find $FR/home -maxdepth 2 -type f -size +5M -printf '%s %TY-%Tm-%Td %p\\n' 2>/dev/null | sort -k3 | head -30"

# ---------------------------------------------------------------------------------------------------------------- 12
sec "12. Errori recenti dei servizi (ultime 24 ore, solo livello errore)"
runsh "journalctl -u 'raptor-*' --since '24 hours ago' -p err --no-pager -q 2>&1 | tail -30" 30

printf '\n=== fine del report ===\n'
}

report >"$OUT" 2>&1
chmod 600 "$OUT" 2>/dev/null || true
LINES="$(wc -l <"$OUT")"
printf '\nFatto. Report: %s  (%s righe, %s byte)\n' "$OUT" "$LINES" "$(stat -c %s "$OUT")"
printf 'Non contiene segreti. Scaricalo con FileZilla e mandalo, oppure:  cat %s  e incolla.\n' "$OUT"

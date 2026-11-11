#!/usr/bin/env bash
# =====================================================================================================================
# test_raptor_00_verifica.sh  -  collaudi di raptor-00-verifica.sh (una scheda finta per ogni prova, nessuna vera)
#
# Uso:
#     bash install/tests/test_raptor_00_verifica.sh
#
# Costruisce, per ogni prova, una cartella finta (RAPTOR_VERIFY_ROOT) con solo i file che lo script legge
# (/proc/device-tree/model, /etc/os-release, /proc/meminfo, /sys/module/vipcore, /dev/vipcore, /usr/lib/*.so) e lancia
# lo script vero contro quella cartella, con RAPTOR_VERIFY_ARCH/KERNEL/YEAR al posto di uname/data e
# RAPTOR_VERIFY_SKIP_NET=1 (le prove di rete vanno viste a parte, con la macchina vera: vedi l'ultima prova).
# =====================================================================================================================
set -u -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../raptor-00-verifica.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

check() {   # check "nome prova" exit_atteso grep_atteso -- comando...
  local name="$1" want_rc="$2" want_grep="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" != "$want_rc" ]; then
    printf '[FALLITA] %s: uscita %s, attesa %s\n%s\n' "$name" "$rc" "$want_rc" "$out"; FAIL=$((FAIL+1)); return
  fi
  if [ -n "$want_grep" ] && ! grep -qF "$want_grep" <<<"$out"; then
    printf '[FALLITA] %s: non trovo "%s" nell'"'"'uscita\n%s\n' "$name" "$want_grep" "$out"; FAIL=$((FAIL+1)); return
  fi
  printf '[  ok   ] %s\n' "$name"; PASS=$((PASS+1))
}

make_good_board() {   # make_good_board DIR  -> una scheda finta che passa tutti i controlli bloccanti
  local d="$1"
  mkdir -p "$d/proc/device-tree" "$d/etc" "$d/sys/module/vipcore" "$d/dev" "$d/usr/lib"
  printf 'Orange Pi 4 Pro\0' >"$d/proc/device-tree/model"
  cat >"$d/etc/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
ID=debian
VERSION_ID="12"
EOF
  printf 'MemTotal:        5800000 kB\n' >"$d/proc/meminfo"
  : >"$d/dev/vipcore"
  : >"$d/usr/lib/libVIPhal.so"
  : >"$d/usr/lib/libNBGlinker.so"
}

run() {   # run DIR [altre env...] -- lancia lo script sulla scheda finta DIR con kernel/arch/anno buoni di serie
  local d="$1"; shift
  env RAPTOR_VERIFY_ROOT="$d" RAPTOR_VERIFY_ARCH=aarch64 RAPTOR_VERIFY_KERNEL="6.1.0-sun60iw2" RAPTOR_VERIFY_YEAR=2026 \
      RAPTOR_VERIFY_SKIP_NET=1 "$@" bash "$SCRIPT"
}

# -------------------------------------------------------------------------------------------- 1. scheda a posto -> 0, tutto OK
d="$TMP/good"; make_good_board "$d"
check "scheda a posto: esce 0" 0 "Tutto a posto: puoi procedere" run "$d"
check "scheda a posto: nessun FAIL" 0 "" bash -c "out=\$(RAPTOR_VERIFY_ROOT='$d' RAPTOR_VERIFY_ARCH=aarch64 RAPTOR_VERIFY_KERNEL='6.1.0-sun60iw2' RAPTOR_VERIFY_YEAR=2026 RAPTOR_VERIFY_SKIP_NET=1 bash '$SCRIPT'); ! grep -q FAIL <<<\"\$out\""

# -------------------------------------------------------------------------------------------- 2. architettura sbagliata -> 1, FAIL
d="$TMP/badarch"; make_good_board "$d"
check "architettura x86_64: esce 1 e segnala" 1 "architettura x86_64" \
  env RAPTOR_VERIFY_ROOT="$d" RAPTOR_VERIFY_ARCH=x86_64 RAPTOR_VERIFY_KERNEL="6.1.0-sun60iw2" RAPTOR_VERIFY_YEAR=2026 RAPTOR_VERIFY_SKIP_NET=1 bash "$SCRIPT"

# -------------------------------------------------------------------------------------------- 3. sistema operativo sbagliato -> 1, FAIL
d="$TMP/bados"; make_good_board "$d"
cat >"$d/etc/os-release" <<'EOF'
PRETTY_NAME="Ubuntu 22.04.3 LTS"
ID=ubuntu
VERSION_ID="22.04"
EOF
check "Ubuntu invece di Debian 12: esce 1 e segnala" 1 "Debian 12" run "$d"

# -------------------------------------------------------------------------------------------- 4. kernel sbagliato -> 1, FAIL (bloccante: e' il problema reale avuto)
d="$TMP/badkernel"; make_good_board "$d"
check "kernel non sun60iw2: esce 1 e segnala" 1 "non e' il BSP sun60iw2" \
  env RAPTOR_VERIFY_ROOT="$d" RAPTOR_VERIFY_ARCH=aarch64 RAPTOR_VERIFY_KERNEL="5.15.0-generic" RAPTOR_VERIFY_YEAR=2026 RAPTOR_VERIFY_SKIP_NET=1 bash "$SCRIPT"

# -------------------------------------------------------------------------------------------- 5. poca RAM -> 0 (solo avviso, non blocca)
d="$TMP/lowram"; make_good_board "$d"
printf 'MemTotal:        2000000 kB\n' >"$d/proc/meminfo"
check "poca RAM: esce 0 ma avvisa" 0 "WARN" run "$d"

# -------------------------------------------------------------------------------------------- 6. poco spazio (sotto i 3000 MB) -> 1, FAIL
#    non possiamo far mentire "df" in sola lettura senza un vero filesystem piccolo: simuliamo rimpiazzando temporaneamente
#    la funzione "df" nel path con uno script finto, cosa che lo script fa con un comando esterno e non una builtin.
d="$TMP/lowdisk"; make_good_board "$d"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1M-blocks Used Available Use% Mounted"
echo "fake 100000 98500 1500 99% /"
EOF
chmod +x "$FAKEBIN/df"
check "poco spazio libero: esce 1 e segnala" 1 "servono almeno 3000" \
  env PATH="$FAKEBIN:$PATH" RAPTOR_VERIFY_ROOT="$d" RAPTOR_VERIFY_ARCH=aarch64 RAPTOR_VERIFY_KERNEL="6.1.0-sun60iw2" RAPTOR_VERIFY_YEAR=2026 RAPTOR_VERIFY_SKIP_NET=1 bash "$SCRIPT"

# -------------------------------------------------------------------------------------------- 7. NPU assente -> 1, FAIL
d="$TMP/nonpu"; make_good_board "$d"
rm -rf "$d/sys/module/vipcore" "$d/dev/vipcore"
check "driver e dispositivo NPU assenti: esce 1" 1 "driver NPU 'vipcore' non caricato" run "$d"

# -------------------------------------------------------------------------------------------- 8. librerie NPU assenti -> 1, FAIL
d="$TMP/nolib"; make_good_board "$d"
rm -f "$d/usr/lib/libVIPhal.so"
check "libVIPhal.so assente: esce 1" 1 "libVIPhal.so manca" run "$d"

# -------------------------------------------------------------------------------------------- 9. orologio indietro nel tempo -> 1, FAIL
d="$TMP/badclock"; make_good_board "$d"
check "anno 2024: esce 1 e segnala l'orologio" 1 "orologio e' sbagliato" \
  env RAPTOR_VERIFY_ROOT="$d" RAPTOR_VERIFY_ARCH=aarch64 RAPTOR_VERIFY_KERNEL="6.1.0-sun60iw2" RAPTOR_VERIFY_YEAR=2024 RAPTOR_VERIFY_SKIP_NET=1 bash "$SCRIPT"

# -------------------------------------------------------------------------------------------- 10. --force prosegue nonostante i FAIL
d="$TMP/forced"; make_good_board "$d"
check "--force su architettura sbagliata: esce 0 comunque" 0 "procedo comunque" \
  env RAPTOR_VERIFY_ROOT="$d" RAPTOR_VERIFY_ARCH=x86_64 RAPTOR_VERIFY_KERNEL="6.1.0-sun60iw2" RAPTOR_VERIFY_YEAR=2026 RAPTOR_VERIFY_SKIP_NET=1 bash "$SCRIPT" --force

# -------------------------------------------------------------------------------------------- 11. --help non controlla nulla, esce 0
check "--help: esce 0 e mostra l'uso" 0 "Uso" bash "$SCRIPT" --help

printf '\n%s passate, %s fallite\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

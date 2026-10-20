#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
export HOME="$tmp_dir/home" OMARCHY_PATH="$ROOT"
export OMARCHY_PCI_DEVICES_PATH="$tmp_dir/PCI devices"
export PATH="$tmp_dir/bin:$ROOT/bin:$PATH"
export TEST_LOG="$tmp_dir/calls" TEST_INSTALLED="$tmp_dir/installed"

# No hardware probing or package transaction may escape the fixtures. Exercise
# the real detectors, package helpers, hardware leaf, and migration together.
cat >"$tmp_dir/bin/lsmod" <<'SH'
#!/bin/bash
echo lsmod >>"$TEST_LOG"
if [[ ${TEST_MODULE_LOADED:-0} == "1" ]]; then
  echo 'amdgpu 1 0'
fi
SH
cat >"$tmp_dir/bin/lspci" <<'SH'
#!/bin/bash
echo lspci >>"$TEST_LOG"
exit 1
SH
cat >"$tmp_dir/bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cat >"$tmp_dir/bin/pacman" <<'SH'
#!/bin/bash
case "$1" in
  -Q)
    [[ $# == 3 && $2 == "--" ]] || exit 90
    grep -Fxq -- "$3" "$TEST_INSTALLED"
    ;;
  -S)
    [[ $* == "-S --noconfirm --needed -- rocm-smi-lib" ]] || exit 91
    echo install >>"$TEST_LOG"
    case "${TEST_INSTALL_MODE:-success}" in
      failure) exit 42 ;;
      unregistered) exit 0 ;;
      success) echo rocm-smi-lib >>"$TEST_INSTALLED" ;;
      *) exit 92 ;;
    esac
    ;;
  *) exit 93 ;;
esac
SH
chmod +x "$tmp_dir/bin"/*

reset_fixture() {
  rm -rf "$OMARCHY_PCI_DEVICES_PATH"
  mkdir -p "$OMARCHY_PCI_DEVICES_PATH"
  : >"$TEST_LOG"
  : >"$TEST_INSTALLED"
  export TEST_MODULE_LOADED=0 TEST_INSTALL_MODE=success
}

add_device() {
  local device_dir="$OMARCHY_PCI_DEVICES_PATH/$1"
  mkdir -p "$device_dir"
  printf '%s\n' "$2" >"$device_dir/vendor"
  printf '%s\n' "$3" >"$device_dir/class"
}

while IFS='|' read -r description expected module devices; do
  reset_fixture
  export TEST_MODULE_LOADED="$module"
  slot=0
  for spec in $devices; do
    add_device "$slot" "${spec%:*}" "${spec#*:}"
    slot=$((slot + 1))
  done
  status=0
  omarchy-hw-amd-gpu >"$tmp_dir/output" 2>"$tmp_dir/errors" || status=$?
  [[ $status == "$expected" ]] || fail "$description" "expected $expected, got $status"
  [[ ! -s $tmp_dir/output && ! -s $tmp_dir/errors ]] || fail "$description: silent detector"
  [[ ! -s $TEST_LOG ]] || fail "$description: only cached PCI IDs are read" "$(cat "$TEST_LOG")"
  pass "$description"
done <<'CASES'
AMD VGA without amdgpu loaded|0|0|0x1002:0x030000
Radeon 8060S Display class 038000 without amdgpu loaded|0|0|0x1002:0x038000
AMD 3D controller without amdgpu loaded|0|0|0x1002:0x030200
Intel primary with AMD offload GPU|0|0|0x8086:0x030000 0x1002:0x030200
NVIDIA primary with AMD Display controller|0|0|0x10de:0x030000 0x1002:0x038000
AMD GPU with amdgpu loaded|0|1|0x1002:0x030000
AMD audio and host bridge are not GPUs|1|0|0x1002:0x040300 0x1022:0x060000
AMD CPU vendor does not match Radeon vendor|1|0|0x1022:0x038000
Intel and NVIDIA GPUs alone do not match|1|0|0x8086:0x030000 0x10de:0x030200
Loaded amdgpu without AMD hardware does not match|1|1|0x8086:0x030000
Empty PCI bus does not match|1|0|
CASES

reset_fixture
rm -rf "$OMARCHY_PCI_DEVICES_PATH"
status=0
omarchy-hw-amd-gpu 2>"$tmp_dir/errors" || status=$?
[[ $status == "1" && ! -s $tmp_dir/errors ]] || fail "missing PCI bus is a silent non-match"
pass "missing PCI bus is a silent non-match"

reset_fixture
add_device 0 0x1002 0x038000
rm "$OMARCHY_PCI_DEVICES_PATH/0/class"
add_device 1 0x1002 0x038000
rm "$OMARCHY_PCI_DEVICES_PATH/1/vendor"
add_device 2 0x1002 0x038000
omarchy-hw-amd-gpu 2>"$tmp_dir/errors" || fail "incomplete PCI entries do not hide a later GPU"
[[ ! -s $tmp_dir/errors ]] || fail "incomplete PCI entries are skipped silently"
pass "incomplete PCI entries do not hide a later GPU"

leaf="$ROOT/install/hardware/amd/rocm-smi.sh"
migration="$ROOT/migrations/1786874984.sh"

reset_fixture
add_device 0 0x1002 0x038000
bash -euo pipefail -c 'source "$1"; echo continued >>"$TEST_LOG"' _ "$leaf"
[[ $(cat "$TEST_INSTALLED") == "rocm-smi-lib" && $(cat "$TEST_LOG") == $'install\ncontinued' ]] ||
  fail "fresh hardware setup installs only rocm-smi-lib and remains sourceable"
pass "fresh hardware setup installs only rocm-smi-lib and remains sourceable"

reset_fixture
add_device 0 0x1002 0x038000
bash -euo pipefail "$migration" >/dev/null
bash -euo pipefail "$migration" >/dev/null
[[ $(cat "$TEST_INSTALLED") == "rocm-smi-lib" && $(cat "$TEST_LOG") == "install" ]] ||
  fail "migration installs once across repeated runs"
pass "migration installs once across repeated runs"

reset_fixture
add_device 0 0x1002 0x040300
add_device 1 0x8086 0x030000
bash -euo pipefail "$leaf"
bash -euo pipefail "$migration" >/dev/null
[[ ! -s $TEST_INSTALLED && ! -s $TEST_LOG ]] || fail "non-AMD-GPU systems skip setup and migration"
pass "non-AMD-GPU systems skip setup and migration"

for mode in failure unregistered; do
  for script in "$leaf" "$migration"; do
    reset_fixture
    add_device 0 0x1002 0x038000
    export TEST_INSTALL_MODE="$mode"
    status=0
    bash -euo pipefail "$script" >"$tmp_dir/output" 2>"$tmp_dir/errors" || status=$?
    (( status != 0 )) || fail "${script##*/} propagates $mode installation failure"
    [[ ! -s $TEST_INSTALLED ]] || fail "failed installation is not recorded as installed"
    pass "${script##*/} propagates $mode installation failure"
  done
done

reset_fixture
add_device 0 0x1002 0x038000
export TEST_INSTALL_MODE=failure
if bash -euo pipefail "$migration" >"$tmp_dir/output" 2>"$tmp_dir/errors"; then
  fail "migration fails before a retry"
fi
export TEST_INSTALL_MODE=success
bash -euo pipefail "$migration" >/dev/null
[[ $(cat "$TEST_INSTALLED") == "rocm-smi-lib" && $(cat "$TEST_LOG") == $'install\ninstall' ]] ||
  fail "migration can retry an unsuccessful installation"
pass "migration can retry an unsuccessful installation"

grep -Fxq 'run_logged "$OMARCHY_INSTALL/hardware/amd/rocm-smi.sh"' "$ROOT/install/hardware/all.sh" ||
  fail "hardware orchestration includes the AMD setup leaf"
grep -Fxq 'rocm-smi-lib' "$ROOT/install/omarchy-other.packages" ||
  fail "offline package cache includes rocm-smi-lib"
pass "hardware setup and offline cache include ROCm SMI"

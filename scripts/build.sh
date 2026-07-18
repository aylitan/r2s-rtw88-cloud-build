#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

RECIPE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
RUN_ROOT="${RUNNER_TEMP:-/tmp}/r2s-rtw88-build"
SRC="$RUN_ROOT/istoreos"
META="$RUN_ROOT/metadata"
OUT="$RECIPE_ROOT/out"
LOGS="$OUT/logs"
ARTIFACT="$OUT/artifact"

ISTOREOS_COMMIT="72437fb255349cb13e524298b1b6040f83a00562"
ISTOREOS_SHORT="72437fb2"
EXPECTED_KERNEL_VERSION="6.6.141~77d4782035a23e6f19f9c4751451b4e3-r1"
EXPECTED_KMOD_VERSION="6.6.141.6.12.61-r2"
EXPECTED_ARCH="aarch64_generic"
EXPECTED_VERMAGIC="6.6.141 SMP mod_unload aarch64"
PATCH_SOURCE="$RECIPE_ROOT/patches/999-rtw88-fix-random-error-beacon-valid-usb.patch"

mkdir -p "$RUN_ROOT" "$META" "$LOGS" "$ARTIFACT"
rm -rf "$SRC" "$ARTIFACT"/*

finish() {
  local rc=$?
  {
    echo "EXIT_CODE=$rc"
    echo "DATE=$(date -u +%FT%TZ)"
    echo "DISK_FINAL_BEGIN"
    df -h
    echo "DISK_FINAL_END"
  } > "$LOGS/final-state.txt" 2>&1 || true

  if [ -d "$SRC" ]; then
    cp -f "$SRC/.config" "$LOGS/final.config" 2>/dev/null || true
    git -C "$SRC" status --short > "$LOGS/source-status.txt" 2>/dev/null || true
  fi
}
trap finish EXIT

log_run() {
  local name="$1"
  shift
  echo "========== $name BEGIN ==========" | tee "$LOGS/$name.log"
  set +e
  "$@" 2>&1 | tee -a "$LOGS/$name.log"
  local rc=${PIPESTATUS[0]}
  set -e
  echo "========== $name END RC=$rc ==========" | tee -a "$LOGS/$name.log"
  return "$rc"
}

fail() {
  echo "RESULT=$1" | tee -a "$LOGS/result.txt"
  exit "${2:-30}"
}

extract_ipk_member() {
  local ipk="$1"
  local prefix="$2"
  local destination="$3"
  local member=""

  member="$(ar t "$ipk" | awk -v p="$prefix" 'index($0,p)==1 {print; exit}')"
  [ -n "$member" ] || return 1

  mkdir -p "$destination"
  ar p "$ipk" "$member" > "$RUN_ROOT/$member"

  case "$member" in
    *.tar.gz)  tar -xzf "$RUN_ROOT/$member" -C "$destination" ;;
    *.tar.xz)  tar -xJf "$RUN_ROOT/$member" -C "$destination" ;;
    *.tar.zst) tar --zstd -xf "$RUN_ROOT/$member" -C "$destination" ;;
    *.tar)     tar -xf "$RUN_ROOT/$member" -C "$destination" ;;
    *) return 1 ;;
  esac
}

validate_control() {
  local pkg="$1"
  local ipk="$2"
  local control_dir="$RUN_ROOT/control-$pkg"
  rm -rf "$control_dir"
  extract_ipk_member "$ipk" control.tar "$control_dir" || fail "BAD_CONTROL_ARCHIVE_$pkg" 70

  local control_file="$control_dir/control"
  [ -f "$control_file" ] || control_file="$control_dir/./control"
  [ -f "$control_file" ] || fail "BAD_CONTROL_FILE_$pkg" 71

  cat "$control_file" | tee "$ARTIFACT/${pkg}.control"

  local actual_pkg actual_version actual_arch depends compact_dep
  actual_pkg="$(sed -n 's/^Package: //p' "$control_file" | head -n1)"
  actual_version="$(sed -n 's/^Version: //p' "$control_file" | head -n1)"
  actual_arch="$(sed -n 's/^Architecture: //p' "$control_file" | head -n1)"
  depends="$(sed -n 's/^Depends: //p' "$control_file" | head -n1)"
  compact_dep="$(printf '%s' "$depends" | tr -d '[:space:]')"

  [ "$actual_pkg" = "$pkg" ] || fail "BAD_PACKAGE_NAME_$pkg" 72
  [ "$actual_version" = "$EXPECTED_KMOD_VERSION" ] || fail "BAD_PACKAGE_VERSION_$pkg" 73
  [ "$actual_arch" = "$EXPECTED_ARCH" ] || fail "BAD_PACKAGE_ARCH_$pkg" 74

  case "$compact_dep" in
    *"kernel(=$EXPECTED_KERNEL_VERSION)"*) ;;
    *)
      echo "DEPENDS=$depends"
      fail "BAD_KERNEL_ABI_DEPENDENCY_$pkg" 75
      ;;
  esac
}

validate_module() {
  local expected_name="$1"
  local module_file="$2"
  [ -f "$module_file" ] || fail "BAD_MODULE_NOT_FOUND_$expected_name" 80

  local vermagic name depends
  vermagic="$(modinfo -F vermagic "$module_file" 2>/dev/null | head -n1)"
  name="$(modinfo -F name "$module_file" 2>/dev/null | head -n1)"
  depends="$(modinfo -F depends "$module_file" 2>/dev/null | head -n1)"

  echo "MODULE=$module_file" | tee -a "$ARTIFACT/modules.txt"
  echo "NAME=$name" | tee -a "$ARTIFACT/modules.txt"
  echo "VERMAGIC=$vermagic" | tee -a "$ARTIFACT/modules.txt"
  echo "DEPENDS=$depends" | tee -a "$ARTIFACT/modules.txt"
  sha256sum "$module_file" | tee -a "$ARTIFACT/modules.txt"
  echo | tee -a "$ARTIFACT/modules.txt"

  [ "$name" = "$expected_name" ] || fail "BAD_MODULE_NAME_$expected_name" 81
  [ "$vermagic" = "$EXPECTED_VERMAGIC" ] || fail "BAD_MODULE_VERMAGIC_$expected_name" 82
}

# BEGIN OPENWRT TAR IPK COMPAT READER
#
# OpenWrt 24.10 ipkg-build creates a gzip-compressed tar archive
# containing debian-binary, control.tar.gz and data.tar.gz.
# The helper also retains compatibility with traditional ar IPKs.

REAL_AR_BIN="$(command -v ar)"

[ -n "$REAL_AR_BIN" ] || {
    echo "RESULT=BAD_REAL_AR_BINARY_NOT_FOUND"
    exit 60
}

ar() {
    local mode="${1:-}"
    local archive="${2:-}"
    local member="${3:-}"
    local clean_member=""
    local output_member=""

    if [ -n "$archive" ] &&
       [ -f "$archive" ] &&
       gzip -t "$archive" >/dev/null 2>&1 &&
       tar -tzf "$archive" >/dev/null 2>&1
    then
        case "$mode" in
            t|-t)
                tar -tzf "$archive" |
                sed 's#^\./##'
                return
                ;;

            p|-p)
                [ -n "$member" ] || return 2

                clean_member="${member#./}"

                if tar -xOzf "$archive" "./${clean_member}" 2>/dev/null; then
                    return 0
                fi

                tar -xOzf "$archive" "$clean_member"
                return
                ;;

            x|-x)
                shift 2

                if [ "$#" -eq 0 ]; then
                    tar -xzf "$archive"
                    return
                fi

                for member in "$@"; do
                    clean_member="${member#./}"
                    output_member="${clean_member##*/}"

                    if tar -xOzf "$archive" "./${clean_member}" \
                        > "$output_member" 2>/dev/null
                    then
                        :
                    else
                        tar -xOzf "$archive" "$clean_member" \
                            > "$output_member"
                    fi
                done

                return
                ;;
        esac
    fi

    "$REAL_AR_BIN" "$@"
}

echo "===== IPK reader early self-test ====="

IPK_TEST_DIR="$(mktemp -d)"

(
    set -Eeuo pipefail

    mkdir -p "$IPK_TEST_DIR/control"
    mkdir -p "$IPK_TEST_DIR/data/lib/modules"

    cat > "$IPK_TEST_DIR/control/control" <<'EOF_TEST_CONTROL'
Package: ipk-reader-selftest
Version: 1
Architecture: aarch64_generic
Description: OpenWrt tar IPK reader self-test
EOF_TEST_CONTROL

    printf 'test-module\n' \
        > "$IPK_TEST_DIR/data/lib/modules/test.ko"

    (
        cd "$IPK_TEST_DIR/control"
        tar -czf "$IPK_TEST_DIR/control.tar.gz" ./control
    )

    (
        cd "$IPK_TEST_DIR/data"
        tar -czf "$IPK_TEST_DIR/data.tar.gz" ./lib
    )

    printf '2.0\n' > "$IPK_TEST_DIR/debian-binary"

    (
        cd "$IPK_TEST_DIR"
        tar -czf sample.ipk \
            ./debian-binary \
            ./data.tar.gz \
            ./control.tar.gz
    )

    ar t "$IPK_TEST_DIR/sample.ipk" |
        grep -qx 'control.tar.gz'

    ar t "$IPK_TEST_DIR/sample.ipk" |
        grep -qx 'data.tar.gz'

    ar p "$IPK_TEST_DIR/sample.ipk" control.tar.gz |
        tar -xzOf - ./control |
        grep -qx 'Package: ipk-reader-selftest'

    ar p "$IPK_TEST_DIR/sample.ipk" data.tar.gz |
        tar -xzOf - ./lib/modules/test.ko |
        grep -qx 'test-module'
) || {
    rm -rf "$IPK_TEST_DIR"
    echo "RESULT=BAD_OPENWRT_IPK_READER_SELFTEST"
    exit 61
}

rm -rf "$IPK_TEST_DIR"

echo "IPK_OUTER_FORMAT_SUPPORTED=TAR_GZIP"
echo "IPK_LEGACY_AR_SUPPORTED=YES"
echo "IPK_READER_SELFTEST=OK"
# END OPENWRT TAR IPK COMPAT READER

echo "========== R2S_RTW88_CLOUD_BUILD_BEGIN ==========" | tee "$LOGS/result.txt"
date -u | tee -a "$LOGS/result.txt"
echo "ISTOREOS_COMMIT=$ISTOREOS_COMMIT" | tee -a "$LOGS/result.txt"
echo "EXPECTED_KERNEL_VERSION=$EXPECTED_KERNEL_VERSION" | tee -a "$LOGS/result.txt"
echo "EXPECTED_KMOD_VERSION=$EXPECTED_KMOD_VERSION" | tee -a "$LOGS/result.txt"

echo "===== 1. Clone exact iStoreOS source =====" | tee -a "$LOGS/result.txt"
git init -q "$SRC"
git -C "$SRC" remote add origin https://github.com/istoreos/istoreos.git
log_run clone-source git -C "$SRC" fetch --depth=1 origin "$ISTOREOS_COMMIT"
git -C "$SRC" checkout -q --detach FETCH_HEAD
ACTUAL_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
[ "$ACTUAL_COMMIT" = "$ISTOREOS_COMMIT" ] || fail BAD_ISTOREOS_COMMIT 20

echo "===== 2. Fetch exact release build configuration =====" | tee -a "$LOGS/result.txt"
CHOSEN_BASE=""
for base in \
  "https://fw.koolcenter.com/iStoreOS/r2s" \
  "https://fw.koolcenter.com/iStoreOS/easepi-r2" \
  "https://fw.koolcenter.com/iStoreOS/h28k"
do
  rm -f "$META/config.buildinfo" "$META/commit.buildinfo"
  if curl -4 -fsSL --retry 3 --connect-timeout 20 --max-time 120 \
       -o "$META/config.buildinfo" "$base/config.buildinfo" && \
     curl -4 -fsSL --retry 3 --connect-timeout 20 --max-time 120 \
       -o "$META/commit.buildinfo" "$base/commit.buildinfo"; then
    short="$(tr -d '\r\n[:space:]' < "$META/commit.buildinfo")"
    if grep -q '^CONFIG_TARGET_rockchip=y' "$META/config.buildinfo" && \
       grep -q '^CONFIG_TARGET_rockchip_armv8=y' "$META/config.buildinfo" && \
       [[ "$ISTOREOS_COMMIT" == "$short"* ]]; then
      CHOSEN_BASE="$base"
      break
    fi
  fi
done

[ -n "$CHOSEN_BASE" ] || fail BAD_RELEASE_BUILDINFO_NOT_FOUND 21
cp "$META/config.buildinfo" "$LOGS/config.buildinfo.original"
cp "$META/commit.buildinfo" "$LOGS/commit.buildinfo"
echo "CHOSEN_BUILDINFO_BASE=$CHOSEN_BASE" | tee -a "$LOGS/result.txt"
echo "BUILDINFO_COMMIT=$(cat "$META/commit.buildinfo")" | tee -a "$LOGS/result.txt"

echo "===== 3. Configure exact target and required modules =====" | tee -a "$LOGS/result.txt"
cp "$META/config.buildinfo" "$SRC/.config"
cd "$SRC"

for symbol in \
  CONFIG_PACKAGE_kmod-rtw88 \
  CONFIG_PACKAGE_kmod-rtw88-usb \
  CONFIG_PACKAGE_kmod-rtw88-8822b \
  CONFIG_PACKAGE_kmod-rtw88-8822bu
do
  sed -i \
    -e "/^${symbol}=/d" \
    -e "/^# ${symbol} is not set$/d" \
    .config

  printf "%s\n" "${symbol}=y" >> .config
done

log_run make-defconfig make defconfig

grep -E '^CONFIG_TARGET_rockchip(_armv8)?=y$' .config | tee "$LOGS/target-config.txt"
grep -E '^CONFIG_PACKAGE_kmod-rtw88(-usb|-8822b|-8822bu)?=y$' .config | tee "$LOGS/rtw88-config.txt"

for symbol in \
  CONFIG_TARGET_rockchip=y \
  CONFIG_TARGET_rockchip_armv8=y \
  CONFIG_PACKAGE_kmod-rtw88=y \
  CONFIG_PACKAGE_kmod-rtw88-usb=y \
  CONFIG_PACKAGE_kmod-rtw88-8822b=y \
  CONFIG_PACKAGE_kmod-rtw88-8822bu=y
do
  grep -qx "$symbol" .config || fail "BAD_CONFIG_${symbol%%=*}" 22
done

echo "===== 4. Inject verified upstream patch =====" | tee -a "$LOGS/result.txt"
PATCH_DIR="$SRC/package/kernel/mac80211/patches/rtl"
[ -d "$PATCH_DIR" ] || fail BAD_MAC80211_RTL_PATCH_DIR 23
cp "$PATCH_SOURCE" "$PATCH_DIR/999-rtw88-fix-random-error-beacon-valid-usb.patch"

BACKPORT_SOURCE="$RUN_ROOT/backports-6.12.61.tar.xz"
curl -4 -fsSL --retry 3 --connect-timeout 20 --max-time 300 \
  -o "$BACKPORT_SOURCE" \
  https://downloads.openwrt.org/sources/backports-6.12.61.tar.xz

echo "9db2f836dba7f38ad68f8798720ad4360bce6a3557bde02b88b3a4f068c77118  $BACKPORT_SOURCE" | sha256sum -c -
mkdir -p "$RUN_ROOT/patch-check"
tar -xJf "$BACKPORT_SOURCE" -C "$RUN_ROOT/patch-check"
BACKPORT_ROOT="$RUN_ROOT/patch-check/backports-6.12.61"
(
  cd "$BACKPORT_ROOT"
  patch --dry-run --batch --forward -p1 < "$PATCH_SOURCE"
) | tee "$LOGS/patch-dry-run.txt"

echo "===== 5. Build toolchain, kernel and mac80211 =====" | tee -a "$LOGS/result.txt"
export FORCE_UNSAFE_CONFIGURE=1
JOBS="$(nproc)"
[ "$JOBS" -le 4 ] || JOBS=4

echo "BUILD_JOBS=$JOBS" | tee -a "$LOGS/result.txt"
log_run tools-install make -j"$JOBS" tools/install
log_run toolchain-install make -j"$JOBS" toolchain/install
log_run target-linux-compile make -j"$JOBS" target/linux/compile V=s
log_run mac80211-compile make -j"$JOBS" package/kernel/mac80211/compile V=s

echo "===== 6. Verify patch was applied to prepared build source =====" | tee -a "$LOGS/result.txt"
BUILT_FW="$(find "$SRC/build_dir" -path '*/backports-6.12.61/drivers/net/wireless/realtek/rtw88/fw.c' -type f | head -n1)"
[ -n "$BUILT_FW" ] || fail BAD_PREPARED_RTW88_SOURCE_NOT_FOUND 50
for marker in \
  'u8 bckp[3];' \
  'bckp[2] = rtw_read8(rtwdev, REG_BCN_CTRL);' \
  '(bckp[2] & ~BIT_EN_BCN_FUNCTION) | BIT_DIS_TSF_UDT' \
  'rtw_write8(rtwdev, REG_BCN_CTRL, bckp[2]);'
do
  grep -Fq "$marker" "$BUILT_FW" || fail BAD_PATCH_MARKER_MISSING 51
done
sed -n '/int rtw_fw_write_data_rsvd_page/,/return ret;/p' "$BUILT_FW" > "$ARTIFACT/patched-fw-function.txt"

# BEGIN RAW RTW88 IPK COLLECTION
#
# Preserve generated packages before strict validation.
# The workflow uploads this directory even when validation fails.

RAW_IPK_DIR="${GITHUB_WORKSPACE:-$PWD}/out/raw-ipks"
RTW88_PACKAGE_DIR="$SRC/bin/targets/rockchip/armv8/packages"

mkdir -p "$RAW_IPK_DIR"
rm -f "$RAW_IPK_DIR"/*.ipk

for package in \
    kmod-rtw88 \
    kmod-rtw88-usb \
    kmod-rtw88-8822b \
    kmod-rtw88-8822bu
do
    package_file="$(
        find "$RTW88_PACKAGE_DIR" \
            -maxdepth 1 \
            -type f \
            -name "${package}_*.ipk" \
            -print |
        head -n 1
    )"

    if [ -n "$package_file" ]; then
        cp -f "$package_file" "$RAW_IPK_DIR/"
        echo "RAW_IPK_SAVED=$(basename "$package_file")"
    else
        echo "RAW_IPK_MISSING=$package"
    fi
done

RAW_IPK_COUNT="$(
    find "$RAW_IPK_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.ipk' |
    wc -l |
    tr -d ' '
)"

echo "RAW_IPK_DIR=$RAW_IPK_DIR"
echo "RAW_IPK_COUNT=$RAW_IPK_COUNT"
# END RAW RTW88 IPK COLLECTION

echo "===== 7. Collect and validate four exact-ABI IPKs =====" | tee -a "$LOGS/result.txt"
PACKAGES=(kmod-rtw88 kmod-rtw88-usb kmod-rtw88-8822b kmod-rtw88-8822bu)
: > "$ARTIFACT/ipk-sha256sums.txt"
: > "$ARTIFACT/modules.txt"
mkdir -p "$ARTIFACT/ipk" "$ARTIFACT/modules"

for pkg in "${PACKAGES[@]}"; do
  ipk="$(find "$SRC/bin" -type f -name "${pkg}_*.ipk" | head -n1)"
  [ -n "$ipk" ] || fail "BAD_IPK_NOT_FOUND_$pkg" 60
  validate_control "$pkg" "$ipk"
  cp "$ipk" "$ARTIFACT/ipk/"
  sha256sum "$ipk" | sed "s#  .*#  ipk/$(basename "$ipk")#" | tee -a "$ARTIFACT/ipk-sha256sums.txt"

  data_dir="$RUN_ROOT/data-$pkg"
  rm -rf "$data_dir"
  extract_ipk_member "$ipk" data.tar "$data_dir" || fail "BAD_DATA_ARCHIVE_$pkg" 61
  find "$data_dir" -type f -name '*.ko' -exec cp -f {} "$ARTIFACT/modules/" \;
done

validate_module rtw88_core "$ARTIFACT/modules/rtw88_core.ko"
validate_module rtw88_usb "$ARTIFACT/modules/rtw88_usb.ko"
validate_module rtw88_8822b "$ARTIFACT/modules/rtw88_8822b.ko"
validate_module rtw88_8822bu "$ARTIFACT/modules/rtw88_8822bu.ko"

sha256sum "$ARTIFACT/modules/"*.ko > "$ARTIFACT/module-sha256sums.txt"

cat > "$ARTIFACT/BUILD-RESULT.txt" <<EOF_RESULT
RESULT=OK_R2S_RTW88_PATCHED_EXACT_ABI_BUILD
ISTOREOS_COMMIT=$ISTOREOS_COMMIT
BUILDINFO_BASE=$CHOSEN_BASE
KERNEL_DEPENDENCY=$EXPECTED_KERNEL_VERSION
KMOD_VERSION=$EXPECTED_KMOD_VERSION
ARCHITECTURE=$EXPECTED_ARCH
VERMAGIC=$EXPECTED_VERMAGIC
PATCH_COMMIT=f24d0d8c3cd7
PACKAGES=kmod-rtw88 kmod-rtw88-usb kmod-rtw88-8822b kmod-rtw88-8822bu
INSTALL_PERFORMED=NO
R2S_CHANGED=NO
EOF_RESULT

cat > "$ARTIFACT/INSTALL-ORDER.txt" <<'EOF_ORDER'
1. kmod-rtw88
2. kmod-rtw88-usb
3. kmod-rtw88-8822b
4. kmod-rtw88-8822bu

Do not install until the separate R2S backup, validation and auto-rollback script is prepared.
EOF_ORDER

cp "$PATCH_SOURCE" "$ARTIFACT/"
cp "$LOGS/config.buildinfo.original" "$ARTIFACT/"
cp "$LOGS/commit.buildinfo" "$ARTIFACT/"

find "$ARTIFACT" -maxdepth 3 -type f -printf '%P\n' | sort | tee "$ARTIFACT/FILES.txt"
echo "RESULT=OK_R2S_RTW88_PATCHED_EXACT_ABI_BUILD" | tee -a "$LOGS/result.txt"
echo "========== R2S_RTW88_CLOUD_BUILD_END ==========" | tee -a "$LOGS/result.txt"

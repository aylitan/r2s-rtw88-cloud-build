#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

ROOT="$GITHUB_WORKSPACE"
OUT="$ROOT/out"
ARTIFACT="$OUT/artifact"
RAW="$OUT/raw-ipks"
LOGS="$OUT/logs"
RUN="${RUNNER_TEMP:-/tmp}/r2s-rtw88-sdk"
SDK="$RUN/sdk"
OPENWRT_SOURCE="$RUN/openwrt-v24.10.7"
ARCHIVE="$RUN/openwrt-sdk.tar.zst"

SDK_URL="https://downloads.openwrt.org/releases/24.10.7/targets/rockchip/armv8/openwrt-sdk-24.10.7-rockchip-armv8_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
SDK_SHA256="1e07c546669b4792c846e7a775156bb1e6d9d727efbc6d5999a02c96c5ab8ea9"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"
OPENWRT_TAG="v24.10.7"
EXPECTED_KERNEL="6.6.141~77d4782035a23e6f19f9c4751451b4e3-r1"
EXPECTED_MAC80211_VERSION="6.12.61"
EXPECTED_SOURCE_MAC80211_RELEASE="1"
TARGET_MAC80211_RELEASE="2"
EXPECTED_PACKAGE_VERSION="6.6.141.6.12.61-r2"
PATCH="$ROOT/patches/999-rtw88-fix-random-error-beacon-valid-usb.patch"

rm -rf "$OUT" "$RUN"
mkdir -p "$ARTIFACT/ipk" "$RAW" "$LOGS" "$SDK"
exec > >(tee "$LOGS/build-full.log") 2>&1

fail() {
    echo "RESULT=$1" | tee "$LOGS/result.txt"
    exit "${2:-30}"
}

set_config_value() {
    local symbol="$1"
    local value="$2"
    sed -i \
        -e "/^${symbol}=/d" \
        -e "/^# ${symbol} is not set$/d" \
        .config

    case "$value" in
        n) echo "# ${symbol} is not set" >> .config ;;
        y|m) echo "${symbol}=${value}" >> .config ;;
        *) echo "${symbol}=${value}" >> .config ;;
    esac
}

read_control() {
    local ipk="$1"
    local member tmp tmpdir rc

    # OpenWrt 24.10 SDK creates .ipk files as gzip-compressed tar archives.
    # Keep an ar fallback for older/other opkg package formats.
    tmpdir="$(mktemp -d)"
    rc=1

    if tar -xzf "$ipk" -C "$tmpdir" >/dev/null 2>&1; then
        member="$(find "$tmpdir" -maxdepth 1 -type f -name 'control.tar*' -print | head -n 1)"
        if [ -n "$member" ]; then
            if tar -xOf "$member" ./control 2>/dev/null ||
               tar -xOf "$member" control 2>/dev/null; then
                rc=0
            fi
        fi
        rm -rf "$tmpdir"
        return "$rc"
    fi

    rm -rf "$tmpdir"
    member="$(ar t "$ipk" 2>/dev/null | grep '^control.tar' | head -n 1 || true)"
    [ -n "$member" ] || return 1

    tmp="$(mktemp)"
    if ! ar p "$ipk" "$member" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi

    rc=1
    if tar -xOf "$tmp" ./control 2>/dev/null ||
       tar -xOf "$tmp" control 2>/dev/null; then
        rc=0
    fi
    rm -f "$tmp"
    return "$rc"
}

extract_ipk_data() {
    local ipk="$1"
    local destination="$2"
    local member tmp tmpdir

    mkdir -p "$destination"

    tmpdir="$(mktemp -d)"
    if tar -xzf "$ipk" -C "$tmpdir" >/dev/null 2>&1; then
        member="$(find "$tmpdir" -maxdepth 1 -type f -name 'data.tar*' -print | head -n 1)"
        if [ -n "$member" ] && tar -xf "$member" -C "$destination"; then
            rm -rf "$tmpdir"
            return 0
        fi
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    member="$(ar t "$ipk" 2>/dev/null | grep '^data.tar' | head -n 1 || true)"
    [ -n "$member" ] || return 1

    tmp="$(mktemp)"
    if ! ar p "$ipk" "$member" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi

    if tar -xf "$tmp" -C "$destination"; then
        rm -f "$tmp"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

echo "========== R2S_RTW88_FINAL_EXACT_ABI_BUILD_BEGIN =========="
date
echo "SDK_URL=$SDK_URL"
echo "OPENWRT_TAG=$OPENWRT_TAG"
echo "EXPECTED_KERNEL=$EXPECTED_KERNEL"

[ -s "$PATCH" ] || fail BAD_PATCH_NOT_FOUND 20

curl -L --fail --retry 8 --retry-delay 3 \
    -o "$ARCHIVE" "$SDK_URL" ||
    fail BAD_SDK_DOWNLOAD 21

echo "$SDK_SHA256  $ARCHIVE" | sha256sum -c - ||
    fail BAD_SDK_SHA256 22

tar --zstd -xf "$ARCHIVE" -C "$SDK" --strip-components=1 ||
    fail BAD_SDK_EXTRACT 23

echo
echo "===== Fetch exact official mac80211 source ====="

git clone \
    --depth 1 \
    --filter=blob:none \
    --sparse \
    --branch "$OPENWRT_TAG" \
    "$OPENWRT_REPO" \
    "$OPENWRT_SOURCE" ||
    fail BAD_OPENWRT_SPARSE_CLONE 24

git -C "$OPENWRT_SOURCE" sparse-checkout set \
    package/kernel/mac80211 ||
    fail BAD_MAC80211_SPARSE_CHECKOUT 25

SOURCE_MAC80211="$OPENWRT_SOURCE/package/kernel/mac80211"
SDK_MAC80211="$SDK/package/kernel/mac80211"

[ -f "$SOURCE_MAC80211/Makefile" ] ||
    fail BAD_OPENWRT_MAC80211_SOURCE 26

rm -rf "$SDK_MAC80211"
mkdir -p "$SDK/package/kernel"
cp -a "$SOURCE_MAC80211" "$SDK_MAC80211" ||
    fail BAD_MAC80211_COPY_TO_SDK 27

[ -d "$SDK_MAC80211/patches/rtl" ] ||
    fail BAD_SDK_MAC80211_RTL_PATCH_PATH 28

MAC80211_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$SDK_MAC80211/Makefile" | head -n 1)"
MAC80211_SOURCE_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$SDK_MAC80211/Makefile" | head -n 1)"
SOURCE_COMMIT="$(git -C "$OPENWRT_SOURCE" rev-parse HEAD)"
SOURCE_TAG_COMMIT="$(git -C "$OPENWRT_SOURCE" rev-list -n 1 "$OPENWRT_TAG")"

[ "$SOURCE_COMMIT" = "$SOURCE_TAG_COMMIT" ] ||
    fail BAD_OPENWRT_TAG_COMMIT_MISMATCH 29

[ "$MAC80211_VERSION" = "$EXPECTED_MAC80211_VERSION" ] ||
    fail "BAD_MAC80211_VERSION_${MAC80211_VERSION:-EMPTY}" 30

[ "$MAC80211_SOURCE_RELEASE" = "$EXPECTED_SOURCE_MAC80211_RELEASE" ] ||
    fail "BAD_SOURCE_MAC80211_RELEASE_${MAC80211_SOURCE_RELEASE:-EMPTY}" 31

RELEASE_LINE_COUNT="$(grep -c '^PKG_RELEASE:=1$' "$SDK_MAC80211/Makefile" || true)"
[ "$RELEASE_LINE_COUNT" = "1" ] ||
    fail "BAD_SOURCE_RELEASE_LINE_COUNT_$RELEASE_LINE_COUNT" 32

sed -i 's/^PKG_RELEASE:=1$/PKG_RELEASE:=2/' "$SDK_MAC80211/Makefile" ||
    fail BAD_MAC80211_RELEASE_REWRITE 33

MAC80211_TARGET_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$SDK_MAC80211/Makefile" | head -n 1)"
[ "$MAC80211_TARGET_RELEASE" = "$TARGET_MAC80211_RELEASE" ] ||
    fail "BAD_TARGET_MAC80211_RELEASE_${MAC80211_TARGET_RELEASE:-EMPTY}" 34

cp "$PATCH" \
    "$SDK_MAC80211/patches/rtl/999-rtw88-fix-random-error-beacon-valid-usb.patch" ||
    fail BAD_PATCH_COPY 35

grep -Fq 'bckp[2] = rtw_read8(rtwdev, REG_BCN_CTRL);' "$PATCH" ||
    fail BAD_PATCH_BACKUP 36

grep -Fq '(bckp[2] & ~BIT_EN_BCN_FUNCTION) | BIT_DIS_TSF_UDT' "$PATCH" ||
    fail BAD_PATCH_DISABLE 37

grep -Fq 'rtw_write8(rtwdev, REG_BCN_CTRL, bckp[2]);' "$PATCH" ||
    fail BAD_PATCH_RESTORE 38

echo "OPENWRT_SOURCE_COMMIT=$SOURCE_COMMIT"
echo "MAC80211_VERSION=$MAC80211_VERSION"
echo "MAC80211_SOURCE_RELEASE=$MAC80211_SOURCE_RELEASE"
echo "MAC80211_TARGET_RELEASE=$MAC80211_TARGET_RELEASE"

cd "$SDK"

# Some official target SDK archives do not ship a pre-generated .config.
# Create it explicitly, seed the fixed SDK target, disable the three
# build-everything switches, and select only the four RTW88 packages.
: > .config

set_config_value CONFIG_TARGET_rockchip y
set_config_value CONFIG_TARGET_rockchip_armv8 y
set_config_value CONFIG_ALL n
set_config_value CONFIG_ALL_KMODS n
set_config_value CONFIG_ALL_NONSHARED n
set_config_value CONFIG_PACKAGE_kmod-ath10k-smallbuffers n
set_config_value CONFIG_PACKAGE_kmod-ath10k n

set_config_value CONFIG_USB_SUPPORT y
set_config_value CONFIG_DRIVER_11AC_SUPPORT y
set_config_value CONFIG_PACKAGE_kmod-cfg80211 m
set_config_value CONFIG_PACKAGE_kmod-mac80211 m
set_config_value CONFIG_PACKAGE_kmod-usb-core m
set_config_value CONFIG_PACKAGE_kmod-rtw88 m
set_config_value CONFIG_PACKAGE_kmod-rtw88-usb m
set_config_value CONFIG_PACKAGE_kmod-rtw88-8822b m
set_config_value CONFIG_PACKAGE_kmod-rtw88-8822bu m

make defconfig | tee "$LOGS/defconfig.log"
[ -s .config ] || fail BAD_SDK_CONFIG_GENERATION 39
cp .config "$LOGS/final.config"

for symbol in \
    CONFIG_PACKAGE_kmod-rtw88 \
    CONFIG_PACKAGE_kmod-rtw88-usb \
    CONFIG_PACKAGE_kmod-rtw88-8822b \
    CONFIG_PACKAGE_kmod-rtw88-8822bu
do
    grep -Eq "^${symbol}=(m|y)$" .config ||
        fail "BAD_CONFIG_$symbol" 40
done

if grep -Eq '^CONFIG_PACKAGE_kmod-ath10k-smallbuffers=(m|y)$' .config; then
    fail BAD_SMALLBUFFERS_VARIANT_STILL_ENABLED 41
fi

if grep -Eq '^CONFIG_ALL_KMODS=y$' .config; then
    fail BAD_ALL_KMODS_STILL_ENABLED 42
fi

grep -E '^CONFIG_TARGET_rockchip(_armv8)?=y$' .config |
    tee "$LOGS/target-config.txt"

grep -E '^CONFIG_(ALL_KMODS|ALL_NONSHARED|USB_SUPPORT|DRIVER_11AC_SUPPORT|PACKAGE_kmod-(cfg80211|mac80211|usb-core|ath10k-smallbuffers|rtw88|rtw88-usb|rtw88-8822b|rtw88-8822bu))' .config |
    tee "$LOGS/selected-config.txt" || true

JOBS="$(nproc)"
[ "$JOBS" -gt 4 ] && JOBS=4

echo
echo "===== Prepare mac80211 and verify patch before compile ====="

make package/kernel/mac80211/clean |
    tee "$LOGS/clean.log"

make -j1 package/kernel/mac80211/prepare V=s |
    tee "$LOGS/prepare.log"

mapfile -t PREPARED_FW_FILES < <(
    find build_dir \
        -type f \
        -path '*/backports-6.12.61/drivers/net/wireless/realtek/rtw88/fw.c' \
        -print |
    sort
)

[ "${#PREPARED_FW_FILES[@]}" -gt 0 ] ||
    fail BAD_PREPARED_RTW88_SOURCE_NOT_FOUND 43

PATCHED_FW=""
for candidate in "${PREPARED_FW_FILES[@]}"; do
    if grep -Fq 'bckp[2] = rtw_read8(rtwdev, REG_BCN_CTRL);' "$candidate" &&
       grep -Fq 'BIT_DIS_TSF_UDT' "$candidate" &&
       grep -Fq 'rtw_write8(rtwdev, REG_BCN_CTRL, bckp[2]);' "$candidate"; then
        PATCHED_FW="$candidate"
        break
    fi
done

[ -n "$PATCHED_FW" ] || fail BAD_PATCH_NOT_APPLIED_TO_PREPARED_SOURCE 44

echo "PATCHED_FW=$PATCHED_FW"
cp "$PATCHED_FW" "$LOGS/patched-fw.c"

echo
echo "===== Compile selected RTW88 packages only ====="

make -j"$JOBS" package/kernel/mac80211/compile V=s |
    tee "$LOGS/compile.log"

PACKAGES=(
    kmod-rtw88
    kmod-rtw88-usb
    kmod-rtw88-8822b
    kmod-rtw88-8822bu
)

mkdir -p "$LOGS/ipk-extracted"

for package in "${PACKAGES[@]}"; do
    mapfile -t files < <(
        find bin/targets/rockchip/armv8/packages \
            -maxdepth 1 \
            -type f \
            -name "${package}_${EXPECTED_PACKAGE_VERSION}_aarch64_generic.ipk" \
            -print |
        sort
    )

    [ "${#files[@]}" -eq 1 ] ||
        fail "BAD_IPK_COUNT_${package}_${#files[@]}" 50

    ipk="${files[0]}"
    control="$LOGS/${package}.control"
    extract_dir="$LOGS/ipk-extracted/$package"

    echo "IPK_FILE=$ipk"
    file "$ipk" || true
    sha256sum "$ipk" || true

    # Save every generated target package before metadata validation so that
    # a parser/checking error can never discard another successful build.
    cp "$ipk" "$RAW/" || fail "BAD_RAW_COPY_$package" 51

    read_control "$ipk" > "$control" ||
        fail "BAD_CONTROL_$package" 52

    cat "$control"

    grep -q "^Package: $package$" "$control" ||
        fail "BAD_PACKAGE_NAME_$package" 53

    grep -Fq "Version: $EXPECTED_PACKAGE_VERSION" "$control" ||
        fail "BAD_PACKAGE_VERSION_$package" 54

    grep -q '^Architecture: aarch64_generic$' "$control" ||
        fail "BAD_ARCH_$package" 55

    grep -Fq "kernel (= $EXPECTED_KERNEL)" "$control" ||
        grep -Fq "kernel (=$EXPECTED_KERNEL)" "$control" ||
        fail "BAD_KERNEL_ABI_$package" 56

    extract_ipk_data "$ipk" "$extract_dir" ||
        fail "BAD_DATA_EXTRACT_$package" 57

    module_count="$(find "$extract_dir" -type f -name 'rtw88*.ko' | wc -l | tr -d ' ')"
    [ "$module_count" -ge 1 ] ||
        fail "BAD_MODULE_COUNT_$package" 58

    cp "$ipk" "$ARTIFACT/ipk/"
done

COUNT="$(find "$ARTIFACT/ipk" -type f -name '*.ipk' | wc -l | tr -d ' ')"
[ "$COUNT" = 4 ] || fail BAD_FINAL_IPK_COUNT 59

sha256sum "$ARTIFACT"/ipk/*.ipk > "$ARTIFACT/SHA256SUMS"

cat > "$ARTIFACT/BUILD_INFO.txt" <<INFO_EOF
RESULT=OK_R2S_RTW88_PATCHED_EXACT_ABI_BUILD
SOURCE=official OpenWrt 24.10.7 rockchip/armv8 SDK plus official v24.10.7 mac80211 source
OPENWRT_SOURCE_COMMIT=$SOURCE_COMMIT
KERNEL_DEPENDENCY=$EXPECTED_KERNEL
MAC80211_BACKPORTS=$MAC80211_VERSION-r$MAC80211_TARGET_RELEASE
PATCH_COMMIT=f24d0d8c3cd7
PATCHED_FW=$PATCHED_FW
IPK_COUNT=$COUNT
INFO_EOF

cat > "$ARTIFACT/INSTALL_ORDER.txt" <<'ORDER_EOF'
1. kmod-rtw88
2. kmod-rtw88-usb
3. kmod-rtw88-8822b
4. kmod-rtw88-8822bu
Do not install before backing up the current IPKs and modules.
ORDER_EOF

echo "RESULT=OK_R2S_RTW88_PATCHED_EXACT_ABI_BUILD" |
    tee "$LOGS/result.txt"
echo "IPK_COUNT=$COUNT"
echo "ARTIFACT=$ARTIFACT"
echo "========== R2S_RTW88_FINAL_EXACT_ABI_BUILD_END =========="

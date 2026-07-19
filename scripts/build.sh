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
ARCHIVE="$RUN/openwrt-sdk.tar.zst"

SDK_URL="https://downloads.openwrt.org/releases/24.10.7/targets/rockchip/armv8/openwrt-sdk-24.10.7-rockchip-armv8_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
SDK_SHA256="1e07c546669b4792c846e7a775156bb1e6d9d727efbc6d5999a02c96c5ab8ea9"
EXPECTED_KERNEL="6.6.141~77d4782035a23e6f19f9c4751451b4e3-r1"
PATCH="$ROOT/patches/999-rtw88-fix-random-error-beacon-valid-usb.patch"

rm -rf "$OUT" "$RUN"
mkdir -p "$ARTIFACT/ipk" "$RAW" "$LOGS" "$SDK"
exec > >(tee "$LOGS/build-full.log") 2>&1

fail() {
    echo "RESULT=$1" | tee "$LOGS/result.txt"
    exit "${2:-30}"
}

read_control() {
    local ipk="$1"
    local member tmp
    member="$(ar t "$ipk" | grep '^control.tar' | head -n 1)"
    [ -n "$member" ] || return 1
    tmp="$(mktemp)"
    ar p "$ipk" "$member" > "$tmp"
    tar -xOf "$tmp" ./control 2>/dev/null || tar -xOf "$tmp" control
    rm -f "$tmp"
}

echo "========== R2S_RTW88_OFFICIAL_SDK_BUILD_BEGIN =========="
date
echo "SDK_URL=$SDK_URL"
echo "EXPECTED_KERNEL=$EXPECTED_KERNEL"

[ -s "$PATCH" ] || fail BAD_PATCH_NOT_FOUND 20

curl -L --fail --retry 5 --retry-delay 3 -o "$ARCHIVE" "$SDK_URL" || fail BAD_SDK_DOWNLOAD 21
echo "$SDK_SHA256  $ARCHIVE" | sha256sum -c - || fail BAD_SDK_SHA256 22

tar --zstd -xf "$ARCHIVE" -C "$SDK" --strip-components=1 || fail BAD_SDK_EXTRACT 23
[ -d "$SDK/package/kernel/mac80211/patches/rtl" ] || fail BAD_SDK_MAC80211_PATH 24

cp "$PATCH" "$SDK/package/kernel/mac80211/patches/rtl/999-rtw88-fix-random-error-beacon-valid-usb.patch"

grep -Fq 'bckp[2] = rtw_read8(rtwdev, REG_BCN_CTRL);' "$PATCH" || fail BAD_PATCH_BACKUP 25
grep -Fq '(bckp[2] & ~BIT_EN_BCN_FUNCTION) | BIT_DIS_TSF_UDT' "$PATCH" || fail BAD_PATCH_DISABLE 26
grep -Fq 'rtw_write8(rtwdev, REG_BCN_CTRL, bckp[2]);' "$PATCH" || fail BAD_PATCH_RESTORE 27

cd "$SDK"
cat >> .config <<'CONFIG_EOF'
CONFIG_PACKAGE_kmod-rtw88=m
CONFIG_PACKAGE_kmod-rtw88-usb=m
CONFIG_PACKAGE_kmod-rtw88-8822b=m
CONFIG_PACKAGE_kmod-rtw88-8822bu=m
CONFIG_EOF

make defconfig | tee "$LOGS/defconfig.log"

for symbol in \
    CONFIG_PACKAGE_kmod-rtw88 \
    CONFIG_PACKAGE_kmod-rtw88-usb \
    CONFIG_PACKAGE_kmod-rtw88-8822b \
    CONFIG_PACKAGE_kmod-rtw88-8822bu
do
    grep -q "^${symbol}=m$" .config || fail "BAD_CONFIG_$symbol" 28
done

grep -E '^CONFIG_TARGET_rockchip(_armv8)?=y$' .config | tee "$LOGS/target-config.txt"
grep -E '^CONFIG_PACKAGE_kmod-rtw88(-usb|-8822b|-8822bu)?=m$' .config | tee "$LOGS/rtw88-config.txt"

JOBS="$(nproc)"
[ "$JOBS" -gt 4 ] && JOBS=4

make package/kernel/mac80211/clean | tee "$LOGS/clean.log"
make -j"$JOBS" package/kernel/mac80211/compile V=s | tee "$LOGS/compile.log"

FW="$(find build_dir -path '*/backports-6.12.61/drivers/net/wireless/realtek/rtw88/fw.c' -type f | head -n 1)"
[ -n "$FW" ] || fail BAD_PATCHED_SOURCE_NOT_FOUND 40
grep -Fq 'bckp[2] = rtw_read8(rtwdev, REG_BCN_CTRL);' "$FW" || fail BAD_PATCH_NOT_APPLIED_BACKUP 41
grep -Fq 'BIT_DIS_TSF_UDT' "$FW" || fail BAD_PATCH_NOT_APPLIED_DISABLE 42
grep -Fq 'rtw_write8(rtwdev, REG_BCN_CTRL, bckp[2]);' "$FW" || fail BAD_PATCH_NOT_APPLIED_RESTORE 43

PACKAGES=(kmod-rtw88 kmod-rtw88-usb kmod-rtw88-8822b kmod-rtw88-8822bu)
for package in "${PACKAGES[@]}"
do
    mapfile -t files < <(find bin -type f -name "${package}_*.ipk" | sort)
    [ "${#files[@]}" -eq 1 ] || fail "BAD_IPK_COUNT_$package" 50
    ipk="${files[0]}"
    control="$LOGS/${package}.control"
    read_control "$ipk" > "$control" || fail "BAD_CONTROL_$package" 51
    cat "$control"
    grep -q "^Package: $package$" "$control" || fail "BAD_PACKAGE_NAME_$package" 52
    grep -q '^Architecture: aarch64_generic$' "$control" || fail "BAD_ARCH_$package" 53
    grep -Fq "kernel (= $EXPECTED_KERNEL)" "$control" || \
        grep -Fq "kernel (=$EXPECTED_KERNEL)" "$control" || \
        fail "BAD_KERNEL_ABI_$package" 54
    cp "$ipk" "$RAW/"
    cp "$ipk" "$ARTIFACT/ipk/"
done

COUNT="$(find "$ARTIFACT/ipk" -type f -name '*.ipk' | wc -l | tr -d ' ')"
[ "$COUNT" = 4 ] || fail BAD_FINAL_IPK_COUNT 55
sha256sum "$ARTIFACT"/ipk/*.ipk > "$ARTIFACT/SHA256SUMS"

cat > "$ARTIFACT/BUILD_INFO.txt" <<INFO_EOF
RESULT=OK_R2S_RTW88_PATCHED_EXACT_ABI_BUILD
SOURCE=official OpenWrt 24.10.7 rockchip/armv8 SDK
KERNEL_DEPENDENCY=$EXPECTED_KERNEL
MAC80211_BACKPORTS=6.12.61-r2
PATCH_COMMIT=f24d0d8c3cd7
IPK_COUNT=$COUNT
INFO_EOF

cat > "$ARTIFACT/INSTALL_ORDER.txt" <<'ORDER_EOF'
1. kmod-rtw88
2. kmod-rtw88-usb
3. kmod-rtw88-8822b
4. kmod-rtw88-8822bu
Do not install before backing up the existing modules.
ORDER_EOF

echo "RESULT=OK_R2S_RTW88_PATCHED_EXACT_ABI_BUILD" | tee "$LOGS/result.txt"
echo "IPK_COUNT=$COUNT"
echo "ARTIFACT=$ARTIFACT"
echo "========== R2S_RTW88_OFFICIAL_SDK_BUILD_END =========="

#!/bin/bash
SECONDS=0
set -e

# =========================
# Kernel build parameters
# =========================
android_version="$1"     # e.g. android14
kernel_version="$2"      # e.g. 6.6
sub_level="$3"           # e.g. 30 (fallback)
os_patch_level="$4"      # e.g. 2024-10

CONFIG="$android_version-$kernel_version-$sub_level"
export CONFIG

# =========================
# Paths
# =========================
ROOT="$(pwd)"
KERNEL_ROOT="$ROOT/$CONFIG"
KERNEL_PATCHES="$ROOT/kernel_patches"
ANYKERNEL3="$ROOT/AnyKernel3"
DEFCONFIG="$KERNEL_ROOT/common/arch/arm64/configs/gki_defconfig"
KERNEL_RESULT="$KERNEL_ROOT/bazel-bin/common/kernel_aarch64"

export ROOT KERNEL_ROOT KERNEL_PATCHES ANYKERNEL3

# =========================
# Build tools
# =========================
AOSP_MIRROR=https://android.googlesource.com
BRANCH=main-kernel-2025

git clone $AOSP_MIRROR/kernel/prebuilts/build-tools -b $BRANCH --depth 1 kernel-build-tools &
git clone $AOSP_MIRROR/platform/system/tools/mkbootimg -b $BRANCH --depth 1 mkbootimg &
wait

export AVBTOOL="$ROOT/kernel-build-tools/linux-x86/bin/avbtool"
export MKBOOTIMG="$ROOT/mkbootimg/mkbootimg.py"
export UNPACK_BOOTIMG="$ROOT/mkbootimg/unpack_bootimg.py"
export BOOT_SIGN_KEY_PATH="$ROOT/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"
export PATH="$ROOT/kernel-build-tools/linux-x86/bin:$PATH"

# =========================
# Repo tool
# =========================
mkdir -p git-repo
curl -s https://storage.googleapis.com/git-repo-downloads/repo > git-repo/repo
chmod +x git-repo/repo
export REPO="$ROOT/git-repo/repo"

# =========================
# Dependencies
# =========================
git clone https://github.com/kylieeXD/AK3-GKI "$ANYKERNEL3"
git clone https://github.com/kylieeXD/kernel_patches.git "$KERNEL_PATCHES"

# =========================
# Kernel source sync
# =========================
mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

FORMATTED_BRANCH="$android_version-$kernel_version-$os_patch_level"
$REPO init --depth=1 -u https://android.googlesource.com/kernel/manifest -b common-${FORMATTED_BRANCH} --repo-rev=v2.16

REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common ${FORMATTED_BRANCH})
DEFAULT_MANIFEST_PATH=.repo/manifests/default.xml
if grep -q deprecated <<< "$REMOTE_BRANCH"; then
  sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" "$DEFAULT_MANIFEST_PATH"
fi

$REPO sync -c -j$(nproc --all) --no-tags --fail-fast

# =========================
# Extract real sublevel
# =========================
cd "$KERNEL_ROOT/common"
ACTUAL_SUBLEVEL=$(grep '^SUBLEVEL = ' Makefile | awk '{print $3}')
export ACTUAL_SUBLEVEL="${ACTUAL_SUBLEVEL:-$sub_level}"

# =========================
# KernelSU-Next + SuSFS
# =========================
curl -fsSL https://raw.githubusercontent.com/Mr-Morat/KernelSU-Next/master/kernel/setup.sh | bash
# =========================
# Add SuSFS (required for KernelSU-Next)
# =========================
git clone https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs

cp /tmp/susfs/kernel/fs/susfs.c fs/
cp /tmp/susfs/kernel/include/linux/susfs.h include/linux/
cp /tmp/susfs/kernel/include/linux/susfs_def.h include/linux/
echo "CONFIG_SUSFS=y" >> "$DEFCONFIG"

grep -q "susfs.o" fs/Makefile || echo "obj-y += susfs.o" >> fs/Makefile

echo "CONFIG_KSU=y" >> "$DEFCONFIG"
echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$DEFCONFIG"
echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG"
echo "CONFIG_KPM=y" >> "$DEFCONFIG"

# =========================
# GKI config cleanup
# =========================
cd "$KERNEL_ROOT"
sed -i 's/check_defconfig//' common/build.config.gki

# Mountify / root fs helpers
echo "CONFIG_TMPFS_XATTR=y" >> "$DEFCONFIG"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$DEFCONFIG"

# Networking
echo "CONFIG_IP_NF_TARGET_TTL=y" >> "$DEFCONFIG"
echo "CONFIG_IP6_NF_TARGET_HL=y" >> "$DEFCONFIG"
echo "CONFIG_IP6_NF_MATCH_HL=y" >> "$DEFCONFIG"

# TCP BBR (safe for GKI)
echo "CONFIG_TCP_CONG_ADVANCED=y" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
echo "CONFIG_NET_SCH_FQ=y" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_BIC=n" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_WESTWOOD=n" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_HTCP=n" >> "$DEFCONFIG"

# IPSet (KernelSU userspace friendly)
echo "CONFIG_IP_SET=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_MAX=65534" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_BITMAP_IP=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IP=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_LIST_SET=y" >> "$DEFCONFIG"

# =========================
# Kernel branding
# =========================
sed -i '$s|.*|echo "${KERNELVERSION}${config_localversion}"|' common/scripts/setlocalversion
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-onyx"/' "$DEFCONFIG"
echo "CONFIG_LOCALVERSION_AUTO=n" >> "$DEFCONFIG"

UTS_VERSION="#1 SMP PREEMPT $(date -u +%a\ %b\ %d\ %H:%M:%S\ UTC\ %Y)"
perl -pi -e "s|UTS_VERSION=\".*\"|UTS_VERSION=\"${UTS_VERSION}\"|" common/scripts/mkcompile_h

sed -i '/stable_scmversion_cmd/s/-maybe-dirty//g' build/kernel/kleaf/impl/stamp.bzl
rm -rf common/android/abi_gki_protected_exports_*
perl -pi -e 's/^\s*"protected_exports_list".*//;' common/BUILD.bazel

# =========================
# Build
# =========================
FILE_NAME="kernel-$kernel_version-$ACTUAL_SUBLEVEL-$android_version-$os_patch_level.zip"

tools/bazel build --config=fast --lto=thin //common:kernel_aarch64_dist

# =========================
# KPM patch
# =========================
cd "$KERNEL_RESULT"
wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.2/patch_linux
chmod +x patch_linux
./patch_linux

rm -f Image
mv oImage Image

# =========================
# AnyKernel3
# =========================
cp Image "$ANYKERNEL3/kernels/Image"
cd "$ANYKERNEL3"
zip -r9 "$FILE_NAME" *

# =========================
# Upload
# =========================
RESPONSE=$(curl -s -F "file=@$FILE_NAME" https://store1.gofile.io/contents/uploadfile || \
           curl -s -F "file=@$FILE_NAME" https://store2.gofile.io/contents/uploadfile)

DOWNLOAD_LINK=$(echo "$RESPONSE" | grep -oP '"downloadPage":"\K[^"]+')
echo -e "\nDownload link: $DOWNLOAD_LINK\n"

echo "Completed in $((SECONDS / 60))m $((SECONDS % 60))s"
cd "$ROOT"

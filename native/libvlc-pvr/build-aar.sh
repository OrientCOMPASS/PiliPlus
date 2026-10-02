#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PiliPlus — build the patched libvlc AAR ("libvlc-pvr") for Android arm64.
#
# Pipeline (mirrors the upstream libvlcjni CI, but pinned & patched):
#   1. Fetch libvlcjni (Java/JNI bindings + Android build system) at a pinned
#      revision from the VideoLAN GitLab (REST archive; git protocol is often
#      blocked for datacenter IPs).
#   2. Fetch VLC core sources at a pinned revision (GitHub mirror tarball).
#   3. Apply the official libvlcjni patch series onto VLC (git am).
#   4. Apply the PiliPlus VR patch series (patches/vlc, patches/libvlcjni).
#   5. Build libvlc with prebuilt contribs when available.
#   6. Assemble the AAR with gradle.
#
# Requirements: ANDROID_NDK (r27-r29) in env, gradle 9.x, JDK 17+, and the
# usual autotools host packages. Output:
#   <work>/libvlcjni/libvlc/build/outputs/aar/libvlc-arm64-v8a-<ver>.aar
# ---------------------------------------------------------------------------
set -euo pipefail

ABI="${1:-arm64}"
case "$ABI" in
    arm64) TRIPLET="aarch64-linux-android"; ABI_DIR="arm64-v8a"; CONTRIB_ARCH="android-arm64" ;;
    *) echo "ERROR: only arm64 is supported (got '$ABI')" >&2; exit 1 ;;
esac

# ---- pinned revisions ------------------------------------------------------
VLC_HASH="84177b2273abc5c4300234e6e18b55a4d2dd5a03"        # vlc 3.0.x
LIBVLCJNI_SHA="0b8dc65efb203c86a0476bc337ddd99ecf1c0ef6"    # libvlcjni-3.x
CONTRIB_SHA="58f19304cbc30a42bc0a954b10d122a0155c1f2d"      # prebuilt contribs
GITLAB_PROJECT_ID="2405"                                    # videolan/libvlcjni

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${PVR_WORK_DIR:-$SCRIPT_DIR/../../build-libvlc}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

GIT_ID=(-c user.name=pili-ci -c user.email=pili-ci@localhost)

echo "==> work dir: $WORK"

# ---- 1. libvlcjni -----------------------------------------------------------
if [ ! -d "$WORK/libvlcjni" ]; then
    echo "==> fetching libvlcjni $LIBVLCJNI_SHA"
    curl -f -sL --retry 5 --retry-delay 5 -o "$WORK/libvlcjni.tar.gz" \
        "https://code.videolan.org/api/v4/projects/$GITLAB_PROJECT_ID/repository/archive.tar.gz?sha=$LIBVLCJNI_SHA"
    tar xzf "$WORK/libvlcjni.tar.gz" -C "$WORK"
    mv "$WORK"/libvlcjni-*-* "$WORK/libvlcjni" 2>/dev/null \
        || mv "$WORK"/libvlcjni-* "$WORK/libvlcjni"
fi

# ---- 2. vlc -----------------------------------------------------------------
if [ ! -d "$WORK/libvlcjni/vlc" ]; then
    echo "==> fetching vlc $VLC_HASH"
    curl -f -sL --retry 5 --retry-delay 5 -o "$WORK/vlc.tar.gz" \
        "https://github.com/videolan/vlc/archive/$VLC_HASH.tar.gz"
    tar xzf "$WORK/vlc.tar.gz" -C "$WORK/libvlcjni"
    mv "$WORK/libvlcjni"/vlc-* "$WORK/libvlcjni/vlc"
fi

# ---- 3. official libvlcjni patch series (git am, as in get-vlc.sh) ----------
cd "$WORK/libvlcjni/vlc"
if [ ! -f "$WORK/.official-patches-applied" ]; then
    if [ ! -d .git ]; then
        git init -q
        git add -A
        git "${GIT_ID[@]}" commit -qm "vlc base $VLC_HASH"
    fi
    echo "==> applying official libvlcjni patches"
    git "${GIT_ID[@]}" am --message-id ../libvlc/patches/*.patch
    touch "$WORK/.official-patches-applied"
fi

# ---- 4. PiliPlus patches ----------------------------------------------------
if [ ! -f "$WORK/.pili-vlc-applied" ]; then
    echo "==> applying PiliPlus VLC patches"
    git apply --verbose "$SCRIPT_DIR"/patches/vlc/*.patch
    touch "$WORK/.pili-vlc-applied"
fi

cd "$WORK/libvlcjni"
if [ ! -d .git ]; then
    git init -q
    git add -A
    git "${GIT_ID[@]}" commit -qm "libvlcjni base $LIBVLCJNI_SHA"
fi
if [ ! -f "$WORK/.pili-jni-applied" ]; then
    echo "==> applying PiliPlus libvlcjni patches"
    git apply --verbose "$SCRIPT_DIR"/patches/libvlcjni/*.patch
    touch "$WORK/.pili-jni-applied"
fi

# ---- 5. build libvlc --------------------------------------------------------
: "${ANDROID_NDK:?ANDROID_NDK must point to an Android NDK r27-r29}"
export ANDROID_NDK

CONTRIB_FLAGS=""
CONTRIB_URL="https://artifacts.videolan.org/vlc-3.0/$CONTRIB_ARCH/vlc-contrib-$TRIPLET-$CONTRIB_SHA.tar.zst"
if curl -f -sI --retry 2 -o /dev/null "$CONTRIB_URL"; then
    echo "==> using prebuilt contribs: $CONTRIB_URL"
    export VLC_PREBUILT_CONTRIBS_URL="$CONTRIB_URL"
    CONTRIB_FLAGS="--with-prebuilt-contribs"
else
    echo "==> WARNING: prebuilt contribs not found, building from source (slow)"
fi

cd "$WORK/libvlcjni"
# --static-cpp: libvlc/libvlcjni statically link libc++ so the app process
# (which also hosts libmpv with its own C++ runtime) has zero shared-runtime
# coupling; also avoids libc++_shared merge/load issues on devices.
./buildsystem/compile-libvlc.sh -a "$ABI" $CONTRIB_FLAGS --release --static-cpp

# ---- 6. assemble the AAR -----------------------------------------------------
echo "==> assembling AAR"
GRADLE_ABI="$ABI_DIR" gradle :libvlc:assembleRelease --no-daemon

AAR_DIR="$WORK/libvlcjni/libvlc/build/outputs/aar"
echo "==> done:"
ls -la "$AAR_DIR"/*.aar

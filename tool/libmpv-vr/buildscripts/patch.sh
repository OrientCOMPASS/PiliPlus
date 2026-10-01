#!/bin/bash -e

set -euo pipefail

PATCHES=(patches/*)
ROOT=$(pwd)

for dep_path in "${PATCHES[@]}"; do
    if [ -d "$dep_path" ]; then
        patches=($dep_path/*)
        dep=$(echo $dep_path |cut -d/ -f 2)
        cd deps/$dep
        echo Patching $dep
        git reset --hard
        # [PiliPlus] deps 目录被 actions/cache 复用时, 上一次应用补丁产生的
        # 新增文件(vr.c/vr.h/vr_tracker.* 是补丁新增的, 不在 git 索引里)
        # 不会被 reset --hard 清掉, 再次 git apply 会报 already exists。
        # clean 只影响有补丁的依赖(当前仅 mpv), 代价是 mpv 每次全量重编,
        # ffmpeg 等其余依赖的增量构建目录不受影响。
        git clean -fdx
        for patch in "${patches[@]}"; do
            echo Applying $patch
            git apply "$ROOT/$patch"
        done
        cd $ROOT
    fi
done

exit 0

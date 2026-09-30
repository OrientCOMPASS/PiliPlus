# xl_player 渲染层（vendored）+ PiliPlus 的 JNI 驱动
#
# 上游: https://github.com/xl-player-developers/xl_player  (xl-player-armv7a/src/main/cpp)
#
# 只编**渲染相关**的源文件。上游 CMakeLists 里另外那一半（xl_container / xl_decoders /
# xl_audio / xl_player.c / xl_playerCore.c / xl_player_read_thread.c / xl_player_gl_thread.c）
# 是 FFmpeg 3.x 的解封装+解码+音频链，需要链接 libavcodec-57/libavformat-57/libavutil-55/
# libavfilter-6/libswresample-2，而仓库里只带 armeabi-v7a 的预编译 .so（本项目是 arm64-v8a，
# 64 位进程加载不了 32 位库）。按需求这部分不移植：解封装/解码继续用 Android 的
# MediaExtractor + MediaCodec（Kotlin 侧 VrEngine），渲染层通过 OES 纹理对接，
# 也就是上游 `XL_PIX_FMT_EGL_EXT` 那条硬解路径。
#
# 因此这里**不链接任何 FFmpeg**；`compat/libavutil/frame.h` 是一个同名类型垫片，
# 让上游渲染层源码无需修改即可编译（详见该文件头部注释）。

cmake_minimum_required(VERSION 3.22.1)

project(xl_vr C CXX)

set(XL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/xl)

add_library(xl_vr SHARED
        # ---- PiliPlus 新增：EGL / 渲染循环 / JNI 桥 ----
        xl_vr_jni.c

        # ---- 上游 xl_video：网格、着色器、矩阵、模型、纹理、头追接口 ----
        ${XL_DIR}/xl_video/xl_mat4.c
        ${XL_DIR}/xl_video/xl_mesh_factory.c
        ${XL_DIR}/xl_video/xl_glsl_program.c
        ${XL_DIR}/xl_video/xl_model.c
        ${XL_DIR}/xl_video/xl_model_ball.c
        ${XL_DIR}/xl_video/xl_model_rect.c
        ${XL_DIR}/xl_video/xl_model_vr.c
        ${XL_DIR}/xl_video/xl_texture.c
        ${XL_DIR}/xl_video/xl_tracker.c
        ${XL_DIR}/xl_video/xl_video_render.c

        # ---- 上游 xl_head_tracker：Google Cardboard 的 OrientationEKF（C++，无外部依赖）----
        ${XL_DIR}/xl_head_tracker/Vector3d.cpp
        ${XL_DIR}/xl_head_tracker/SO3Util.cpp
        ${XL_DIR}/xl_head_tracker/Matrix3x3d.cpp
        ${XL_DIR}/xl_head_tracker/OrientationEKF.cpp
        ${XL_DIR}/xl_head_tracker/HeadTracker.cpp
)

target_include_directories(xl_vr PRIVATE
        # "xl/..." 形式的 include 从这里解析
        ${CMAKE_CURRENT_SOURCE_DIR}
        # 必须能被 <libavutil/frame.h> 命中 —— 顶替真 FFmpeg 头
        ${CMAKE_CURRENT_SOURCE_DIR}/compat
        # 上游源文件内部的相对 include（"../xl_types/..."）依赖这个布局，无需额外指定
        )

find_library(log-lib log)
find_library(android-lib android)
find_library(glesv2-lib GLESv2)
find_library(egl-lib EGL)

# ASensorManager / ALooper（xl_tracker.c 用 NDK 传感器 API）都在 libandroid 里
target_link_libraries(xl_vr
        ${log-lib}
        ${android-lib}
        ${egl-lib}
        ${glesv2-lib}
        )

target_compile_options(xl_vr PRIVATE
        # 上游 build.gradle 的 cppFlags "-frtti -fexceptions"
        -frtti -fexceptions
        # 上游源码是 2017 年写的，靠当年 NDK 头文件的间接包含拿到一些声明，新 NDK 不一定还给：
        #   · xl_tracker.c 用 gettimeofday/struct timeval 却没 include <sys/time.h>
        #   · xl_video_render_types.h 用 pthread_mutex_t / uint8_t 却没 include <pthread.h>/<stdint.h>
        # 用编译选项统一前置包含，这样上游文件可以保持逐字不动。
        -include sys/time.h
        -include pthread.h
        -include stdint.h
        -Wno-unused-parameter
        -Wno-comment
        )

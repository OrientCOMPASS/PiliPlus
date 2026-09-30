//
// 上游: xl-player-armv7a/src/main/cpp/xl_types/xl_player_types.h
//
// 【本仓库唯一被裁剪的上游头文件】
// 上游这个头把整个播放器的状态 (`xl_play_data`) 都定义在这里，并且 include 了
// <libavformat/avformat.h> <libavcodec/avcodec.h> <libavutil/imgutils.h> <libavfilter/avfilter.h>
// <media/NdkMediaCodec.h> —— 也就是把 FFmpeg 解码链、NDK MediaCodec、OpenSLES 音频全都拖进来。
//
// 我们只移植 xl_player 的**渲染层**（网格/着色器/矩阵/模型 + Cardboard EKF 头追），
// 解封装与解码仍由 Kotlin 侧的 MediaExtractor/MediaCodec 负责（它已经跑通，且不引入
// FFmpeg 3.x 的 arm64 交叉编译负担）。渲染层用到 `xl_play_data` 的地方只有两处：
//   xl_texture.c : pd->video_render_ctx / pd->is_sw_decode
//   xl_texture.h : initTexture(xl_play_data*) / xl_texture_delete(xl_play_data*)
// 所以这里只保留这两个字段，其余（frame queue、clock、AVFormatContext、MediaCodec 句柄、
// 音频上下文、JNI 类缓存……）连同 FFmpeg 的 include 一起删掉。
//
// 裁剪原则：**不改任何被渲染层使用的名字与语义**，只删我们用不到的声明。
//
// Created by gutou on 2017/4/6.
//

#ifndef XL_XL_PLAYER_TYPES
#define XL_XL_PLAYER_TYPES

#include <android/native_window_jni.h>
#include "xl_video_render_types.h"
#include "xl_macro.h"

/**
 * 播放器的共享状态。上游版本还包含解封装/解码/音频/时钟等几十个字段，
 * 这里只保留渲染层真正读取的两个。
 */
typedef struct xl_play_data {
    /** 渲染上下文（EGL、输出窗口、纹理、当前模型）。 */
    xl_video_render_context *video_render_ctx;
    /** 0 = 硬解（MediaCodec → OES 纹理），1 = 软解（FFmpeg → YUV 纹理）。本项目恒为 0。 */
    int is_sw_decode;
} xl_play_data;

#endif //XL_XL_PLAYER_TYPES

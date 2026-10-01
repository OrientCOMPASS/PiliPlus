/*
 * FFmpeg 兼容垫片 —— 让 xl_player 的渲染层源码**一行都不用改**就能编进 arm64-v8a。
 *
 * 背景：上游 xl_player (https://github.com/xl-player-developers/xl_player) 的渲染层
 * (xl_video/*、xl_head_tracker/*) 并不调用任何 FFmpeg 函数，它只是：
 *   1) 在函数签名里把 `AVFrame *` 当**不透明指针**传递（硬解 OES 路径那个参数甚至标了
 *      `__attribute__((unused))`，见 xl_texture.c 的 update_texture_oes）；
 *   2) 用 `enum AVPixelFormat` 当"像素格式标记"在 switch 里分支。
 * 唯一真正解引用 AVFrame 字段的是软解路径 update_texture_yuv420p/nv12（读 data/linesize/height），
 * 以及 update_frame_ball 里的 `frame->format / width / linesize[0]`。
 *
 * 本项目的 VR 播放走 Android MediaCodec（硬解 → OES 纹理），**不链接 FFmpeg**，
 * 所以这里给出同名类型的最小定义，字段布局按用到的部分提供即可。
 *
 * 上游通过 `#include <libavutil/frame.h>` 引入，本目录被放在 include 搜索路径最前面，
 * 于是这个文件顶替了真的 FFmpeg 头文件。
 */
#ifndef XL_COMPAT_LIBAVUTIL_FRAME_H
#define XL_COMPAT_LIBAVUTIL_FRAME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 上游只会解引用这几个字段（软解路径 + update_frame_*），其余一律用不到。
 * 另外两个字段是上游 xl_macro.h 的"借位"宏要求的：
 *   #define HW_BUFFER_ID  pkt_pos      （硬解路径把 buffer id 塞进 pkt_pos）
 *   #define FRAME_ROTATION sample_rate （xl_model_rect.c 把旋转角塞进音频字段 sample_rate）
 * 我们走 OES 硬解纹理，运行时不会真用到，但类型定义里必须有，否则编译不过。 */
typedef struct AVFrame {
    uint8_t *data[8];
    int linesize[8];
    int width;
    int height;
    int format;
    int64_t pts;
    int64_t pkt_pos;
    int sample_rate;
} AVFrame;

/* 只列出渲染层出现过的三个取值；数值本身无所谓（我们永远不会送 YUV/NV12 帧进来），
 * 保持与 FFmpeg 一致只是为了读代码时不困惑。 */
enum AVPixelFormat {
    AV_PIX_FMT_NONE = -1,
    AV_PIX_FMT_YUV420P = 0,
    AV_PIX_FMT_NV12 = 23,
};

#ifdef __cplusplus
}
#endif

#endif /* XL_COMPAT_LIBAVUTIL_FRAME_H */

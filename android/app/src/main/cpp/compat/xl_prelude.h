/*
 * 统一前置包含 —— 由 CMakeLists 的 `-include` 注入到每个编译单元。
 *
 * 上游源码是 2017 年写的，有些声明靠当年 NDK 头文件的间接包含才拿得到，NDK r28 不一定还给：
 *   · xl_tracker.c 用 gettimeofday / struct timeval，却没 include <sys/time.h>
 *   · xl_video_render_types.h 用 pthread_mutex_t，却没 include <pthread.h>
 *   · 多处用 uint8_t / size_t，却没 include <stdint.h> / <stddef.h>
 * 用这个前置头统一补上，上游文件就能保持逐字不动。
 *
 * 注意：只能有**一个** -include。写三个 `-include a.h b.h c.h` 会被 CMake 合并成
 * `-include a.h b.h c.h`，clang 会把后两个当成输入文件报 "no such file or directory"
 * （第九轮 CI 就是这么挂的）。
 */
#ifndef XL_COMPAT_PRELUDE_H
#define XL_COMPAT_PRELUDE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>   /* xl_tracker.c 用 memset 却没 include */
#include <math.h>     /* xl_mat4.c 用 tanf/sinf/cosf/sqrtf/fabsf 却没 include（新版 clang 视为硬错误） */
#include <pthread.h>
#include <sys/time.h>

#endif /* XL_COMPAT_PRELUDE_H */

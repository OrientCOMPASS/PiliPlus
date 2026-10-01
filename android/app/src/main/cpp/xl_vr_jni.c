/*
 * xl_vr_jni.c —— 把 xl_player 的渲染层接到 PiliPlus 的 MediaCodec 解码上。
 *
 * 为什么需要这个文件：
 *   上游用 `xl_player_gl_thread.c` 驱动渲染，但那个循环深度绑定了它的 FFmpeg 播放状态
 *   (`xl_play_data` 的 frame queue / clock / xl_mediacodec / send_message)。按需求我们保留
 *   Android 侧的 MediaExtractor + MediaCodec 解码（已跑通，且不必把 FFmpeg 3.x 交叉编译到
 *   arm64），所以这里用**同样的结构**重写这一层驱动：
 *
 *     · EGL 初始化           —— 照搬上游 init_egl()（去掉 xl_play_data 依赖）
 *     · OES 纹理             —— 直接调上游 initTexture()（硬解分支）
 *     · 视频 SurfaceTexture  —— 照搬上游的做法：GL 线程内经 JNI 让 Java 侧
 *                               `SurfaceTextureBridge.getSurface(texName)` 建 SurfaceTexture，
 *                               于是 updateTexImage() 可以合法地在 GL 线程调用
 *     · 每帧 updateTexImage + getTransformMatrix —— 照搬上游 draw_video_frame() 的硬解分支
 *     · 头追                 —— 直接调上游 xl_tracker_get_last_view()（Cardboard OrientationEKF）
 *     · 模型/网格/着色器/矩阵 —— 全部上游原码（xl_model_ball / xl_mesh_factory /
 *                               xl_glsl_program / xl_mat4）
 *
 *   与上游唯一的行为差别：手动视角的俯仰在开启陀螺仪时依然生效。上游 updateHead() 只做
 *   `modelMatrix = head; rotateY(_ry)`（手动只保留偏航），我们在组装矩阵时补一个 rotateX，
 *   用的仍是上游 xl_mat4 的函数，没有自己写矩阵运算。
 */

#include <jni.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <sys/prctl.h>
#include <sys/time.h>

#include "xl/xl_types/xl_player_types.h"
#include "xl/xl_video/xl_model.h"
#include "xl/xl_video/xl_model_ball.h"
#include "xl/xl_video/xl_mat4.h"
#include "xl/xl_video/xl_mesh_factory.h"
#include "xl/xl_video/xl_texture.h"
#include "xl/xl_video/xl_glsl_program.h"
#include "xl/xl_video/xl_tracker.h"
#include "xl/xl_video/xl_video_render.h"

#define TAG "VrXl"
/* 上游 xl_macro.h（经 xl_model.h 等间接引入）已定义过 LOGE，这里接管成自己的 TAG，
 * 先 #undef 消掉 -Wmacro-redefined。 */
#undef LOGE
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define DEG2RAD ((float) M_PI / 180.0f)
/** 渲染节奏上限：60fps。上游 fixed_frequency 模式也是全速画。 */
#define FRAME_INTERVAL_US 16000
/** 没有任何变化时的空转间隔（省电，也避免无谓地占 GPU）。 */
#define IDLE_SLEEP_US 33000

typedef struct xl_vr {
    JavaVM *vm;

    /* ---- 输出（Flutter 的 SurfaceTextureEntry → Surface → ANativeWindow）---- */
    jobject out_surface_ref;
    ANativeWindow *out_window;
    EGLDisplay display;
    EGLConfig config;
    EGLSurface surface;
    EGLContext context;
    int width, height;
    /** Kotlin 侧要求的渲染尺寸（比 eglQuerySurface 可靠：SurfaceTexture 的
     *  defaultBufferSize 改了以后 EGL 那边不一定同步）。 */
    volatile int req_w, req_h;

    /* ---- 视频输入（MediaCodec → SurfaceTexture → OES 纹理）---- */
    jobject bridge_class;
    jmethodID m_get_surface, m_update_tex_image, m_get_transform_matrix;
    jobject video_surface_ref;
    GLuint oes_texture;
    int video_w, video_h;

    /* ---- 上游渲染对象 ---- */
    xl_video_render_context *ctx;
    xl_play_data pd;
    xl_model *model;

    /* ---- 状态（全部只在 GL 线程写，Kotlin 线程通过 flag 请求）---- */
    volatile bool running;
    volatile bool ready;
    volatile bool new_frame;
    volatile bool dirty;
    volatile bool rebuild;
    volatile bool resize;
    volatile bool tracker_on;
    volatile bool flip_v;
    /** 诊断用「原画直通」：换成上游的 Rect 模型（平面四边形，直接铺原始画面）。 */
    volatile bool passthrough;
    volatile bool req_passthrough;
    float manual_yaw, manual_pitch;
    float yaw_sign, pitch_sign;
    /** 「重置视角」= 记住当前头姿作为新的正前方。只在 GL 线程读写。 */
    volatile bool want_reset_ref;
    GLfloat reset_ref_inv[16];
    bool has_reset_ref;
    float fovh_deg;
    float coverage, u0, u1, v0, v1;
    /** 请求的水平 fov / 投影参数（Kotlin 线程写，GL 线程读） */
    volatile float req_fovh, req_coverage, req_u0, req_u1, req_v0, req_v1;

    pthread_t tid;
    pthread_mutex_t lock;
    pthread_cond_t ready_cond;

    long frames, skipped;
    char last_error[192];
} xl_vr;

static inline int64_t now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t) tv.tv_sec * 1000000LL + tv.tv_usec;
}

static void set_error(xl_vr *v, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(v->last_error, sizeof(v->last_error), fmt, ap);
    va_end(ap);
    LOGE("%s", v->last_error);
}

/* ============================================================================
 * EGL —— 照搬上游 xl_player_gl_thread.c 的 init_egl()
 * ==========================================================================*/
static bool init_egl(xl_vr *v) {
    const EGLint attribs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE,
                              EGL_OPENGL_ES2_BIT, EGL_BLUE_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_RED_SIZE,
                              8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0,
                              EGL_NONE};
    EGLint numConfigs = 0;
    v->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (v->display == EGL_NO_DISPLAY) {
        set_error(v, "eglGetDisplay 失败");
        return false;
    }
    EGLint major, minor;
    eglInitialize(v->display, &major, &minor);
    if (!eglChooseConfig(v->display, attribs, &v->config, 1, &numConfigs) || numConfigs < 1) {
        set_error(v, "eglChooseConfig 失败");
        return false;
    }
    v->surface = eglCreateWindowSurface(v->display, v->config, v->out_window, NULL);
    if (v->surface == EGL_NO_SURFACE) {
        set_error(v, "eglCreateWindowSurface 失败 eglErr=0x%x", eglGetError());
        return false;
    }
    EGLint attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    v->context = eglCreateContext(v->display, v->config, NULL, attrs);
    if (v->context == EGL_NO_CONTEXT) {
        set_error(v, "eglCreateContext 失败 eglErr=0x%x", eglGetError());
        return false;
    }
    if (eglMakeCurrent(v->display, v->surface, v->surface, v->context) == EGL_FALSE) {
        set_error(v, "eglMakeCurrent 失败 eglErr=0x%x", eglGetError());
        return false;
    }
    eglQuerySurface(v->display, v->surface, EGL_WIDTH, &v->width);
    eglQuerySurface(v->display, v->surface, EGL_HEIGHT, &v->height);
    LOGD("EGL 就绪 %dx%d (GLES %d.%d)", v->width, v->height, major, minor);
    return true;
}

/* ============================================================================
 * 模型 —— 上游 createModel() + 我们的投影参数
 * ==========================================================================*/
static void apply_fov(xl_vr *v) {
    if (v->model == NULL || v->width <= 0 || v->height <= 0) return;
    /* Kotlin 侧的 fov 是**水平**视场角，上游 perspective() 要的是**垂直**视场角。 */
    float aspect = (float) v->width / (float) v->height;
    float half_h = tanf(v->fovh_deg * 0.5f * DEG2RAD);
    float fovy = 2.0f * atanf(half_h / aspect) / DEG2RAD;
    if (fovy < 1.0f) fovy = 1.0f;
    if (fovy > 179.0f) fovy = 179.0f;
    xl_model_set_fovy(v->model, fovy);
}

/** 在 GL 线程上（重新）创建模型。必须在 xl_mesh_set_projection() 之后调用。 */
static bool create_model_locked(xl_vr *v) {
    if (v->model != NULL) {
        freeModel(v->model);
        v->model = NULL;
    }
    xl_mesh_set_projection(v->coverage, v->u0, v->u1, v->v0, v->v1);
    ModelType type = v->passthrough ? Rect : Ball;
    v->model = createModel(type);
    if (v->model == NULL) {
        set_error(v, "createModel(%s) 返回 NULL", v->passthrough ? "Rect" : "Ball");
        return false;
    }
    /* 上游 change_model() 的关键一步：把渲染上下文的纹理交给模型。 */
    memcpy(v->model->texture, v->ctx->texture, sizeof(GLuint) * 4);
    v->model->resize(v->model, v->width > 0 ? v->width : 1, v->height > 0 ? v->height : 1);
    apply_fov(v);
    v->dirty = true;

    /* 上游的 update_frame() 负责按像素格式挑着色器并绑定顶点属性。
     * 我们恒为硬解 OES，所以造一个"伪 AVFrame"喂给它（见 compat/libavutil/frame.h）：
     *   format   = XL_PIX_FMT_EGL_EXT  → 选 fs_egl_ext + bind_texture_oes
     *   linesize[0] = width            → width_adjustment = 1.0
     */
    AVFrame fake;
    memset(&fake, 0, sizeof(fake));
    fake.format = XL_PIX_FMT_EGL_EXT;
    fake.width = v->video_w > 0 ? v->video_w : 1920;
    fake.height = v->video_h > 0 ? v->video_h : 1080;
    fake.linesize[0] = fake.width;
    v->model->update_frame(v->model, &fake);
    LOGD("模型已建 %s coverage=%.0f uv=[%.2f,%.2f]x[%.2f,%.2f] %dx%d tri=%zu",
         v->passthrough ? "Rect(直通)" : "Ball(球面)", v->coverage, v->u0, v->u1, v->v0, v->v1,
         v->width, v->height, v->model->elementsCount / 3);
    return true;
}

/* ============================================================================
 * GL 线程
 * ==========================================================================*/
static void compose_model_matrix(xl_vr *v) {
    GLfloat m[16];
    float yaw = v->manual_yaw * v->yaw_sign;
    float pitch = v->manual_pitch * v->pitch_sign;
    if (v->tracker_on) {
        /* 「重置视角」请求：把当前头姿记为新的正前方。
         * 不在别的线程直接调 xl_ekf_reset()——那是 EKF 线程持有锁的内部状态，跨线程改会撕裂。
         * 改成在组合矩阵时右乘 ref⁻¹：head == ref 时结果就是单位阵，画面回到正前方。 */
        if (v->want_reset_ref) {
            GLfloat ref[16];
            xl_tracker_get_last_view(ref);
            /* 旋转矩阵的逆 == 转置（只转 3x3 部分，平移恒为 0）。 */
            for (int c = 0; c < 4; c++) {
                for (int r = 0; r < 4; r++) {
                    v->reset_ref_inv[c * 4 + r] = (r == 3 || c == 3) ? (r == c ? 1.0f : 0.0f)
                                                                    : ref[r * 4 + c];
                }
            }
            v->has_reset_ref = true;
            v->want_reset_ref = false;
        }
        /* 上游 xl_tracker_get_last_view()：Cardboard OrientationEKF 的预测姿态，
         * 内部已含 33ms 前视补偿和横屏校正矩阵 ekf_to_head_tracker。 */
        xl_tracker_get_last_view(m);
        if (v->has_reset_ref) multiply(m, m, v->reset_ref_inv);
        /* 上游 updateHead() 的行为：modelMatrix = head; rotateY(_ry) —— 手动只保留偏航。
         * 我们在此基础上补一个手动俯仰（用的还是上游 xl_mat4 的 rotateX）。 */
        rotateY(m, yaw);
        rotateX(m, pitch);
    } else {
        /* 与上游 updateModelMatrix() 的顺序一致：identity → rotateX → rotateY
         * （上游是 rotateZ→rotateX→rotateY，我们不使用滚转）。 */
        identity(m);
        rotateX(m, pitch);
        rotateY(m, yaw);
    }
    memcpy(v->model->modelMatrix, m, sizeof(GLfloat) * 16);
}

/** 把 SurfaceTexture 的变换矩阵取到 model->texture_matrix，按需做垂直翻转。 */
static void pull_texture_matrix(xl_vr *v, JNIEnv *env) {
    jfloatArray arr = (jfloatArray) (*env)->CallStaticObjectMethod(env, v->bridge_class,
                                                                  v->m_get_transform_matrix);
    if (arr == NULL) return;
    GLfloat m[16];
    (*env)->GetFloatArrayRegion(env, arr, 0, 16, m);
    (*env)->DeleteLocalRef(env, arr);
    if (v->flip_v) {
        /* 关于 v=0.5 翻转：M' = F·M，F = diag(1,-1,1,1) 且平移 y+1（列主序）。
         * 逐列展开即下面四行，避免再引入一次 4x4 乘法。 */
        GLfloat f[16];
        for (int c = 0; c < 4; c++) {
            int b = c * 4;
            f[b + 0] = m[b + 0];
            f[b + 1] = -m[b + 1];
            f[b + 2] = m[b + 2];
            f[b + 3] = m[b + 1] + m[b + 3];
        }
        memcpy(m, f, sizeof(m));
    }
    memcpy(v->model->texture_matrix, m, sizeof(GLfloat) * 16);
}

static void *gl_thread(void *arg) {
    prctl(PR_SET_NAME, "xl_vr_gl", 0, 0);
    xl_vr *v = (xl_vr *) arg;
    JNIEnv *env = NULL;
    if ((*v->vm)->AttachCurrentThread(v->vm, &env, NULL) != JNI_OK) {
        set_error(v, "AttachCurrentThread 失败");
        pthread_mutex_lock(&v->lock);
        v->ready = true;
        pthread_cond_broadcast(&v->ready_cond);
        pthread_mutex_unlock(&v->lock);
        return NULL;
    }

    bool ok = init_egl(v);
    if (ok) {
        /* 上游 initTexture() 的硬解分支：建一个 OES 纹理放到 ctx->texture[3]。 */
        initTexture(&v->pd);
        v->oes_texture = v->ctx->texture[3];
        /* 照搬上游：在 GL 线程内经 Java 桥建 SurfaceTexture(texName)，
         * 这样之后每帧的 updateTexImage() 都在同一个线程上，合法。 */
        jobject surface = (*env)->CallStaticObjectMethod(env, v->bridge_class, v->m_get_surface,
                                                         (jint) v->oes_texture);
        if (surface != NULL) {
            v->video_surface_ref = (*env)->NewGlobalRef(env, surface);
            (*env)->DeleteLocalRef(env, surface);
        } else {
            set_error(v, "VrSurfaceBridge.getSurface 返回 null");
            ok = false;
        }
    }
    if (ok) {
        ok = create_model_locked(v);
    }

    pthread_mutex_lock(&v->lock);
    v->ready = true;
    pthread_cond_broadcast(&v->ready_cond);
    pthread_mutex_unlock(&v->lock);

    if (ok) {
        if (v->tracker_on) xl_tracker_start();
        bool have_frame = false;
        while (v->running) {
            int64_t t0 = now_us();

            /* 1) 处理来自 Kotlin 线程的请求 */
            pthread_mutex_lock(&v->lock);
            bool need_rebuild = v->rebuild;
            bool need_resize = v->resize;
            float want_fovh;
            if (v->req_passthrough != v->passthrough) {
                v->passthrough = v->req_passthrough;
                need_rebuild = true;
            }
            if (need_rebuild) {
                v->coverage = v->req_coverage;
                v->u0 = v->req_u0;
                v->u1 = v->req_u1;
                v->v0 = v->req_v0;
                v->v1 = v->req_v1;
                v->fovh_deg = v->req_fovh;
                v->rebuild = false;
            }
            if (need_resize) v->resize = false;
            want_fovh = v->req_fovh;
            pthread_mutex_unlock(&v->lock);

            if (need_rebuild) {
                /* create_model_locked() 内部会用 v->fovh_deg，先同步成最新请求值。 */
                v->fovh_deg = want_fovh;
                create_model_locked(v);
            } else if (need_resize) {
                if (v->req_w > 0 && v->req_h > 0) {
                    v->width = v->req_w;
                    v->height = v->req_h;
                } else {
                    eglQuerySurface(v->display, v->surface, EGL_WIDTH, &v->width);
                    eglQuerySurface(v->display, v->surface, EGL_HEIGHT, &v->height);
                }
                if (v->model != NULL) v->model->resize(v->model, v->width, v->height);
                v->fovh_deg = want_fovh;
                apply_fov(v);
                v->dirty = true;
            } else if (fabsf(want_fovh - v->fovh_deg) > 0.01f) {
                v->fovh_deg = want_fovh;
                apply_fov(v);
                v->dirty = true;
            }

            if (v->model == NULL) {
                usleep(IDLE_SLEEP_US);
                continue;
            }

            /* 2) 有新帧则 updateTexImage（上游 draw_video_frame 的硬解分支） */
            if (v->new_frame) {
                v->new_frame = false;
                (*env)->CallStaticVoidMethod(env, v->bridge_class, v->m_update_tex_image);
                if ((*env)->ExceptionCheck(env)) {
                    (*env)->ExceptionClear(env);
                } else {
                    pull_texture_matrix(v, env);
                    have_frame = true;
                    v->dirty = true;
                }
            }

            /* 3) 画一帧。
             * 「脏了才画」：有新帧、参数/视角变了、或者开着陀螺仪（姿态每帧都在变）才画。
             * 暂停且无头追时完全不占 GPU —— 上一轮真机反馈的卡顿就是白白满帧重画 + 逐像素
             * 反投影叠加出来的。 */
            bool drew = false;
            if (have_frame || v->dirty || v->tracker_on) {
                compose_model_matrix(v);
                v->model->draw(v->model);
                eglSwapBuffers(v->display, v->surface);
                v->frames++;
                v->dirty = false;
                drew = true;
            } else {
                v->skipped++;
            }
            /* 画过就把"有新帧"清掉，否则暂停后会一直以 60fps 重画同一帧 */
            have_frame = false;

            /* 4) 限速：画过的按 60fps 补齐间隔，没画的睡久一点 */
            int64_t spent = now_us() - t0;
            int64_t sleep_us = drew ? (FRAME_INTERVAL_US - spent) : IDLE_SLEEP_US;
            if (sleep_us > 0) usleep((useconds_t) sleep_us);
        }
    }

    /* 清理：与上游 release_egl() 同序 */
    if (v->display != EGL_NO_DISPLAY) {
        if (v->model != NULL) {
            freeModel(v->model);
            v->model = NULL;
        }
        if (v->oes_texture != 0) xl_texture_delete(&v->pd);
        /* 上游 release_egl() 的同一步：xl_glsl_program.c 用静态变量缓存 program，
         * 不清的话下次进 VR 页面会复用已销毁上下文里的 id -> 黑屏。 */
        xl_glsl_program_clear_all();
        eglMakeCurrent(v->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (v->context != EGL_NO_CONTEXT) eglDestroyContext(v->display, v->context);
        if (v->surface != EGL_NO_SURFACE) eglDestroySurface(v->display, v->surface);
        eglTerminate(v->display);
        v->display = EGL_NO_DISPLAY;
        v->context = EGL_NO_CONTEXT;
        v->surface = EGL_NO_SURFACE;
    }
    if (v->tracker_on) xl_tracker_stop();
    (*v->vm)->DetachCurrentThread(v->vm);
    LOGD("GL 线程退出 frames=%ld skipped=%ld", v->frames, v->skipped);
    return NULL;
}

/* ============================================================================
 * JNI
 * ==========================================================================*/
static jmethodID find_static(JNIEnv *env, jclass cls, const char *name, const char *sig) {
    jmethodID m = (*env)->GetStaticMethodID(env, cls, name, sig);
    if (m == NULL) {
        LOGE("找不到 VrSurfaceBridge.%s%s", name, sig);
        (*env)->ExceptionClear(env);
    }
    return m;
}

JNIEXPORT jlong JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeCreate(JNIEnv *env, jobject thiz,
                                                       jobject out_surface, jfloat coverage,
                                                       jfloat u0, jfloat u1, jfloat v0, jfloat v1,
                                                       jfloat fovh, jboolean tracker,
                                                       jboolean flip_v) {
    xl_vr *v = (xl_vr *) calloc(1, sizeof(xl_vr));
    if (v == NULL) return 0;
    (*env)->GetJavaVM(env, &v->vm);
    pthread_mutex_init(&v->lock, NULL);
    pthread_cond_init(&v->ready_cond, NULL);

    jclass bridge = (*env)->FindClass(env, "com/example/piliplus/vr/VrSurfaceBridge");
    if (bridge == NULL) {
        (*env)->ExceptionClear(env);
        set_error(v, "找不到 VrSurfaceBridge");
        free(v);
        return 0;
    }
    v->bridge_class = (jclass) (*env)->NewGlobalRef(env, bridge);
    v->m_get_surface = find_static(env, bridge, "getSurface", "(I)Landroid/view/Surface;");
    v->m_update_tex_image = find_static(env, bridge, "updateTexImage", "()V");
    v->m_get_transform_matrix = find_static(env, bridge, "getTransformMatrix", "()[F");
    (*env)->DeleteLocalRef(env, bridge);

    v->out_surface_ref = (*env)->NewGlobalRef(env, out_surface);
    v->out_window = ANativeWindow_fromSurface(env, out_surface);
    if (v->out_window == NULL) {
        set_error(v, "ANativeWindow_fromSurface 失败");
        free(v);
        return 0;
    }

    /* 上游的渲染上下文：只用来存 EGL 句柄、纹理数组和模型指针。 */
    v->ctx = xl_video_render_ctx_create();
    v->ctx->window = v->out_window;
    v->pd.video_render_ctx = v->ctx;
    v->pd.is_sw_decode = 0;

    v->coverage = v->req_coverage = coverage;
    v->u0 = v->req_u0 = u0;
    v->u1 = v->req_u1 = u1;
    v->v0 = v->req_v0 = v0;
    v->v1 = v->req_v1 = v1;
    v->fovh_deg = v->req_fovh = fovh;
    v->tracker_on = tracker == JNI_TRUE;
    v->flip_v = flip_v == JNI_TRUE;
    v->yaw_sign = 1.0f;
    v->pitch_sign = 1.0f;
    v->video_w = v->video_h = 0;
    v->req_w = v->req_h = 0;
    v->running = false;
    return (jlong) (intptr_t) v;
}

JNIEXPORT jboolean JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeStart(JNIEnv *env, jobject thiz, jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL || v->running) return JNI_FALSE;
    if (v->m_get_surface == NULL || v->m_update_tex_image == NULL ||
        v->m_get_transform_matrix == NULL) {
        set_error(v, "VrSurfaceBridge 方法未就绪");
        return JNI_FALSE;
    }
    v->running = true;
    v->ready = false;
    if (pthread_create(&v->tid, NULL, gl_thread, v) != 0) {
        v->running = false;
        set_error(v, "pthread_create 失败");
        return JNI_FALSE;
    }
    /* 等 GL 线程把 EGL / OES 纹理 / 视频 Surface 建好，Kotlin 才能拿去 configure MediaCodec。 */
    pthread_mutex_lock(&v->lock);
    int64_t deadline = now_us() + 3000000LL;
    while (!v->ready && now_us() < deadline) {
        struct timespec ts;
        ts.tv_sec = (time_t) (deadline / 1000000LL);
        ts.tv_nsec = (long) ((deadline % 1000000LL) * 1000LL);
        pthread_cond_timedwait(&v->ready_cond, &v->lock, &ts);
    }
    bool ok = v->ready;
    pthread_mutex_unlock(&v->lock);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jobject JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeGetVideoSurface(JNIEnv *env, jobject thiz,
                                                                jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL || v->video_surface_ref == NULL) return NULL;
    return (*env)->NewLocalRef(env, v->video_surface_ref);
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetRenderSize(JNIEnv *env, jobject thiz,
                                                              jlong handle, jint w, jint h) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL || w <= 0 || h <= 0) return;
    v->req_w = w;
    v->req_h = h;
    v->width = w;
    v->height = h;
    v->resize = true;
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetVideoSize(JNIEnv *env, jobject thiz, jlong handle,
                                                             jint w, jint h) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->video_w = w;
    v->video_h = h;
    /* 让 GL 线程重建模型，以便 update_frame() 用新的宽高算 width_adjustment。 */
    v->rebuild = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetProjection(JNIEnv *env, jobject thiz,
                                                              jlong handle, jfloat coverage,
                                                              jfloat u0, jfloat u1, jfloat v0,
                                                              jfloat v1) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    pthread_mutex_lock(&v->lock);
    v->req_coverage = coverage;
    v->req_u0 = u0;
    v->req_u1 = u1;
    v->req_v0 = v0;
    v->req_v1 = v1;
    v->rebuild = true;
    pthread_mutex_unlock(&v->lock);
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetFov(JNIEnv *env, jobject thiz, jlong handle,
                                                       jfloat fovh) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    pthread_mutex_lock(&v->lock);
    v->req_fovh = fovh;
    pthread_mutex_unlock(&v->lock);
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeRotateBy(JNIEnv *env, jobject thiz, jlong handle,
                                                         jfloat yaw_deg, jfloat pitch_deg) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->manual_yaw += yaw_deg * DEG2RAD;
    v->manual_pitch += pitch_deg * DEG2RAD;
    /* 俯仰夹在 ±89°，避免翻过头；偏航不夹（360 片源要能转圈），
     * 180 片源的水平范围由 Dart 侧按格式限制。 */
    const float lim = 89.0f * DEG2RAD;
    if (v->manual_pitch > lim) v->manual_pitch = lim;
    if (v->manual_pitch < -lim) v->manual_pitch = -lim;
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeResetView(JNIEnv *env, jobject thiz, jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->manual_yaw = 0.0f;
    v->manual_pitch = 0.0f;
    if (v->tracker_on) {
        /* 交给 GL 线程去采样当前头姿（见 compose_model_matrix） */
        v->want_reset_ref = true;
    } else {
        v->has_reset_ref = false;
    }
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetTracker(JNIEnv *env, jobject thiz, jlong handle,
                                                           jboolean on) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    bool want = (on == JNI_TRUE);
    if (want == v->tracker_on) return;
    v->tracker_on = want;
    /* xl_tracker_* 内部自带线程与 run 标志，可以从任意线程调用（上游也是在 GL 线程外调的）。 */
    if (want) {
        xl_tracker_start();
    } else {
        xl_tracker_stop();
    }
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetFlipV(JNIEnv *env, jobject thiz, jlong handle,
                                                         jboolean flip) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->flip_v = (flip == JNI_TRUE);
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetAxisSign(JNIEnv *env, jobject thiz, jlong handle,
                                                            jfloat yaw_sign, jfloat pitch_sign) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->yaw_sign = yaw_sign;
    v->pitch_sign = pitch_sign;
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeOnFrameAvailable(JNIEnv *env, jobject thiz,
                                                                 jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->new_frame = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeSetPassthrough(JNIEnv *env, jobject thiz,
                                                              jlong handle, jboolean on) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    v->req_passthrough = (on == JNI_TRUE);
    v->dirty = true;
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeMarkDirty(JNIEnv *env, jobject thiz, jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v != NULL) v->dirty = true;
}

JNIEXPORT jstring JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeDebugInfo(JNIEnv *env, jobject thiz, jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return (*env)->NewStringUTF(env, "no-native");
    char buf[512];
    snprintf(buf, sizeof(buf),
             "xl_player mesh=%.0f uv=[%.2f,%.2f]x[%.2f,%.2f] oes=%u surf=%dx%d video=%dx%d "
             "fovH=%.0f tracker=%s flipV=%s pass=%s frames=%ld skip=%ld%s%s",
             v->coverage, v->u0, v->u1, v->v0, v->v1, v->oes_texture, v->width, v->height,
             v->video_w, v->video_h, v->fovh_deg, v->tracker_on ? "on" : "off",
             v->flip_v ? "on" : "off", v->passthrough ? "on" : "off", v->frames, v->skipped,
             v->last_error[0] ? " err=" : "", v->last_error[0] ? v->last_error : "");
    return (*env)->NewStringUTF(env, buf);
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeStop(JNIEnv *env, jobject thiz, jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    if (v->running) {
        v->running = false;
        pthread_join(v->tid, NULL);
    }
}

JNIEXPORT void JNICALL
Java_com_example_piliplus_vr_VrGlPipeline_nativeDestroy(JNIEnv *env, jobject thiz, jlong handle) {
    xl_vr *v = (xl_vr *) (intptr_t) handle;
    if (v == NULL) return;
    if (v->running) {
        v->running = false;
        pthread_join(v->tid, NULL);
    }
    /* 让 Java 桥释放 SurfaceTexture / Surface（上游 SurfaceTextureBridge.release()） */
    if (v->bridge_class != NULL) {
        jmethodID release = (*env)->GetStaticMethodID(env, v->bridge_class, "release", "()V");
        if (release != NULL) (*env)->CallStaticVoidMethod(env, v->bridge_class, release);
        (*env)->DeleteGlobalRef(env, v->bridge_class);
    }
    if (v->video_surface_ref != NULL) (*env)->DeleteGlobalRef(env, v->video_surface_ref);
    if (v->out_surface_ref != NULL) (*env)->DeleteGlobalRef(env, v->out_surface_ref);
    if (v->out_window != NULL) ANativeWindow_release(v->out_window);
    if (v->ctx != NULL) xl_video_render_ctx_release(v->ctx);
    pthread_mutex_destroy(&v->lock);
    pthread_cond_destroy(&v->ready_cond);
    free(v);
}

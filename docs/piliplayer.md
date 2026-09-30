# piliplayer 分支说明

本分支（`piliplayer`）是工作分支，仓库默认分支已切到它。
`main` 分支被规则集 `lock-main-upstream-pr` + 经典分支保护（`enforce_admins`）双重锁定，
因为它是上游 PR [bggRGjQaUbCoE/PiliPlus#2977](https://github.com/bggRGjQaUbCoE/PiliPlus/pull/2977)
的 head 分支，任何直推都会被拒绝：

```
remote: - Changes must be made through a pull request.
 ! [remote rejected] main -> main (push declined due to repository rule violations)
```

改动默认分支不会影响该 PR（PR 的 head ref 固定为 `OrientCOMPASS:main`），
已验证：切换后 PR 仍为 open、head sha 未变。

版本按 0.0.1 步进：`2.1.4+1` → `2.1.5+1`。

本次新增两块能力：**本地板块**（本机 + 局域网视频播放）与 **VR/全景视频播放**。
两者都只针对 Android（其余平台不在本次 scope 内）。

---

## 1. 本地板块

### 入口

「我的」页面 → **本地视频**（路由 `/localMedia`）。

### 结构

```
lib/models/local_media/         来源、条目、排序模型
lib/services/local_media_service.dart  浏览/权限/播放地址拼接
lib/utils/local_media_progress.dart    播放进度记忆（仅本机）
lib/pages/local_media/          板块 UI（来源列表 → 目录浏览）
lib/pages/video/introduction/local_media/  播放页简介面板（同目录播放列表）
```

交互参照 VLC / OPlayer 安卓版：**来源列表 → 目录浏览 → 点文件播放**，
同目录的其他视频自动成为播放列表，支持上一个/下一个与列表循环。

### 来源类型与协议边界

| 来源 | 浏览 | 播放 | 说明 |
| --- | --- | --- | --- |
| 本机存储 | ✅ | ✅ | `dart:io` 直接列目录；自动发现主存储与 SD 卡/U 盘卷 |
| WebDAV | ✅ | ✅ | 复用仓库已有的 `webdav_client`（原本用于设置备份）浏览；播放交给 mpv 走 http(s) |
| HTTP/HTTPS 直链 | ❌ | ✅ | 直接播放 |
| FTP 直链 | ❌ | ✅ | 直接播放 |
| SMB / NFS | ❌ | ❌ | 见下方说明 |

协议边界不是随意定的，而是由**安卓端实际打包的 native 库**决定的。
`media_kit_libs_android_video` 下载的是
[My-Responsitories/libmpv-android-video-build](https://github.com/My-Responsitories/libmpv-android-video-build)
release `20260906` 的产物，其 FFmpeg 配置为 `--disable-protocols` + 白名单：

```
async cache crypto data ffrtmphttp file ftp hls http httpproxy https
pipe rtmp rtmps rtmpt rtmpts rtp subfile tcp tls srt
```

即 **file / http / https / ftp 可用，`smb` 与 `nfs` 没有编进库**，
所以 SMB/NFS 需要先重建 native 库（或引入 Dart 侧 SMB 客户端 + 本地 HTTP 代理）才能支持，
本次没有做，避免为了一个协议引入整条 native 构建链。

demuxer 白名单同理，因此 `LocalMediaExtensions.videos` 只列了确实能解封装的容器：
mp4/m4v/mov/3gp/3g2（mov）、mkv/webm（matroska）、avi、ts/m2ts/mts（mpegts）、
flv、mpg/mpeg/vob（mpegps）、wmv/asf（asf）、m3u8（hls）。
rmvb、ogv 之类即使显示出来也播不了，故不放进白名单。

### 凭据处理

WebDAV/FTP 的账号密码只保存在本机（Hive `setting` 盒子的 `localMediaSources`），
播放时以 URL userinfo 形式交给 mpv（`https://user:pass@host/path`），
应用内不实现认证逻辑、也不打印密码；界面上展示与复制到剪贴板的地址一律经过
`LocalMediaService.maskedUrl()` 脱敏。

### 权限

安卓 13+ 用 `READ_MEDIA_VIDEO`、12 及以下退回 `READ_EXTERNAL_STORAGE`，
两者都已在 `AndroidManifest.xml` 中声明（本次未改 manifest）。
未授权时不会崩溃，只提示"未获得存储读取权限"。

### 播放本地视频时禁用的在线行为

「不该发的消息不发」是硬性要求，实现上不是逐个关闭开关，而是**复用仓库既有的离线语义**：
`VideoDetailController.isFileSource` 在全仓 57 处被用作"离线播放"总开关，
本地媒体与离线缓存共用该语义（`SourceType.localMedia` 也会把 `isFileSource` 置为 true），
因此以下路径天然不会走到：

- 视频地址请求 `queryVideoUrl` / `_queryPlayInfo`（`if (isFileSource) return _initPlayerIfNeeded(...)`）
- 评论、相关视频、笔记、弹幕趋势图、同时在看人数
- 点赞 / 投币 / 收藏 / 分享 / 稍后再看（简介控制器全部空实现）
- SponsorBlock 分段拉取、 Stein-Edge 互动分支、离线缓存入口
- 进度预览图 `videoshot`

另外新增了两处显式闸门（防止将来有人改动调用顺序）：

- `PlPlayerController.isLocalMedia`：`makeHeartBeat()`（播放历史上报）与
  `getVideoShot()`（预览图）在本地媒体下直接返回，不发任何请求；
- `_initPlayer()` 中的 `player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl)`
  对本地媒体**不再设置**：本机文件用不到，局域网/NAS 的 HTTP 服务反而可能因非法 Referer 拒绝请求。

播放进度只写本机：`LocalMediaProgress` 复用 `watchProgress` 盒子，key 为
`local:<crc32(uri)>`，与 B 站 cid 命名空间隔离；看到结尾前 10 秒自动清除记录。

---

## 2. VR / 全景视频

### 方案选型（为什么是着色器）

先量化再决策，三条候选路径的实测/核查结果：

| 方案 | 投影位置 | 安卓可用性 | 结论 |
| --- | --- | --- | --- |
| A. FFmpeg `v360` 滤镜 + `vf-command` 运行时改 yaw/pitch/fov | CPU（SIMD、slice-threaded） | ❌ 不可用 | 打包的 FFmpeg 是 `--disable-filters` + 白名单，只有 overlay/equalizer/aresample/dynaudnorm/loudnorm/alimiter，**没有 v360**，也没有 `buffer`/`buffersink`，因此 `--vf=lavfi=[v360=...]` 这条路整体不通；且 `-Dlua=disabled`，无法用 Lua 脚本兜底 |
| B. 原生 media3/ExoPlayer `SphericalGLSurfaceView` | GPU（GLES 球面网格） | ✅ 可用 | 性能最高，但要引入第二套播放栈（PlatformView + ExoPlayer + 独立的进度/倍速/字幕/音轨控制），丢掉弹幕、字幕、手势、截图、画中画等既有能力，且无法在无设备环境下验证，风险与维护成本都过高 |
| C. mpv 用户 GLSL 着色器（`vo=gpu`） | GPU（单次 fullscreen pass） | ✅ 可用 | **采用**：直接在硬解纹理上采样，零拷贝，pass 输出尺寸被限制为屏幕分辨率，与片源是 4K/8K 无关 |

方案 C 的可行性有仓库内的既有证据：`assets/shaders/Anime4K_*.glsl`（超分辨率）
用的就是同一套机制 `//!HOOK MAIN` + `//!WIDTH OUTPUT.w` + `//!HEIGHT OUTPUT.h`，
并且是通过 `change-list glsl-shaders set <path>` 加载的——本项目 mpv 构建上已验证可用。
安卓端 media_kit 固定使用 `--vo=gpu` + `opengl-es=yes`
（`media_kit_video/lib/src/video_controller/android_video_controller/real.dart`），
`vo=gpu` 支持用户着色器。

### 参数下发方式（本次唯一的妥协点）

mpv 的用户着色器 `//!PARAM` + `--glsl-shader-opts` 才是"改参不重编译"的正解，
但核查版本后确认**当前构建不支持**：

- 打包版本为 mpv `v0.41.0` + libplacebo `7.360.1`；
- `v0.41.0` 的 `video/out/gpu/user_shaders.c` 里没有任何 `PARAM` 解析，
  `video.c` 里也没有 `gl_sc_uniform_f_bstr`（PARAM → uniform 的注入点）；
  这些是 mpv master（0.41 之后）才补进 `vo=gpu` 的，`v0.41.0` 只有 `vo=gpu-next` 支持；
- 而安卓端用的是 `vo=gpu`，不是 `gpu-next`。

因此本次实现把 yaw/pitch/fov **烘焙成 `#define`** 写进着色器源码，
视角变化时重写文件并 `change-list glsl-shaders set`。
`glsl-shaders` 属于 VO 私有选项，改它触发的是 `VOCTRL_UPDATE_RENDER_OPTS`（重建渲染链），
不会重建 VO/Surface；再叠加以下措施把开销压到可接受：

1. **量化**：yaw/pitch 步长 0.2°、fov 步长 0.25°，源码不变就不重写、不下发命令；
2. **节流**：拖拽期间最多 ~22 次/秒（`vrApplyIntervalMs = 45`），手势结束时
   `applyVrView(force: true)` 强制落一次，保证最终视角与手指位置一致；
3. **着色器极小**（单 hook、单 pass、无循环），编译成本低；相同源码可命中 mpv 的程序缓存。

升级路径已经留好：等 mpv 升到支持 `vo=gpu` PARAM 的版本，只需把
`VrShader.source()` 里的 `#define` 换成 `//!PARAM` 块、把 `_applyVrShader()`
里的重载换成 `setProperty('glsl-shader-opts', ...)`，其余代码不动。

### 投影实现

`lib/plugin/pl_player/utils/vr_shader.dart` 生成 GLSL：

- 等距柱状（equirectangular）→ 矩形（rectilinear）投影，
  逐像素 `atan/asin` 求经纬度后采样，360° 片源水平方向用 `fract()` 无缝回绕；
- 宽高比取 `target_size`（mpv 提供的 dst rect 尺寸），因此全屏/半屏、
  画面比例(fit)切换、窗口尺寸变化都会自动跟随，不会拉伸变形；
- 支持 360°/180° 覆盖，双目片源（左右 SBS、上下 TB）只取一只眼睛（左/右可切）；
- 180° 片源的偏航角按 `±(coverageH - fov)/2` 收敛，避免转出画面出现黑边。

自动识别只认文件名里的明确关键词（`360`/`vr`/`equirect`/`panoram`/`全景`/`sbs`/`tb`/`180` 等），
**不看宽高比**——2:1 也可能是普通宽银幕视频，误判会直接把正常视频弄花。
可在「设置 → 播放设置 → VR/全景自动识别」关闭；播放中随时可在播放器设置面板手动切换。

### 操作

| 操作 | 行为 |
| --- | --- |
| 单指拖拽 | 环视（水平偏航 / 垂直俯仰） |
| 双指缩放 | 调整水平视场角（25°~120°） |
| 播放器设置面板 → VR/全景 | 切换片源布局（关闭 / 360 / 180 / 左右 / 上下） |
| 播放器设置面板 → VR 眼位 | 双目片源选左眼或右眼 |
| 播放器设置面板 → VR 重置视角 | 视角摆正 |

VR 模式下单指拖拽不再触发进退、亮度、音量、全屏手势（这些手势在环视时会互相干扰），
双击暂停、进度条、倍速、字幕、弹幕等其余能力保持不变。
VR 与超分辨率（Anime4K）都占用 `glsl-shaders`，不能同时生效，**VR 优先**；
退出 VR 会调用 `setShader()` 恢复用户原本的超分辨率设置（不会改写该偏好）。

### 尚未做的部分

- **陀螺仪/头部追踪**：需要新增 `sensors_plus` 依赖，且轴向映射无法在无设备环境下验证，
  本次未做（拖拽环视已可完整使用）；
- **立体输出（真正的 VR 头显模式）**：目前只输出单眼画面，适合手机/平板裸屏观看；
- 立方体贴图（cubemap）片源。

---

## 3. CI

开发沙盒只有 2 vCPU / 1 GiB 内存，无法构建 Flutter 应用（本地 analyze 也会 OOM），
所以一切验证都在 GitHub Actions 上跑：`.github/workflows/piliplayer_ci.yml`。

- 触发：push 到 `piliplayer`、面向 `piliplayer` 的 PR、手动 dispatch；
- 步骤与仓库既有 `build.yml` 对齐（Flutter 版本取自 `pubspec.yaml`，
  构建前执行 `lib/scripts/patch.ps1 android` 给 Flutter SDK 与 material_ui/cupertino_ui 打补丁）；
- `check` 作业：`flutter analyze`（仓库基线有 37 条 info、0 error，故只把 **error** 视为失败）
  → 对本分支新增路径再做一次 `dart analyze --fatal-infos` **零容忍**检查 → `flutter test`；
- `build_android` 作业：`flutter build apk --debug --target-platform android-arm64`
  并上传产物，方便直接装机验证；手动 dispatch 时可切 `release`。

`STRICT_PATHS`（workflow 的 env）列出了本分支新增的目录/文件，新增代码请一并加进去。

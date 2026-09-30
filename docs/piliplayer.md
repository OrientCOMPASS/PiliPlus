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
| SMB/CIFS | ✅ | ✅ | **内置纯 Dart SMB2 客户端**浏览; 播放走本机回环 HTTP 代理 |
| NFS | ❌ | ❌ | 见下方说明 |

SMB 是个例外: 打包的 FFmpeg 同样没有 `smb` 协议, 但 SMB 的**客户端协议**可以
在 Dart 侧实现, 再用本机回环 HTTP 代理喂给 mpv, 因此不依赖重建 native 库
(实现与验证方式见下文「SMB 支持」)。

其余协议边界不是随意定的，而是由**安卓端实际打包的 native 库**决定的。
`media_kit_libs_android_video` 下载的是
[My-Responsitories/libmpv-android-video-build](https://github.com/My-Responsitories/libmpv-android-video-build)
release `20260906` 的产物，其 FFmpeg 配置为 `--disable-protocols` + 白名单：

```
async cache crypto data ffrtmphttp file ftp hls http httpproxy https
pipe rtmp rtmps rtmpt rtmpts rtp subfile tcp tls srt
```

即 **file / http / https / ftp 可用，`smb` 与 `nfs` 没有编进库**。
NFS 要支持就得重建 native 库或再写一套 RPC 客户端, 本次没有做。

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

### 操作: 显式的「VR 操作模式」切换

第一版把 VR 手势直接插进播放器原有手势里, 结果**双指缩放被 PiliPlus 自身的
「画面缩放」手势占用**(视频层是 `MouseInteractiveViewer`, 它自己要吃掉 pinch),
于是采纳 [PiliPlus#364](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/364)
提出的"切换操作模式"方案(与 xl_player 的做法一致):

- 选定片源布局后自动进入 **VR 操作模式**; 此时 `MouseInteractiveViewer`
  **不在控件树里**, 由 `VrControlLayer` 独占手势, 不存在争抢。
- VR 操作模式下的输入:

| 操作 | 行为 |
| --- | --- |
| 单指拖拽 | 环视（水平偏航 / 垂直俯仰） |
| 双指缩放 | 调整水平视场角（25°~120°） |
| 屏幕方向键 ◀ ▶ ▲ ▼ | 每次 10° 步进，**长按连续转动**（110ms/次） |
| 屏幕 🔍± | 视场角每次 8° |
| 屏幕「视角摆正」 | 回到 yaw=pitch=0 |
| 屏幕「切换眼位」 | 双目片源切左/右眼 |
| 顶部提示条 | 实时显示 `偏航 / 俯仰 / 视场` 读数，点一下退出 VR 操作模式 |
| 单击画面 | 显示/隐藏控制栏 |

- 退出 VR 操作模式后, 常规手势(左右进退、上下亮度/音量、上下滑全屏、
  双指缩放画面)立刻恢复; 需要进退/调音量时先退出即可, 不必关闭全景投影。
- 入口有三处: 自动识别(本地媒体) / 控制栏上的「VR 操作」按钮 /
  播放器设置面板里的「VR/全景」「VR 操作模式」。
- VR 与超分辨率(Anime4K)都占用 `glsl-shaders`, 不能同时生效, **VR 优先**;
  退出 VR 会调用 `setShader()` 恢复用户原本的超分辨率设置(不会改写该偏好)。

顺带修掉一个真 bug: `PlPlayerController` 是单例, 切集/换视频时播放器**不会重建**,
而着色器下发原本只写在"新建播放器"分支里 —— 于是自动识别出的 VR 从来没生效过。
现在每次装载新源都会重新下发。

### 尚未做的部分

- **陀螺仪/头部追踪**（xl_player 用的是 Cardboard 那套 EKF HeadTracker）：
  需要新增 `sensors_plus` 依赖，且轴向映射无法在无设备环境下验证，本次未做；
  目前拖拽 + 屏幕按钮已可完整操作视角。
- **立体输出（真正的 VR 头显模式，左右分屏）**：目前只输出单眼画面，
  适合手机/平板裸屏观看；
- 立方体贴图（cubemap）片源。

---

## 4. 顶层板块与媒体库（第二轮）

### 导航栏：首页 / 动态 / 本地 / 我的

`NavigationBarType` 里新增 `local`。**枚举值追加在末尾**而不是插到 `mine` 之前：
`navBarSort` 存的是枚举下标，插在中间会让老用户的配置整体错位（把「我的」变成「本地」）。
默认展示顺序由 `MainController.kDefaultNavBars` 决定，并对老配置做**一次性迁移**
（把「本地」插到「我的」前面，用 `navBarSortMigratedLocal` 标记避免重复执行）。
「设置 → Navbar编辑」里也能自由增删/排序（`defaultBars` 传的是 `values`，自动包含「本地」）。

### 媒体库：扫描 + 按文件夹排列

参照 VLC 安卓版的组织方式，「本地」页分两个 Tab：

- **媒体库**：递归扫描所有存储卷，**按文件夹归组**展示（文件夹名 / 视频数 / 总大小 /
  最近修改 / 路径），点进文件夹就是该目录的播放列表；顶部另有各存储卷入口，可直接逐层浏览。
  - 扫描跳过 `Android/`、`LOST.DIR`、`.thumbnails` 等目录与所有隐藏目录；
  - 有 `maxFiles=20000` / `maxFolders=4000` 上限，超大存储卡不会拖死 UI；
  - 结果缓存在本机（`localMediaLibrary`），下次进入立即可见，再手动重扫；
  - 首次进入且无缓存时自动扫一次。
- **网络**：自动发现的 SMB 主机 + 已保存的共享（SMB/WebDAV/HTTP/FTP）。

目录浏览页（`browser.dart`）是自成一体的 `StatefulWidget`：逐层进入、`..` 回退、
返回键逐层退出、排序/隐藏文件切换、长按看详情与复制地址（脱敏）、清除续播进度。

### 倍速：开放 4x / 8x

默认档位改为 `[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4, 8]`。
自定义过档位的老用户不会被覆盖，因此加了**一次性迁移**（`speedsListMigrated4x8x`）
把 4.0/8.0 补进已保存的列表；「倍速设置 → 重置」也能回到新默认值。
`setPlaybackSpeed` 本身不做上限裁剪，直接交给 mpv 的 `setRate`。

### 本地视频续播进度

原来只在 `onClose` / `onReset` 时保存，进程被杀、后台回收、或播放器先于页面控制器
销毁时都会丢进度。现在改为：

- **播放中每 5 秒落盘一次**（挂在 `PlPlayerController.addPositionListener` 上，
  该回调本身就是每秒一次，再做 5 秒节流）；
- 关闭页面 / 切换条目时再补一次；播放器已销毁取不到位置时不会把进度覆盖成 0；
- 只写本机（`watchProgress` 盒子，key = `local:<crc32(uri)>`），**不上报 B 站**；
- 看到结尾前 10 秒视为看完，自动清除记录；
- 列表页/简介面板从播放页返回后即时刷新「看到 xx:xx」。

---

## 5. SMB 支持（自动发现 + 浏览 + 播放）

### 为什么自己实现协议

安卓端打包的 FFmpeg 没有 `smb` 协议，mpv 打不开 `smb://`；VLC 之所以能播，
是因为它在 native 层带了 libsmb2/libdsm。要么重建 native 库、打包 .so，
要么在 Dart 侧实现协议 —— 选后者：不引入 native 构建链，且**可以在沙盒里对真实
smbd 联调**（这一点是决定性的，见下文验证方式）。

### 组成（`lib/services/smb/`，纯 Dart，不依赖 Flutter）

| 文件 | 内容 |
| --- | --- |
| `md4.dart` | MD4(RFC 1320)。`package:crypto` 没有 MD4，而 NTOWFv1 必须用它 |
| `ntlm.dart` | NTLMSSP Type1/2/3、NTLMv2（NTOWFv2 / NTProofStr / SessionBaseKey / LMv2）、**SPNEGO 封装**（negTokenInit / negTokenResp） |
| `smb2_client.dart` | SMB2 客户端：方言 0x0202/0x0210、HMAC-SHA256 签名、**信用记账**、NEGOTIATE / SESSION_SETUP / TREE_CONNECT / CREATE / QUERY_DIRECTORY(FileIdBothDirectoryInformation) / READ / CLOSE / ECHO / LOGOFF |
| `smb_browse.dart` | 目录浏览、路径规范化、稳定 URI（不含凭据）、代理注册地址 |
| `local_media_proxy.dart` | 本机回环 HTTP 代理（Range/206），把 SMB 文件喂给 mpv |
| `smb_discovery.dart` | 局域网主机发现：IPv4 /24 网段 TCP 445 并发扫描 + NetBIOS NBSTAT 主机名解析 |

范围之外（明确不做）：写入、oplock/lease、多通道、SMB3 加密、DFS、共享枚举（SRVSVC RPC）。
方言只协商 2.0.2/2.1：SMB3 的签名要 AES-CMAC、加密要 AES-CTR，Dart 侧没有现成 AES，
而家用 NAS/Windows 默认都还接受 SMB2.1（Samba 的 `server min protocol` 默认更低）。

### 播放路径

```
mpv  --(http, Range)-->  127.0.0.1:<随机端口>/s/<token>  --(SMB2 READ)-->  NAS
```

代理只监听 loopback、token 不可枚举、不提供目录列表、只能访问显式注册过的对象；
支持 `Range`（206 + Content-Range + Accept-Ranges），所以 mpv 的 seek / 缓冲 /
硬件解码全部照常工作，且视频流量不出本机。

### 验证方式（关键：不是"看起来对"，而是对着真实服务端跑过）

沙盒里装了 **Samba 4.17 + Dart SDK 3.13**，脚本 `~/.ci/smb_testbed.sh` 会拉起一个
真实 smbd（共享 `pub`(guest) / `priv`(需认证)，含中文目录名与 3MB 文件），然后：

1. **抓包对比**：`tcpdump` 抓 `smbclient`（已知可用）的请求，与我的实现逐字段对比；
2. **联调脚本**：连接/认证/列目录/读文件/Range 流式读/错误路径，全部跑通；
3. **强制签名模式**：`server signing = required` 下重跑，验证 HMAC-SHA256 签名实现；
4. **端到端**：通过代理 `GET` 全量与 `Range` 取回，与源文件**逐字节比对一致**；
5. **单元测试**（进 CI）：MD4 的 RFC 1320 向量 + Python 独立实现交叉验证的分块边界、
   NTLMv2 的 MS-NLMP 4.2.4 向量、SPNEGO 往返、**真实抓包的 Type2/negTokenResp 原文**
   解析回归、Type3 字段偏移与 MIC、目录项链表解析（中文名）、FILETIME、
   路径/URI/Range 解析；
6. **联调测试**（`smb_live_test.dart`）：有 `SMB_TEST_HOST` 才跑，CI 上自动跳过。

这条路径抓到了 6 个"只看代码/只靠 CI 永远发现不了"的问题：

| 问题 | 症状 | 定位手段 |
| --- | --- | --- |
| 安全缓冲区没做 SPNEGO 封装 | SESSION_SETUP 被拒 | tcpdump 对比 smbclient |
| `MORE_PROCESSING_REQUIRED` 常量记错（写成 0xC0000001，实际 0xC0000016） | 把握手中间态当成失败 | 对照响应头字节 |
| Type3 的 SESSION_SETUP 被签名 | 服务端"没有签名密钥"，直接断连 | smbd 日志 |
| CREATE 空名（共享根目录）/ READ 的 body 少 1 字节 buffer | `STATUS_INVALID_PARAMETER` | 抓包对比 body 长度 |
| MessageId 未按 CreditCharge 递增 | `bad message_id 8 (low = 15)` | smbd 日志 |
| 大块 READ 超发信用 | `client used more credits than granted` | smbd 日志 |

另外还修了两个只有真实数据才会暴露的问题：`Uri.pathSegments` 已解码，
再 `decodeComponent` 遇到字面量 `%` 会抛异常；socket 的异步写错误若无人接收，
会变成未捕获异常直接崩掉 isolate（已改为显式订阅 + `onError`）。

---

## 6. CI

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

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

> **第三轮的结论是错的，已在第四轮推翻**（见 9.1）：当时以为"两个槽位轮流写"
> 就能让 mpv 重读文件。实际上 `vo=gpu` 是**按路径永久缓存文件内容**
> （`gpu/video.c: load_cached_file()`），两个槽位各自只在第一次被读走，
> 之后无论怎么改写都无效 —— 画面停在 VR 初始化那一刻，而每 45ms 一次的
> `change-list` 还在空转重建整条渲染管线（这就是"变卡顿"）。
> 现在的做法是**一份源码一个文件、只写一次**，Dart 侧维护「源码 → 路径」映射。
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

- 选定片源布局后自动进入 **VR 操作模式**。
  > 第三轮真机教训: 第一版以为"把 `VrControlLayer` 套在外面就独占手势了",
  > 实际上底层 `MouseInteractiveViewer` 仍是它的 child, 命中测试还会路过其
  > `Listener`, 底层识别器(touch slop 只有 4px)在竞技场里抢先获胜 ——
  > 单指拖拽依旧是进度/音量/亮度。现在 `_onPointerDown` 在 VR 模式下
  > **不再把指针喂给任何底层识别器**, 竞技场里只剩 VR 层, 手势才真正独占。
- VR 操作模式下的输入:

| 操作 | 行为 |
| --- | --- |
| 单指拖拽 | 环视（水平偏航 / 垂直俯仰） |
| 双指缩放 | 调整水平视场角（25°~120°） |
| 屏幕方向键 ◀ ▶ ▲ ▼ | 每次 10° 步进，**长按连续转动**（110ms/次） |
| 屏幕 🔍± | 视场角每次 8° |
| 屏幕「视角摆正」 | 回到 yaw=pitch=0 |
| 屏幕「切换眼位」 | 双目片源切左/右眼 |
| 屏幕「陀螺仪」 | 开关陀螺仪环视（转动设备看四周，参考 xl_player 头追） |
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

### 陀螺仪环视（第三轮新增）

参考 xl_player 的头部追踪，用 `sensors_plus` 实现：

- 陀螺仪 50Hz 采样积分出偏航/俯仰增量，加速度计（重力）判定持握姿态
  （竖屏 / 横屏顶左 / 横屏顶右 / 倒置），四个姿态的轴向映射各自推导并单测
  （`vr_gyro_math.dart` 纯数学，零依赖）；
- 死区（0.03 rad/s）+ 低通滤波抑制静止漂移；不做重滤波，保证头动跟手；
- 随「VR 操作模式」自动启停（默认值在 设置 → 播放设置 → VR 陀螺仪视角），
  播放中可用控制层右侧按钮或设置面板随时开关；
- 与拖拽/按钮共用同一个 `vrView`，量化(0.2°)后没变化不会打扰着色器。

已知限制：纯陀螺仪积分存在慢速漂移（无磁力计/旋转矢量校正），
长时间观看后视角可能缓慢偏转，用「视角摆正」即可复位。

### 尚未做的部分

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
| `dcerpc.dart` | 最小 DCERPC(MS-RPCE) 封帧/解析 + NDR32 读写器（bind / request / response / fault） |
| `srvsvc.dart` | **SRVSVC NetShareEnum：共享自动枚举**（`\\host\IPC$` → `\srvsvc` 管道 → RPC），与 VLC/资源管理器同款做法 |
| `smb_name.dart` | 主机名解析：IP 直通 → 系统 DNS → **NBNS 广播查询(UDP 137)** → 发现阶段记录的 IP 兜底，结果缓存 60s |

范围之外（明确不做）：写入、oplock/lease、多通道、SMB3 加密、DFS。
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
   路径/URI/Range 解析、**SRVSVC NetShareEnum 的 NDR 请求/响应编解码**；
6. **联调测试**（`smb_live_test.dart` / `smb_share_enum_test.dart`）：有
   `SMB_TEST_HOST` 才跑，CI 上自动跳过。共享枚举对真实 smbd 验证过匿名/认证
   两条路径，并覆盖"枚举出来的共享直接能浏览"的端到端链路。

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

- 触发：push 到 `piliplayer`、push `v*` tag、面向 `piliplayer` 的 PR、手动 dispatch；
- 步骤与仓库既有 `build.yml` 对齐（Flutter 版本取自 `pubspec.yaml`，
  构建前执行 `lib/scripts/patch.ps1 android` 给 Flutter SDK 与 material_ui/cupertino_ui 打补丁）；
- `check` 作业：`flutter analyze`（仓库基线有 37 条 info、0 error，故只把 **error** 视为失败）
  → 对本分支新增路径再做一次 `dart analyze --fatal-infos` **零容忍**检查 → `flutter test`；
- `build_android` 作业（矩阵）：分支 push 只建 debug（`--target-platform android-arm64`）；
  手动 dispatch 可切模式；**推 `v*` tag 时 debug + release 双模式都建**，
  产物均上传为 workflow artifact（14 天有效）。

### 6.1 tag → GitHub Release

推一个 `v*` tag（如 `v2.1.5-test.1`）即可发布测试版本：

1. `build_android` 每条腿构建完成后，用 `gh release upload --clobber` 把
   **全部 APK + `PiliPlayer-<tag>-<mode>-SHA256SUMS.txt`** 传到该 tag 对应的 Release；
2. Release 不存在时 CI 会兜底创建一个 **prerelease**（正常流程是打 tag 后手动建好
   Release、写清 changelog，CI 只负责传包）；
3. release 腿沿用上游参数：`--split-per-abi --android-project-arg dev=1`，
   即包名带 `.dev` 后缀（可与正式版共存）、按 ABI 拆分；
   仓库没有 `android/key.properties` 时自动回落 debug 签名，装机测试没问题，
   但要上商店需自行配置签名。

`STRICT_PATHS`（workflow 的 env）列出了本分支新增的目录/文件，新增代码请一并加进去。

---

## 7. 真机验证记录

CI 产出的 debug 包装机后（Lenovo TB-J706F / Android 12）暴露的问题，这些是纯静态
检查和沙盒里都发现不了的，记录在这里避免重复踩。

### 7.1 「本地」板块整页空白：`SimpleScaffold` 撑不住带 `bottom` 的 `AppBar`

现象：点进「本地」板块整页是空的，日志里刷一屏
`RenderBox was not laid out` 加一条根因：

```
RenderFlex children have non-zero flex but incoming height constraints are unbounded.
...
#4  _RenderScaffoldLayout.performLayout (common/widgets/scaffold/simple_scaffold.dart:88)
```

原因链：

1. `SimpleScaffold` 是自绘的槽位布局（`lib/common/widgets/scaffold/simple_scaffold.dart`），
   它用 `BoxConstraints.tightFor(width: ...)` 测量 `appBar` 槽位 —— **高度是无界的**；
2. Flutter 自带的 `Scaffold` 之所以没这个问题，是因为它会先调
   `AppBar.preferredHeightFor()` 把 appBar 槽位夹成 `ConstrainedBox(maxHeight: ...)`；
   `SimpleScaffold` 没有这一步；
3. 不带 `bottom` 的 `AppBar` 恰好能自适应高度，所以仓库里 70 多处
   `SimpleScaffold(appBar: AppBar(...))` 一直是好的；
4. 但带 `bottom`（TabBar）的 `AppBar` 内部是
   `Column(mainAxisSize: max, mainAxisAlignment: spaceBetween)` 里套 `Flexible`，
   高度无界时直接抛断言 → 整棵子树布局失败 → 页面空白。

修法：「本地」板块改用真正的 `Scaffold`，与 `lib/pages/dynamics/view.dart`
（同样是顶层 Tab）保持一致：

```dart
Scaffold(
  primary: false,                  // MainApp 已统一加过状态栏内边距，AppBar 再加会多一条空白
  resizeToAvoidBottomInset: false,
  backgroundColor: Colors.transparent,
  appBar: AppBar(primary: false, bottom: TabBar(...)),
  ...
)
```

> 约定：**顶层 Tab 页不要往 `SimpleScaffold` 里塞带 `bottom` 的 `AppBar`**。
> 没有改 `SimpleScaffold` 本身，因为它被 80 多处复用，而
> `MultiSelectAppBarWidget.preferredSize` 直接透传 `AppBar.preferredSize`
> （不含状态栏高度），在那里加高度夹取会把「下载/历史」等页的标题栏裁掉一截。

### 7.2 首扫时界面像卡死：Rx 通知没有节流

全盘递归扫描动辄上万个文件，原来每发现一个文件就 `scannedFiles.value++`，
等于触发同样多次 `Obx` 重建（整张 `ListView` 重建）。已改为内部普通 `int` 计数 +
300 ms 定时器批量推送进度、1.2 s 发布一次阶段性文件夹列表，
并加了 `_abort` 标志让板块销毁时（`LocalMediaController.onClose`）能尽快停下扫描。

### 7.3 顶层 Tab 页的控制器要用 `Get.putOrFind`

原来写的是字段初始化里的 `Get.put(LocalMediaController())`：顶层 Tab 页会被
`MainApp` 的 `TabBarView` 反复重建，`put` 每次都把控制器连同扫描结果整个换掉。
已改为 `Get.putOrFind(LocalMediaController.new)` + `AutomaticKeepAliveClientMixin`，
与 `HomePage` / `DynamicsPage` / `MinePage` 的写法一致。

### 7.4 CI 构建的包现在自报 commit

`piliplayer_ci.yml` 的构建步骤补上了 `--dart-define=pili.hash/pili.time/pili.code`，
装机后在「关于」页能看到 Commit Hash 和构建时间，不用再猜手上这个 apk 是哪次提交。

---

## 8. 第三轮真机反馈修复（v2.1.5-test.1 重新构建）

第二轮装机（Lenovo TB-J706F / Android 12）反馈了三类问题，全部修复并回归：

### 8.1 手动填共享名报 `OBJECT_NAME_NOT_FOUND`

真凶不在协议层，而是 `LocalMediaSource.rootPath`：对 SMB 源它返回 `/共享名`，
浏览器打开后把它当作**共享内**路径再列一层 —— 相当于去找
`\\host\pub\pub`，必然 `OBJECT_NAME_NOT_FOUND`（"测试连接"用的是
`ep.path`（空）所以能通过，一打开就炸）。现在 SMB 的 `rootPath` 只返回
共享内相对路径，并加了回归测试（`test/services/local_media_source_test.dart`）。

### 8.2 SMB：共享自动枚举 + 尽量用主机名（对齐 VLC 行为）

- **不再需要手填共享名**：点发现的主机 → SRVSVC `NetShareEnum` 自动列出共享
  → 选一个即保存并打开；匿名被拒时弹凭据框重试一次；RPC 被禁用的服务端
  自动退回手动输入。列表只展示可浏览的磁盘共享（过滤 `IPC$`/`ADMIN$`/打印队列，
  与 VLC/资源管理器一致）。
- **opnum 兼容性考据**（踩坑记录）：Windows(MS-SRVS) 与 Samba 的 srvsvc
  方法编号表**不同** —— Samba 自家 IDL 里 `NetShareEnum=0x24(36)`、
  `NetShareEnumAll=0x0f(15)`；Windows 的 `NetrShareEnum=15`。两者在
  **opnum 15 上签名完全同构**，所以统一用 15（libsmb2/VLC 同款选择），
  对 Samba 实际打到的是 NetShareEnumAll，行为一致。
- **NDR 布局逐字节对齐真实抓包**：`tcpdump` 抓 `rpcclient -N netshareenum`
  与自研实现对比，抓出两个必错点：union 判别式在 `level` 之后**还要再发一次**；
  `TotalEntries` 是 `[out,ref]`（内联 4 字节占位），不是 unique 指针。
  bind_ack 的 `p_results` 前面还有 `n_results+reserved(4)` 也需要跳过。
- **主机名优先**：服务端权威名字取自 NTLM CHALLENGE 的 AV_PAIR
  （MsvAvDnsComputerName / MsvAvNbComputerName，比 NBSTAT 猜测可靠），
  保存的 URL 写成 `smb://<主机名>/<共享>`；连接时按
  IP 直通 → DNS → **NBNS 广播查询** → 发现阶段记录的 IP（存在来源的
  `address` 字段）四级解析，即使路由器拦广播也不会失联。
- 错误翻译同步更新：tree connect 收到 `OBJECT_NAME_NOT_FOUND`/`BAD_NETWORK_NAME`
  统一提示"共享不存在或无权访问"，并指路自动枚举。

### 8.3 VR：手势独占、着色器重载、拖拽方向

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| 切到 VR 操作模式后单指拖拽仍是进度/音量/亮度 | 底层 `MouseInteractiveViewer` 还在树里，其 `Listener.onPointerDown` 照常把指针喂给底层识别器（slop 4px），在竞技场里抢先获胜 | `_onPointerDown` 在 `vrControlMode` 下直接 return，底层识别器不进竞技场，手势由 `VrControlLayer` 独占 |
| 方向按钮读数在变、画面不动；播放中切展开格式不生效 | 每次都写同一文件并 `change-list glsl-shaders set <同一路径>`，选项值未变 → mpv 不触发 opts-change → 不重读文件 | 双槽位文件名交替（`piliplus_vr_a/b.glsl`），每次 set 的值必然变化。**该修法在第四轮被证明无效**：mpv 按路径永久缓存文件内容，两个槽位各自只被读一次；正确做法见 9.1 |
| （顺手修）拖拽俯仰方向与"画面跟手"约定相反 | `pitch -= dy` 写反 | 改为 `pitch += dy`，与偏航的"画面跟手"约定一致 |

### 8.4 本地媒体播放页崩溃（`LocalIntroController not found`）

横屏宽布局的右侧 TabBarView 只判断了 `isFileSource`（对 localMedia 也为 true），
无条件构建 `LocalIntroPanel`，而本地媒体注册的是 `LocalMediaIntroController`
→ `Get.find` 抛错 → 错误组件(RenderErrorBox)被塞进 sliver 槽位，连带
`'RenderErrorBox' is not a subtype of 'RenderSliver?'`。已按 `isLocalMedia`
分流到 `localMediaIntroPanel()`。

### 8.5 本轮新增/更新的验证

- `test/services/smb/smb_share_enum_test.dart`：NDR 编解码离线用例 + 对真实
  smbd 的匿名/认证枚举联调（沙盒 11/11 通过）；
- `test/services/local_media_source_test.dart`：rootPath / address 序列化回归；
- `test/plugin/vr_test.dart`：新增槽位命名与陀螺仪轴向映射/姿态判定用例
  （陀螺仪纯数学在沙盒用 dart:test 先行验证 7/7）。

---

## 9. 第四轮真机反馈修复（v2.1.6-test.1）

第三轮的包（Lenovo TB-J706F / Android 12）反馈了三类问题：VR 变卡且切展开格式不生效、
连接远程主机的交互不对、打开播放器三点菜单崩溃。逐条给出根因与修法。

### 9.1 VR：为什么"读数在变、画面不变"，以及和 xl_player 的管线差异

先把 mpv v0.41.0 的源码读了一遍（`video/out/gpu/video.c`、`user_shaders.c`、
`shader_cache.c`、`player/command.c`、`options/m_option.c`），三条事实决定了这个方案的上限：

| 事实 | 源码位置 | 后果 |
| --- | --- | --- |
| 用户着色器的**文件内容按路径永久缓存** | `gpu/video.c: load_cached_file()` —— `p->files[]` 只增不减，`strcmp(path)` 命中就直接返回**第一次读到的内容**，直到 `gl_video` 销毁 | 反复改写同一个文件再 `change-list glsl-shaders set <同一路径>`，mpv 永远看不到新内容 |
| 改 `glsl-shaders` 会**重建整条渲染管线** | `gl_video_render_frame()` 开头调 `gl_video_update_options()` → `m_config_cache_update()` 发现选项变了 → `reinit_from_options()` → `uninit_rendering()` + `gl_video_setup_hooks()` + 重新解析着色器 | 每次下发都是"拆掉再搭一遍"，源码变了还要真的编译一次 GLSL |
| `vo=gpu` 的用户着色器**不支持 `//!PARAM`** | `user_shaders.c` 只解析 HOOK/BIND/SAVE/DESC/OFFSET/WIDTH/HEIGHT/WHEN/COMPONENTS/TEXTURE/SIZE/FORMAT/FILTER/BORDER；`glsl-shader-opts`（`gpu/video.c:548`）声明了但 `vo=gpu` 根本不读，只有 `vo_gpu_next.c: update_hook_opts()` 会把它灌进 hook 的 param | 参数只能以 `#define` 烘焙进源码，"改参数"就等于"换源码" |

于是第三轮那个"两个槽位轮流写"的修法是**错的**：`piliplus_vr_a.glsl` /
`piliplus_vr_b.glsl` 各自在第一次被 mpv 读走之后内容就冻结了，之后再怎么写都无效。
真机现象因此完全对得上：

- 读数在变（Dart 侧的 `vrView` 确实在动）；
- 画面停在 VR 初始化那一刻（mpv 拿到的还是那两个文件的旧内容）；
- **变卡顿**：选项值每 45ms 变一次 → 每秒 22 次 `reinit_from_options()`，
  拆建整条渲染管线，却一点画面变化都没有 —— 纯亏。

另外补一个只有 SMB 才会踩的坑：VR 自动识别原来拿 `dataSource.videoSource`
去猜文件名，而 SMB 播放走本机回环代理（`http://127.0.0.1:<port>/s/<token>`），
地址里根本没有原文件名，`360`/`sbs`/`tb` 全丢，自动识别必然失效。
`setDataSource` 新增 `mediaName` 参数，本地媒体传条目名。

#### 与 xl_player 的管线对比（用户问的重点）

[xl_player](https://github.com/xl-player-developers/xl_player) 是**自研 native 播放器**：
ffmpeg 解封装 + MediaCodec 硬解（`xl_decoders/xl_mediacodec.c`）→ 输出到
SurfaceTexture/OES 纹理 → **自己的 GLES 渲染器**把纹理贴到球面网格上 →
`xl_head_tracker/`（`HeadTracker.cpp` + `OrientationEKF.cpp` + `SO3Util.cpp`，
就是 Cardboard 那套 EKF 姿态估计）每帧算出一个旋转矩阵。

关键差别只有一句：**它的投影参数是 per-frame uniform（MVP 矩阵），改视角 = 一次
`glUniformMatrix4fv`，不重编译、不重建管线**，所以头追能做到逐帧跟手。

| | xl_player | PiliPlus(本分支) |
| --- | --- | --- |
| 播放器 | 自研 C 播放器，自己拥有 GL 上下文 | 复用 media_kit → libmpv，渲染在 mpv 的 `vo=gpu` 里 |
| 解码 | MediaCodec（`xl_mediacodec.c`） | mpv 的 hwdec（同样是 MediaCodec） |
| 投影 | 自己的球面网格 + 顶点/片元着色器，**参数是 uniform** | mpv 用户着色器（`//!HOOK MAIN`），**参数只能烘焙进源码** |
| 姿态 | Cardboard OrientationEKF（陀螺仪+加速度计融合，抗漂移） | `sensors_plus` 陀螺仪积分 + 重力定姿态（会慢漂） |
| 改视角的代价 | ~0（每帧设 uniform） | 重建渲染管线 + 编译一份新 GLSL + mpv 进程内永久留一份程序缓存 |
| 弹幕/字幕/截图/画中画 | 没有 | 全部沿用 PiliPlus 既有能力 |

也就是说，卡顿与"参数不生效"不是实现细节写错了，而是**把 xl_player 那种
"uniform 逐帧更新"的交互，塞进了一个只接受"换源码"的接口**。

#### 现在的做法（在 `vo=gpu` 的约束内做到最好）

`lib/plugin/pl_player/utils/vr_shader.dart` + `PlPlayerController._runApplyVrShader`：

1. **一个文件只写一次**：内容变了就换新文件名（`writeUnique(seq)`），
   Dart 侧维护「源码 → 路径」映射；同一份源码复用同一路径，
   于是"回到看过的视角"在 mpv 那边是缓存命中 —— 不编译、不占预算；
2. **源码没变就不下发命令**（下发即重建管线，这是第三轮卡顿的直接来源）；
3. **串行 + 合并**：一次只允许一条 `change-list` 在飞，期间的更新合并成
   "用最新视角再发一次"，不会在 mpv 命令队列里堆几十次重建；
4. **节流**：拖拽 100ms、陀螺仪 180ms，手势结束 `force` 补一次；
5. **变体预算 + 自适应降档**（`VrQuantizer`）：每份新源码都是 mpv 进程里一条
   永久驻留的 GLSL 程序（`shader_cache.c` 的 `sc_flush_cache()` 只在
   `gl_sc_destroy()` 时调用）外加一个磁盘缓存文件，所以必须有上限。
   用量越大自动放大量化步长（0.5° → 1° → 2° → 4°），预算（1500）耗尽就
   停陀螺仪并明确告知，而不是悄悄罢工；
6. 播放器重建时 `purge()` 旧文件并重置预算（此时 mpv 侧的 `gl_video`
   连同它的两个缓存也确实没了）。**播放器活着的时候绝不能删这些文件**：
   media_kit 在 surface 尺寸变化时会重设 `vo=gpu`，那会重建 `gl_video`
   并从磁盘重新读取当前 `glsl-shaders` 指向的文件。

**诚实的结论**：`vo=gpu` + 用户着色器这条路做不到 xl_player 那种逐帧头追。
现在的实现下，切展开格式/切眼位/按钮步进是即时且正确的，拖拽与陀螺仪是
"量化 + 节流"的跟手（精度随用量下降）。要真正做到逐帧，只有两条路，
都不在本轮 scope 内，但已经留好了接口：

- 换 `vo=gpu-next` + `//!PARAM`（libplacebo 已随包构建，`buildscripts/scripts/libplacebo.sh`；
  media_kit 的 `VideoControllerConfiguration.vo` 也支持传）。**没有直接切**的原因：
  ① gpu-next 改渲染选项时 `update_render_options()` 结尾会置 `want_reset`，
  下一帧就 `pl_renderer_flush_cache()` + `pl_queue_reset()`（丢帧队列），
  高频改参数同样是灾难；② media_kit 的安卓 surface 流程对 `vo=gpu` 有专门处理
  （先 `vo=null` 再在拿到 videoParams 后设 `vo=gpu`、按分辨率重设 surface），
  换 VO 会波及**全部**视频播放，无设备环境下不敢动；
- 自己写 native GL 层（等于把 xl_player 的渲染器搬过来），代价是丢掉
  弹幕/字幕/截图/画中画等既有能力。

升级时只需把 `VrShader.source()` 里的 `#define` 换成 `//!PARAM` 块、
把下发命令换成 `setProperty('glsl-shader-opts', ...)`，投影数学与控制层都不用动。

### 9.2 SMB：主机即目录 + VLC 式手动快捷方式

第三轮的行为是"点主机 → 枚举共享 → **弹窗让用户挑一个** → 存成一条快捷路径 → 打开"，
两个共享就弹两次、快捷路径越攒越长，想换共享还得退回来重选。改成：

- **连接后直接进入这台主机**：主机本身是一级目录，它共享出来的目录是其中的子目录
  （VLC / Windows 资源管理器同款）。新增"主机级来源" `smb://<主机名>`（不带共享名）：
  `LocalMediaSource.isSmbHostRoot`，服务层把根目录解释为 SRVSVC `NetShareEnum`
  列共享（过滤 `IPC$`/`ADMIN$`/打印队列），往下按 `共享\子路径` 列目录；
  `showSmbSharePicker` 对话框已删除；
- 连接时仍然先枚举一次共享，但目的只是：拿服务端权威主机名（NTLM CHALLENGE 的
  AV_PAIR，存成 `smb://<主机名>` 而不是会变的 IP）、提前知道要不要账号、
  以及把共享列表当浏览页根目录的 `initialItems`（省一次往返）。
  枚举不可用（服务端禁用 RPC）才退回"手动输入共享地址"；
- 同一台主机只保存一条来源，已收藏过就直接进入，不再重新枚举；
- **快捷方式改为用户手动收藏**：浏览页右上角新增书签按钮，把当前目录存进
  「本地 → 媒体库」（本机目录）或「本地 → 网络」（网络来源）；
  已在收藏中时按钮变灰。地址推导（`LocalMediaController.shortcutFor`，静态纯函数）
  对三种来源分别处理：本机 = 绝对路径；SMB 主机级 = 路径第一段当共享名；
  SMB 共享级 = 共享名取自来源；WebDAV = 基址 + 路径；直链来源不可收藏；
- 浏览中服务端拒绝匿名 → 弹一次凭据框，账号写回来源并持久化，
  页面栈里同源的层级一起替换（否则每进一层都要重输）。

### 9.3 崩溃：`type 'NetworkSource' is not a subtype of type 'FileSource'`

`PlDanmakuController._initFileDm()` 里写的是 `dataSource as FileSource`，
而本地媒体的**局域网**来源是 `NetworkSource`（SMB 走回环代理、WebDAV/HTTP 直连）。
`isFileSource`（页面控制器那个）对本地媒体是 true，于是弹幕控制器走了
"读离线缓存目录里的 danmaku.pb"分支，一强转就炸 —— 打开三点菜单触发重建时必现。

修法有两层：

1. **本地媒体根本不挂弹幕组件**（`pages/video/view.dart` 的 `danmuWidget` 传 null）：
   B 站弹幕按 cid 拉取，离线缓存才有同目录的弹幕文件，本地/局域网视频两者都没有；
2. `_initFileDm()` 改成 `is! FileSource` 直接返回，任何调用路径都不会再崩。

### 9.4 本地视频播放器功能审查（不再照搬在线/缓存播放器）

按用户要求过了一遍播放器里"哪些功能对本地视频没有意义"。除了弹幕，还发现一个
**判据用错**的系统性问题：`PlPlayerController.isFileSource` 只看
`dataSource is FileSource`，而本地媒体的局域网来源是 `NetworkSource`，
于是一批只对 B 站在线视频成立的行为被错误打开。新增语义明确的
`isOfflinePlayback = isFileSource || isLocalMedia`，并按它重新判定：

| 功能 | 依赖 | 本地媒体 |
| --- | --- | --- |
| 弹幕组件 / 发弹幕 / 弹幕开关 / 弹幕列表 / 弹幕设置 | B 站 cid 或离线缓存目录 | **全部隐藏** |
| 底栏「弹幕趋势图」`dmChart` | `videoshot`/弹幕趋势接口 | 隐藏（`isOfflinePlayback`） |
| 底栏「看点」`viewPoints`、「选集」`episode`、「AI 字幕翻译」`aiTranslate`、「画质」`qa` | B 站播放地址/剧集/字幕接口 | 隐藏（`isOfflinePlayback`） |
| 拖动进度条 / 拖动缩略图时的**预览图** | `videoshot` 接口 | 关闭（`isOfflinePlayback`），不再无谓地调 `updatePreviewIndex` |
| 「稍后再看」「查看笔记」「举报」 | B 站账号体系（举报还要 aid） | 隐藏 |
| 「解码格式」 | 读 `supportFormats` 并会重新请求播放地址 | 仍只对 B 站视频开放（本地媒体点了必崩，故不放开） |
| 「选择画质/音质」「CDN 设置」「离线缓存」「投屏」「听音频」 | 同上 | 原本就按 `!isFileSource` 隐藏，本地媒体同样隐藏 |
| 上一个/下一个、播放顺序、倍速、字幕（含加载外挂字幕）、截图、画中画、画面比例、VR、定时关闭、播放信息 | 纯本地能力 | **保留** |
| 播放历史上报 / 进度预览图请求 | B 站接口 | 早已有 `isLocalMedia` 闸门，保留 |

### 9.5 那两条 `SocketException: Connection timed out ... port = 526xx`

报告里 `STACK TRACE: null` 说明它是**未捕获的异步错误**（zone 兜到的），
不是某条调用栈上的同步失败。排查了本分支所有会开 socket 的代码：

- SMB 的 TCP 一律连 445（`smb2_client.dart: Socket.connect(address, port)`），
  UDP 只发 137（NBNS/NBSTAT），且都挂了 `onError`；
- 回环代理只听 `127.0.0.1`，`_handle` 外面包了 `catch (_)`；
- 全仓搜不到任何"连局域网 IP + 随机高端口"的 Dart 代码。

而 `192.168.2.2:52612` / `:52616` 这种**同一 IP、相邻高端口、同一毫秒超时**的组合，
最符合"SSDP 发现设备后去 `http://<设备IP>:<随机端口>/...` 拉设备描述"的行为
（Windows/多数 DLNA 渲染器的描述地址就是随机高端口）。`lib/pages/dlna/view.dart`
恰好有这个隐患：`_onSearch()` 是从 `initState` 里**不 await** 调起来的，
里面又用 `await for` 消费 `devices.stream` —— 插件抛出的 SocketException
无人接收，直接冒到 zone 外面被当崩溃上报。已改为显式订阅 + `onError` +
整体 `try`，`dispose` 里取消订阅并 `_searcher.stop()`，投屏失败也给 toast。

> 说明：这条只能定位到"最可能"，因为报告里没有 Dart 栈。若换机复现，
> 抓一份 `adb logcat` 就能确认是不是 `dlna_dart`。本分支自己的 socket 路径
> 已经全部有错误归属，不会再产生这类无栈报告。

### 9.6 顺手修掉的仓库问题：`test*` 把整个测试目录吃掉了

`.gitignore` 里有一行上游留下的 `test*`，`git check-ignore -v test/plugin/vr_test.dart`
命中它 —— 也就是说**前三轮写在 `test/` 下的单元测试一个都没进仓库**，
CI 的 `flutter test` 一直在空跑（`STRICT_PATHS` 里那些测试路径也因为
`[ -e "$p" ]` 判断而被跳过）。保留原规则、补一行 `!/test/` 把目录放回来，
本轮的 4 个测试文件是真正进了 CI 的第一批。

### 9.7 补：节流要"带尾随下发"，方向键长按不能绕过节流

改完 9.1 之后又自查出两处会让"卡顿"复发的地方：

1. `vrStep`（屏幕方向键 / 🔍±）原来调 `applyVrView(force: true)`，而长按连续转动
   是 110ms 一次 → `force` 绕过节流 → 每秒约 9 次渲染管线重建 + 9 个新着色器变体，
   和第三轮那个 45ms/22 次是同一类问题。改为走节流路径；
2. 原来的节流是"窗口内直接丢弃"，于是按住方向键的最后一下、拖拽结束前的最后一段
   位移可能不落地，表现成"画面差一点点没跟上手指"。改为**尾随下发**：窗口内的更新
   排一个定时器在窗口末尾补发，最终视角一定准确。

手势结束（`_onScaleEnd`）、视角摆正、进入 VR 操作模式仍然 `force` —— 这些是离散动作，
需要立刻生效。`dispose()` 里取消尾随定时器。

### 9.8 单元测试第一次真的跑起来，立刻抓到一个 bug

`.gitignore` 修好之后（9.6），本轮 4 个测试文件是仓库里第一批真正进 CI 的测试。
它们当场抓到一个只看代码很难发现的真 bug：

> **Dart 的 `Uri.host` 会按 RFC 3986 把主机名规范化成小写**
> （`Uri.parse('smb://NAS/pub').host == 'nas'`）。

于是 `smb://NAS` 一经解析就变成 `smb://nas`：收藏出来的快捷方式地址、界面上展示的
地址都会与发现阶段（NBSTAT / SRVSVC AV_PAIR）拿到的大写 NetBIOS 名对不上，
"这是不是同一台主机"的匹配也会失效 —— 同一台主机会被认成两台。

修法：`LocalMediaSource.rawHostOf()` 自己从 authority 里截主机名（处理 userinfo、
端口、IPv6 方括号、path/query/fragment），`smbHost` / `smbEndpoint` 都改用它。
连接不受影响：DNS 与 NetBIOS 都大小写不敏感（NBNS 查询本来就会 `toUpperCase()`）。
`SmbBrowse.parseEndpoint` 保持用 `Uri.host`（其结果只用于建连接），
测试里把这个差异显式记录下来，避免以后有人"顺手统一"反而改坏展示。

CI 那一轮的输出正好说明了这批测试的价值：`flutter analyze` errors=0 / warnings=0，
新增路径 `dart analyze --fatal-infos` 报 `No issues found!`，
而 `flutter test` 是 **68 passed / 7 failed —— 7 条失败全部指向这一个根因**。

### 9.9 本轮验证

- CI（`.github/workflows/piliplayer_ci.yml`）：`flutter analyze`（error 视为失败）
  → 新增路径 `dart analyze --fatal-infos` 零容忍 → `flutter test` → 构建 arm64-v8a；
- 新增测试：`test/plugin/vr_test.dart`、`test/services/smb/smb_browse_test.dart`、
  `test/services/local_media_source_test.dart`、`test/services/local_media_service_test.dart`；
- 沙盒里用 Dart SDK 3.13.5 的 `dart format` 做了全量语法解析校验
  （沙盒装不下 Flutter，无法本地 analyze/test，一切以 CI 为准）；
- release 腿加 `--target-platform android-arm64`，测试包只出 arm64-v8a；
- 发布：tag `v2.1.6-test.1`（版本 2.1.5+2 → **2.1.6+3**，按 0.0.1 步进），
  Release 里只有 `app-arm64-v8a-release.apk` + `app-debug.apk` 与各自的
  SHA256SUMS；旧的 `v2.1.5-test.1` release 与 tag 已在新包产出并校验之后删除。
  tag 那条 workflow run 三个 job（Analyze & Test / Build debug / Build release）全绿。

---

## 10. 第五轮真机反馈修复（v2.1.5-test 固定 tag）

### 10.1 本地视频强制自动播放（顺带解释"三点菜单是在线菜单"）

「自动播放」设置关掉时，播放页停在封面占位状态 —— 那个状态下顶栏挂的是
**在线视频**的菜单（分享/举报/稍后再看…），对本地文件全都不成立。
本地点开就是要看，没有"先不播"的语义，所以 `isLocalMedia` 时
`_autoPlay` 强制为 true（`VideoDetailController.onInit`）。

### 10.2 三点菜单打不开：`as FileSource` 的第二处

上一轮只修了弹幕控制器里的强转，没把全仓扫干净。这次崩在
`header_control.dart:679`「只听音频」那一项：

```dart
if ((isFileSource && !(plPlayerController.dataSource as FileSource).isMp4) || ...)
```

页面的 `isFileSource` 对本地媒体是 true，而 `dataSource` 是 `NetworkSource`
（SMB 回环代理 / WebDAV / HTTP）→ 一强转就抛。抽成 `_canOnlyPlayAudio` getter，
先判类型再用，不做任何强转。`grep -rn "as FileSource" lib/` 现在只剩注释里的说明。

### 10.3 内嵌字幕：根因是被我们自己关掉的

现象是"播内嵌字幕的片子看不到字幕，播放信息里只有 video/audio"。
根因不在解码器，而在 `VideoDetailController.playerInit` 的 `onInit`：

```dart
onInit: () { videoState.value = true; setSubtitle(vttSubtitlesIndex.value); }
```

`vttSubtitlesIndex` 默认 -1 → `setSubtitle(-1)` → `setSubtitleTrack(SubtitleTrack.no())`
→ mpv `sid=no`，**把片源里内嵌的字幕轨一起关掉了**。
media_kit 只在创建播放器时设 `vid=no`，并不动 `sid`，所以本来 mpv 的
`sid=auto` 会自动选一条内嵌字幕。

修法：

1. 本地媒体不再调 `setSubtitle(...)`，内嵌字幕交给 mpv 的 `sid=auto` 自选；
2. `PlPlayerController` 订阅 media_kit 的 `stream.tracks` / `stream.track`，
   暴露 `internalSubtitleTracks` / `internalAudioTracks` / `currentTrack`
   （过滤掉 media_kit 塞在列表最前面的 `auto`/`no` 两个伪轨道）；
3. **字幕入口按 VLC 的做法从三点菜单移到播放器顶栏**：顶栏新增「字幕」按钮，
   面板里一屏给出「当前正在用的字幕流」（以 mpv 实际选中的轨为准，不是本地记的）、
   B 站字幕 / 内嵌字幕轨道 / 自动 / 关闭、多音轨片源的音轨切换、
   加载外挂字幕（srt/ass/vtt/json/bcc）与字幕设置；三点菜单里的
   「字幕设置」「加载字幕」随之移除（逻辑原样搬进面板，行为不变）；
4. 播放信息补 `SubtitleTrack` 与可用轨道数 —— 上一轮定位问题就是卡在
   "播放信息里看不到字幕轨"。

### 10.4 VR 改为自研 native 播放器（不再用 mpv 渲染）

第 9.1 节已经论证过：mpv 安卓端固定 `vo=gpu`，用户着色器不支持 `//!PARAM`，
视角参数只能烘焙进源码，改一次视角 = 重建整条渲染管线 + 编译一份新 GLSL +
在 mpv 进程里永久留一份程序缓存。**逐帧头追在这条路上做不到**，
量化/节流/预算只能把体验做到"能用"，做不到 xl_player 那样跟手。

这轮按 xl_player 的管线自己写了一套（`android/app/src/main/kotlin/com/example/piliplus/vr/`）：

```
MediaExtractor ─┬─ video → MediaCodec ──→ SurfaceTexture(OES 纹理)
                │                                    │
                └─ audio → MediaCodec → AudioTrack   │  GLES2 程序(全屏四边形 +
                              (主时钟)               ▼  等距柱状→直线投影片元着色器)
                                            VrGlPipeline ──→ Flutter TextureRegistry
```

| 文件 | 内容 |
| --- | --- |
| `VrGlPipeline.kt` | EGL14 + GLES2 渲染线程（`HandlerThread` + `Choreographer` 跟 vsync 出帧）；片元着色器做等距柱状→直线投影，**yaw/pitch/fov/覆盖角/眼位全是 uniform**；OES 外部纹理 + `SurfaceTexture.getTransformMatrix` |
| `VrEngine.kt` | MediaExtractor + MediaCodec（视频解到 Surface，音频解到 AudioTrack 并作**主时钟**）、倍速（`AudioTrack.playbackParams`）、seek（flush + `SEEK_TO_PREVIOUS_SYNC`）、丢帧追赶、缓冲/结束/错误回调 |
| `VrHeadTracker.kt` | 优先 `TYPE_ROTATION_VECTOR`（系统已融合陀螺仪+加速度计+磁力计）：每次取绝对姿态的 yaw/pitch，**用相邻两次的差累加** —— 增量是两个绝对值之差，所以不像纯陀螺仪积分那样慢漂（这正是 Dart 版 `VrGyroMath` 的已知限制）。没有旋转矢量传感器时退回「加速度计定姿态 + 陀螺仪积分」 |
| `VrPlayerBridge.kt` | MethodChannel `piliplus/vr_player`：create/open/play/pause/seekTo/setSpeed/lookBy/setFov/zoomBy/resetView/setProjection/setEye/setGyro/release，事件回传 prepared/view/buffering/ended/error |
| `lib/services/vr/vr_native_player.dart` | Dart 侧控制器（`GetxController` + Rx 状态） |
| `lib/pages/video/vr/vr_player_page.dart` | 独立全屏播放页：拖拽环视、双指缩放视场角、方向键/缩放键长按连续、片源布局与眼位切换、陀螺仪开关、视角摆正、进度条与快进快退、错误/缓冲/播完状态 |

关键设计：

- **视角状态以 native 为准**，Dart 只发增量指令（`lookBy`/`setFov`/`resetView`），
  native 在**每帧绘制前**（`onBeforeFrame`，GL 线程上）把头追增量叠到 yaw/pitch 上，
  再按 10Hz 把读数回报给 Dart 显示。头追不经过 platform channel 往返，
  所以是真正的逐帧跟手；
- 投影数学与 Dart/mpv 版**逐行对齐**（同样的 rotX→rotY 顺序、同样的
  `u = lon/coverageH + 0.5`、`v = 0.5 - lat/π`、180° 片源按 `±(coverage-fov)/2`
  收敛、双目取单眼区域），所以两条路径看到的画面几何一致，只是刷新方式不同；
- 用全屏四边形 + 片元着色器做投影，**不是球面网格**：没有网格密度不足导致的
  边缘拉伸，也不用生成/上传顶点缓冲；
- 进入这一页时暂停外层 mpv、退出时恢复（`onResumeOuter`），不会两路一起出声；
- `open`/`release` 都放到后台线程（`awaitVideoSurface` 最多等 3s、解码线程要 join），
  避免占着主线程触发 ANR；`TextureRegistry` 的 entry 仍回主线程释放；
- WebDAV/HTTP 的凭据转成 `Authorization: Basic` 头（`LocalMediaService.nativeHeaders`）：
  MediaExtractor 不会像 FFmpeg 那样自己解析 URL 里的 userinfo；
- **保留回退开关**：设置 → 播放设置 → 「VR 使用独立播放器」（默认开）。
  关掉就回到 mpv 用户着色器路径（第 9.1 节那套量化+节流+预算的实现原样保留），
  万一新渲染器在某些机型上有问题，用户可以立刻退回，也能对比两条路径的手感。

已知边界（不藏）：

- 只实现了安卓；其它平台自动退回 mpv 着色器路径（`isSupported` 判定）；
- VR 播放页里**没有弹幕**（这一页不经过 mpv，弹幕是 mpv 播放器上的 Flutter 层），
  也暂时没有字幕与多音轨切换（`VrEngine` 只取第一条视频轨/第一条音频轨）；
- seek 对齐到前一个关键帧，不是逐帧精确；
- 不支持 DRM 与 `ftp://`（MediaExtractor 不认，会明确提示）；
- 沙盒里没有 Android SDK/设备，**这套 native 代码只经过 CI 的 gradle 编译验证**，
  运行时行为（GL 上下纹理方向、色彩、音画同步、传感器轴向）需要真机确认；
  真机上如有问题，先用上面的回退开关退回 mpv 路径，再反馈现象。

### 10.5 native 引擎的两个时钟/交互坑（写完复读时抓到的）

沙盒里没有 Android SDK，native 代码只能靠 CI 编译 + 真机验证，所以写完逐行复读了一遍，
抓到两个只有真机才会暴露的问题，赶在出包前修掉：

1. **无音轨片源暂停后位置会漂移**：没有音轨时用墙钟计时，而墙钟不会因为
   `pause()` 停下 → 恢复播放时 position 一次性跳过"暂停了多久"，视频同步也跟着错。
   现在 `pause()` 冻结 `frozenUs`，`play()` 以冻结值重新对齐墙钟基准；
2. **暂停中拖进度条看不到画面**：视频线程在 `!playing` 时直接 `continue`，一帧都不出。
   加 `renderOneFrame`：seek 时放行一帧（早于目标的帧照常丢弃追赶），渲染完即复位。

另外两个 Dart 侧的问题也是自查出来的（都会在真机上直接表现为"打不开/花屏"级别）：

3. `_buildVideo` 直接在 `build` 里读 `textureId`（普通字段，不是 Rx）→ `open()`
   完成后不会触发重建，页面会永远停在"正在准备 VR 播放器…"。改为包在 `Obx` 里读 `ready`；
4. `dispose` 里无条件 `showSystemBar()`：从全屏播放进 VR 页时系统栏本来就是隐藏的，
   退出时会把它放出来盖在外层播放器上。改为只有"进来时系统栏可见"才恢复。

### 10.6 版本与发布流程

- 版本**切回 `2.1.5+2`**，不再随每轮 bump；
- tag 固定为 **`v2.1.5-test`**：每次新构建先删掉旧的 release 与同名 tag，
  再在新提交上重建 —— 下载链接永远不变，Release 页永远只有一个测试包；
- CI 的 release 腿仍然只出 `arm64-v8a`。

---

## 11. 第六轮真机反馈（VR 播放器首版）

首版自研 VR 播放器装机后反馈两件事：**控件全挤在屏幕中间**、**解码出来的画面是纯色**。
两个都能定位到具体原因，不是"玄学渲染问题"。

### 11.1 纯色画面：Flutter 不会替你设输出缓冲区尺寸

`TextureRegistry.createSurfaceTexture()` 给的 SurfaceTexture，**Flutter 不会替插件调用
`setDefaultBufferSize`**（这点和 `createSurfaceProducer`/ImageReader 不一样），默认就是 0x0。
而我的时序是：`create` → native 立刻起 GL 线程开始渲染 → Dart 那边 `open()` 返回后
才重建出 `Texture(textureId)` 组件并完成布局。于是 EGL 交换出来的缓冲只有 1 个像素、
`glViewport` 也只有 1x1，Flutter 把这 1 个像素**拉伸铺满全屏** → 整屏一个纯色。

修法（四层，缺一不可）：

1. `initGl` 里主动 `setDefaultBufferSize(1280, 720)` 兜底，绝不留 0x0；
2. Dart 侧 `LayoutBuilder` 拿到真实尺寸后按 `devicePixelRatio` 换算成**设备像素**，
   通过新增的 `setRenderSize` 报给 native；
3. native 收到后重设缓冲区尺寸并**重建 EGL window surface** —— 个别实现会把
   创建时的几何信息缓存住，只改 `setDefaultBufferSize` 不一定生效；
4. `eglQuerySurface` 查不到尺寸（返回 0）时退回我们自己设的值，
   绝不让 `glViewport` 变成 0/1。

顺带把 `eglCreateWindowSurface` 的 native window 从 `SurfaceTexture` 换成
`Surface(surfaceTexture)`：EGL14 对前者各版本处理不完全一致，后者是所有实现都认的。

### 11.2 还有一个只有 VR 播放器会踩的坑：明文 HTTP

`MediaExtractor` 走的是**系统 HTTP 栈**（MediaHTTPService），受安卓明文流量策略约束
（Android 9+ 默认禁止 `http://`）；而 mpv/FFmpeg 自己做 socket，**不受这个策略管** ——
所以 SMB 播放在 mpv 路径下一直是好的，换到 VR 播放器就必挂（SMB 恰恰是走
`127.0.0.1` 上的回环 HTTP 代理，见第 5 节）。

新增 `android/app/src/main/res/xml/network_security_config.xml` 放开明文。
说明一下影响面：这只是"允许"明文，不会把任何 https 请求降级；B 站接口全是 https，
行为不变。而这个 app 本身就是局域网播放器（WebDAV/HTTP/SMB 直链是一等公民），
mpv 路径早就在做任意明文 HTTP 了，这里只是让两条路径行为一致。

### 11.3 控件挤在屏幕中间：Stack 的非定位子项是 tight 约束

`Stack(fit: StackFit.expand)` 的**非定位**子项拿到的是**全屏 tight 约束**。
我直接往里塞了 `SafeArea > Padding > Row` 的顶栏，Row 被拉满整屏，
内容按 `crossAxisAlignment: center` 垂直居中 → 顶栏就出现在屏幕正中间。
改为全部用 `Positioned` 明确定位（顶/左/右/底各一个），侧边按钮拆成左右两列各自
`Center`，不再用一个占满全屏的 `Row`（那样还会把整屏的点击都吃掉）。

### 11.4 加诊断能力：没有设备时，让真机一次把话说清

沙盒里没有 Android SDK 也没有设备，"改一版→出包→装机→看现象"一轮就是二三十分钟，
所以这轮把可观测性做进去了，下一轮不用再猜：

- 顶栏「诊断信息」按钮：屏幕上直接显示 native 每 100ms 回报的一行
  `render=<EGL 实际尺寸> video=<解码尺寸> frames=<渲染帧> texUpd=<updateTexImage 次数>
  decoded=<解码帧> rendered=<送显帧> glErr pos playing dur`；
- 「原画直通」开关：跳过球面投影，把解码帧原样贴出来。
  **直通有画面 → 问题在投影；直通仍纯色 → 问题在解码/纹理链路**；
- 一帧视频都没到时清成**深蓝**而不是黑：深蓝 = GL 在跑但没有解码帧，
  纯黑 = 连 GL 输出都没到 Flutter，两者修法完全不同；
- 打开后 10 秒仍无画面 → 明确报错并附上那行诊断。

### 11.5 关于"用 xl_player 的管线解码再传给 view"

现在这套 native 管线与 xl_player **结构同构**：

```
xl_player : ffmpeg 解封装 → MediaCodec 硬解 → OES 纹理 → 自己的 GLES 球面渲染 → SurfaceView
本实现    : MediaExtractor → MediaCodec 硬解 → OES 纹理 → 自己的 GLES2 投影   → Flutter Texture
```

参数同样是**每帧 uniform**（不重编译、不重建管线），头追同样在渲染线程里逐帧叠加。
唯一区别是最后一步呈现到 Flutter 的 `Texture` 而不是自己的 `SurfaceView` ——
因为控制层是 Flutter 画的，必须能叠在画面上面（用 SurfaceView 就得走 PlatformView
混合合成，还要处理 z-order）。

**如果诊断显示 `decoded/frames/texUpd` 都在涨而画面仍然不对**，那问题就锁定在最后
这一步呈现上，下一轮改成 PlatformView + SurfaceView（`initExpensiveAndroidView`
混合合成，Flutter 控件照样能叠在上面）即可，解码与投影代码一行都不用动。

### 11.6 目录检索（本目录 + 所有子目录）

浏览页顶栏新增检索按钮，`LocalMediaService.search()`：

- 广度优先递归**当前目录及其所有子目录**，按文件名（不区分大小写）匹配可播放媒体，
  结果保持 BFS 顺序 —— 要搜的东西多半就在附近，就近排前面比按名称排序更有用；
- 输入 400ms 去抖；改词/退出/销毁页面用「检索代数」让在飞的那次结果直接作废；
- `maxResults=500` / `maxDirs=1500` 硬上限：整卡递归动辄上万个目录，SMB 更是
  **每个目录一次网络往返**，不设上限会把 UI 和连接一起拖死；扫描中实时显示
  「已扫描 N 个目录，找到 M 个」；
- 单个目录读不出来（无权限/断链/服务端拒绝）跳过，不影响整体；
- 结果直接可播，播放列表就是结果集；检索态下隐藏书签/排序/隐藏文件/刷新，
  返回键先退出检索；
- 下钻路径的推导抽成 `LocalMediaService.childPath()`，浏览与检索共用同一套约定
  （本机 = 绝对路径，网络 = 服务器相对路径，SMB 主机级 = 共享名打头），
  避免又出现"多套一层共享名"那类错，并补了单测。

---

## 12. 第七轮真机反馈

### 12.1 VR 画面上下颠倒

`SurfaceTexture.getTransformMatrix()` 给的变换矩阵**各机型不统一**：有的自带一次
上下翻转，有的是单位阵。我按"图像空间 v 向下"直接过矩阵，在这台机器上就颠倒了。

修法：着色器里加 `uFlipV`（`fixV(v) = mix(v, 1.0 - v, uFlipV)`），默认翻一次；
并且做成**诊断面板里可实时切换**的开关 —— 换机型时当场就能确认方向，
不用为了一个符号再出一版包。

### 12.2 VR 频繁"等待缓冲"（本机文件也这样）

用户反馈的是本机存储的视频，xl_player 播同一个文件正常 —— 所以瓶颈不在 IO，
而在**我喂解码器的节奏**：

第一版视频线程每个循环只喂 **一个** 输入缓冲，而输出侧又要等到帧的显示时间才放行；
等待期间完全不喂输入，解码器的输入池（通常只有 4~8 个）很快被耗干，
输出侧就反复拿到 `INFO_TRY_AGAIN_LATER`，超过 400ms 就报一次"缓冲中"。
表现为：明明是本机文件，却不停转圈。

修法：抽出 `feedVideoInput` / `feedAudioInput`，一次尽量喂满（最多 8 个），
并且**在"等显示时间"的循环里继续非阻塞补喂** —— 解码器不再挨饿。
（音频侧本来就是靠 `AudioTrack` 的阻塞写来定节奏，同样一次多喂几个。）

### 12.3 "能不能把解码投影后的画面直接输出到原来播放器的 view？"

不能，原因是那个 view 是 **mpv 的**：media_kit 在安卓上把 mpv 的 `--wid` 绑到
自己创建的 SurfaceTexture 上，画面由 mpv 的 `vo=gpu` 直接画进去，
外部拿不到那块 surface，也没法在 mpv 出图之后插入一道投影。
要用自研渲染器就必须自己拥有一条"解码 → 纹理 → 输出"的通路。

现在的通路已经是最短的了，**没有多余的拷贝**：

```
MediaCodec ──(硬件直接写)──> SurfaceTexture A(OES 纹理)
                                    │  GL: 一次 drawcall 做球面投影
                                    ▼
                     SurfaceTexture B(Flutter TextureRegistry)
                                    │  Flutter 合成(与控件同一帧)
                                    ▼
                                  屏幕
```

A→B 之间只有一次 GPU 内的全屏 drawcall（不经过 CPU、不经过内存拷贝）；
B 是 Flutter 的纹理，为的是让 Flutter 画的控件能叠在画面上。
如果哪天要连这一步也省掉，就得改用 PlatformView + SurfaceView（混合合成），
代价是要自己处理 z-order 与合成开销 —— 目前诊断数据还不支持"这一步是瓶颈"的结论，
所以先不动。

### 12.4 为什么 SMB 走操作系统网络栈，而不是内存指针 / IPC

问得对，这里确实有个取舍，写清楚：

`MediaExtractor` 只接受四种输入：文件路径、`FileDescriptor`、`Uri`(+headers)、
以及 `MediaDataSource`（API 23+，`readAt(position, buffer, offset, size)` 回调）。

| 方案 | 能不能用 | 原因 |
| --- | --- | --- |
| `MediaDataSource`（"内存指针"） | ❌ | 它的 `readAt` 是在**解封装线程上同步阻塞**调用的，必须立刻返回字节。而我们的 SMB2 客户端是**纯 Dart** 实现的，native 只能通过 platform channel 调 Dart —— 那是**异步且必须在主线程收发**的。让 native 线程阻塞等一个 Dart 异步回包，主线程一旦被占就是死锁。除非把整个 SMB 客户端重写成 Kotlin |
| `ParcelFileDescriptor.createPipe()`（真 IPC，不过网络栈） | ❌ | 管道**不可 seek**。moov 在文件尾的 MP4（非常常见）必须能随机访问才能起播，用户拖动进度条也需要 seek |
| 回环 HTTP（现在用的） | ✅ | 进程内（`127.0.0.1`，数据不出设备）、可用 `Range`/206 随机访问、Dart 侧可以异步流式喂；而且**与 mpv 共用同一个代理**，一套实现两个播放器都能用 |

代价是 HTTP 分帧 + 每块数据两次内核拷贝（用户态→内核→用户态），
但在 loopback 上是 GB/s 量级，远快于 SMB 本身的千兆/百兆链路，不是瓶颈。

另外要说清楚：**本机文件根本不走这条路** —— 那是直接给 MediaExtractor 一个文件路径
（真 fd），完全不涉及网络栈。所以 12.2 那个"本机文件也频繁缓冲"的问题与网络栈无关，
纯粹是喂解码器的节奏问题。

顺带：`MediaExtractor` 走系统 HTTP 栈，因此受安卓明文流量策略约束
（见 11.2），这也是必须加 `network_security_config.xml` 的原因。

### 12.5 倍速改成滑动条（0.1 步进）

底栏倍速原来是个 `PopupMenuButton` 列预设档位（0.5/0.75/1/1.25/1.5/1.75/2/3/4/8），
只能挑那几档。改成底部面板：**滑动条 0.5X–4.0X、步进 0.1**（35 档），
预设档位保留成快捷 chip（滑动条范围外的 8X 也还在），另加「重置为 1.0X」。
`setPlaybackSpeed` 本身不做上限裁剪（直接交给 mpv 的 `setRate`），所以 0.1 步进没问题；
滑动值统一 `(v*10).round()/10`，避免 1.7000000000000002 这种显示。

### 12.6 目录检索改成"边扫边出"

第一版是遍历完整棵树才一次性显示结果 —— 大目录/局域网下要等几十秒，期间界面一片空白。
现在 `LocalMediaService.search` 增加 `onFound` 回调，命中即回调；
浏览页把命中先塞进缓冲，按 ~120ms 批量 `setState` 一次
（每条都刷会把整张列表重建一遍，反而更卡）。
改关键词/退出检索/销毁页面时用"检索代数"作废在飞的那次，并清掉缓冲与定时器。

### 12.7 CI 改成"一次构建即发布"

以前每轮要等两次：分支 push 建一次 debug（~13 分钟），打 tag 再建 debug+release
（~20 分钟）。既然只在 CI 全绿后才发 release，那第一次就是纯浪费。
现在 **只有 tag 触发出包，且只出 release(arm64-v8a)**：`check`（analyze + test）
或构建任一步失败就不会有产物上传，Release 也不会被填上半成品；
需要 debug 包时用 `workflow_dispatch` 手动出。每轮从 ~33 分钟降到 ~17 分钟、少一次构建。

---

## 13. 第八轮真机反馈：VR 投影换成球面网格、陀螺仪俯仰符号、SMB 会话复用

### 13.1 陀螺仪上下反向：**我上一轮的修法治了标、掩盖了本**

第六轮报"画面上下颠倒"，我加了 `uFlipV` 把采样 v 翻了。第七轮变成"画面正了、
陀螺仪上下反了"。这两件事其实是**两个独立的 bug**，而翻转只是把第二个暴露出来：

- 画面颠倒 = 采样 v 与片源行序的对应关系错了 → `uFlipV` 修对了，保留；
- 俯仰反了 = **参考轴用错了**。`VrHeadTracker` 原来取 `f = R·(0,0,1)`，
  那是**屏幕法线**（+Z，指向用户）。但 magic-window 模式下你"看向"的是
  **背面摄像头的方向 = −Z**（手机举起来对着场景、屏幕朝着自己）。
  用 +Z 算出来的 pitch 符号正好相反。

改成 `f = −R·(0,0,1)` 后：`pitch = asin(f.z)` 在抬头时增大 ✓，与着色器
"pitch+ = 向上看"的约定一致。**偏航之所以一直是对的**：取 −f 只让 yaw 差一个
常量 π，而我们用的是相邻两次采样的**差值**，常量自动抵消 —— 所以这个 bug
只表现在俯仰上，很容易看漏。

顺带把"没有旋转矢量传感器时"的退回方案（加速度计定姿态 + 陀螺仪积分）的
轴向映射也重推了一遍：原来横屏下把 yaw/pitch 用在了**错误的设备轴**上
（横屏顶左时，绕设备 X 才是偏航、绕设备 Y 才是俯仰，我写反了）。
四种姿态各自的映射现在写在代码注释里，与 Dart 版 `VrGyroMath` 的推导对齐。

### 13.2 卡顿的真正原因：逐像素做球面投影，GPU 吃不消

第六轮用的是"全屏四边形 + 片元着色器逐像素算等距柱状→直线投影"：
每个像素 4 次三角函数 + `normalize` + `atan` + `asin`。在 2560×1600 的平板上
按 vsync 连出 60 帧 = **每秒两亿多次超越函数运算**，Adreno 610 根本吃不消。
GPU 打满之后渲染线程抢不到 CPU，解码线程也跟着饿 —— 所以"卡顿"和"频繁缓冲"
是同一个根因的两个表现。（上一轮我只改了喂解码器的节奏，治了半个，
把解码器放开了跑反而让 CPU 更紧张，所以用户感觉"更严重了"。）

现在换成 **UV 球面网格**（xl_player / ExoPlayer `SphericalGLSurfaceView` 的做法）：

| | 第六轮 | 现在 |
| --- | --- | --- |
| 几何 | 全屏四边形（4 顶点） | UV 球面网格（72×36 段 ≈ 2700 顶点 / 15k 三角形；180° 片源经度减半） |
| 投影数学在哪算 | **每个像素**（几百万次/帧） | **生成网格时算一次**；每帧只在 CPU 上算一个 MVP 矩阵 |
| 片元着色器 | 4×trig + normalize + atan + asin | **一次纹理采样** |
| 视角怎么传 | 5 个 float uniform | 1 个 mat4 uniform（`Rx(-pitch)·Ry(-yaw)` × 透视投影） |

GPU 负载下降约三个数量级，这才是"逐帧头追"能成立的前提。
网格只在覆盖角 360↔180 切换时重建（两种），眼位/翻转/视角都不触发重建。

同时加了 **dirty 渲染**：只在"有新帧或视角变了"时才真正 draw，静止画面不再
空转 60fps（省电，也把 CPU 让给解码线程）。

还限制了**解码预读窗口**（最多领先时钟 0.8s）：上一轮改成"一次喂满"之后，
解码器会尽可能往前解，在弱 SoC 上与渲染抢 CPU，seek 时还会白解一堆用不上的帧。

### 13.3 SMB 会话复用（对齐 VLC / libsmb2）

以前**每次列目录、每次播放、每个 Range 请求**都新建一条连接：
NEGOTIATE + SESSION_SETUP(NTLM 三个往返) + TREE_CONNECT + CREATE，
局域网里也要 100~300ms。mpv / MediaExtractor 是按 Range 读的，
**拖一次进度条就重新握手一次** —— 这就是局域网播放"拖一下就卡一下"的直接来源。
VLC(libsmb2)、Windows 资源管理器都是复用会话的，这里跟上。

`lib/services/smb/smb_session_pool.dart`：

- 按 `(host, port, share, user, domain)` 分桶，每桶最多 4 条会话；
- **一条会话同一时刻只跑一个请求**：`Smb2Client` 只有一个 `_waiter`、
  一套 messageId/信用记账，并发发请求会串包。所以用"连接池 + 借还"，
  而不是一条连接多路复用（那需要按 MessageId 分发响应，当前客户端没实现）；
  播放器通常同时开 1~2 条 HTTP 连接，所以每桶留了余量，到上限才排队等；
- **错误分诊**：只有会话/连接层面的错误（socket 断、超时、
  `USER_SESSION_DELETED`、`NETWORK_SESSION_EXPIRED`）才作废会话；
  文件层面的错误（路径不存在、无权限、不是目录）**保留会话** ——
  判反了要么反复白握手，要么抱着坏连接一直失败；
- **客户端中断 ≠ 会话坏了**：mpv seek 时会掐掉上一个 HTTP 请求，
  `_pump` 里单独捕获这种写入失败并 quietly 关闭响应，绝不因此作废会话
  （否则"拖动进度条 = 重新握手"，正好把要修的问题又造回来）；
- 空闲 2 分钟自动关（比 Samba 踢静默会话的默认时间短），文件句柄用完就还、
  会话留给池；握手/tree connect 失败会把半开的连接关掉，不漏 socket；
- 共享枚举（SRVSVC 走 `IPC$`）用 `IPC$` 作为 key 单独一条，
  与磁盘共享的会话互不干扰 —— 主机根目录每次进来都要枚举，复用它省一整套握手。

关于"为什么不用内存指针 / IPC 而用回环 HTTP"，见 12.4（结论不变：
`MediaDataSource.readAt` 是解封装线程上的**同步阻塞**调用，而 SMB 客户端是纯 Dart，
platform channel 是异步且主线程收发，阻塞等回包会死锁；管道又不可 seek，
moov 在尾部的 MP4 连起播都做不到）。会话复用之后，那条 HTTP 路径上
最贵的握手成本已经摊掉了。

### 13.4 本轮验证

- 新增 `test/services/smb/smb_session_pool_test.dart`：错误分诊（会话级 vs 文件级 vs
  socket 级）与容量/空闲策略常量；
- CI 仍是"一次构建即发布"（只有 tag 触发，只出 arm64-v8a release）。

## 14. 第九轮：VR 渲染层改为移植 xl_player

### 14.1 决策依据

第八轮把投影从"全屏四边形 + 逐像素反投影"换成手写球面网格后，真机反馈仍是
「问题太多」。既然 VR 已经是独立播放窗口（等于接受了第二套播放栈），继续自己维护
一套 GL 渲染器的收益不高，于是按需求改为移植
[xl_player](https://github.com/xl-player-developers/xl_player)（2017 年的 Android
VR 播放器，Cardboard 系）。

移植范围经过一次事实核查后收窄。上游 `xl-player-armv7a/build.gradle` 写死
`abiFilters 'armeabi-v7a'`，`ff_libs/` 里只带 **v7a 预编译**的
`libavcodec-57 / libavformat-57 / libavutil-55 / libavfilter-6 / libswresample-2`
（≈9 MB，avcodec 57 = FFmpeg 3.2~3.4）。本项目是 arm64-v8a，64 位进程加载不了 32 位
`.so`；而上游 C 代码用的是 FFmpeg 3.x API（`avcodec_decode_video2`、`av_register_all`、
老 avfilter graph），这些在 FFmpeg 4~7 已删除。也就是说"连解码链一起移植"要么把
9 年前的 FFmpeg 用现代 NDK 交叉编译到 arm64，要么把 ~60 KB 的 FFmpeg 相关 C 代码改写到
新 API（那就不叫移植了）。

逐个文件核查后确认：**出问题的那两块（投影渲染、头追）完全不依赖 FFmpeg**。

| 上游文件 | 行数 | FFmpeg 引用 |
| --- | --- | --- |
| `xl_glsl_program.c` | 483 | 0 |
| `xl_mesh_factory.c` | 294 | 0 |
| `xl_mat4.c` | 271 | 0 |
| `xl_tracker.c` | 162 | 0 |
| `xl_video_render.c` | 55 | 0 |
| `xl_head_tracker/*`（Cardboard OrientationEKF，C++） | ~500 | 0（上游 CMake 里 `ekf` 就是不链任何库的独立 target） |
| `xl_model_vr.c` / `xl_texture.c` / `xl_model_ball.c` | ~800 | 只把 `AVFrame*` 当**不透明指针**传参；OES 路径那个参数还标了 `__attribute__((unused))` |

所以最终方案（已与需求方确认）：**移植渲染器 + 头追，解码保留 MediaCodec**。
上游 `xl_texture.c` 的 `bind_texture_oes()` 期望的正是一个 OES 纹理，
而 MediaCodec + SurfaceTexture 产出的就是它 —— 对接点是天然吻合的。

### 14.2 代码布局

```
android/app/src/main/cpp/
├── CMakeLists.txt              新增：只编渲染相关源文件，不链接任何 FFmpeg
├── compat/libavutil/frame.h    新增：FFmpeg 同名类型垫片
├── xl_vr_jni.c                 新增：EGL + 渲染循环 + JNI（替代上游 xl_player_gl_thread.c）
└── xl/                         vendored 上游源码
    ├── xl_types/{xl_macro.h, xl_video_render_types.h}   逐字不动
    ├── xl_types/xl_player_types.h                       裁剪（见下）
    ├── xl_video/{xl_mat4, xl_mesh_factory*, xl_glsl_program, xl_model, xl_model_ball*,
    │            xl_model_rect, xl_model_vr, xl_texture, xl_tracker, xl_video_render}.c/h
    └── xl_head_tracker/{Vector3d, SO3Util, Matrix3x3d, OrientationEKF, HeadTracker}.cpp/h
```

未移植：`xl_player.c`、`xl_playerCore.c`、`xl_player_read_thread.c`、
`xl_player_gl_thread.c`、`xl_container/`、`xl_decoders/`、`xl_audio/`、`xl_utils/`
—— 全是 FFmpeg 解封装/解码/音频链，按上面的决策由 Kotlin 侧
`MediaExtractor + MediaCodec + AudioTrack`（`VrEngine.kt`）承担。

### 14.3 对上游代码的三处改动

原则是"能不改就不改"，改动都带注释标明原因：

1. **`compat/libavutil/frame.h`（新增，不改上游）**
   上游渲染层只在签名里传 `AVFrame*`、只把 `enum AVPixelFormat` 当标记用；真正解引用
   字段的只有软解路径（`data/linesize/height`）和 `update_frame_*` 里的
   `format/width/linesize[0]`。垫片给出同名类型的最小定义，并把 `compat/` 放在 include
   搜索路径前面，于是 `#include <libavutil/frame.h>` 命中垫片，**上游源文件一行都不用改**。

2. **`xl_types/xl_player_types.h`（裁剪）**
   上游这个头把整个播放器状态都定义在此，并 include 了 avformat/avcodec/avfilter/
   imgutils/NdkMediaCodec。渲染层实际只用到 `xl_play_data` 的两个字段
   （`video_render_ctx`、`is_sw_decode`，见 `xl_texture.c`），所以只保留这两个，
   其余连同 FFmpeg 的 include 一起删掉。

3. **`xl_video/xl_mesh_factory.c`（扩展）+ `xl_video/xl_model_ball.c`（加一个导出口）**
   - 上游 `get_ball_mesh()` 只能生成"整幅 360° 单目"网格：经度固定 0..360、uv 固定
     [0,1]。而片源还有 180° 覆盖和 左右(SBS)/上下(TB) 立体布局，差别**只在经度范围与
     uv 区间**，顶点/索引生成方式完全一样，于是参数化为
     `xl_mesh_set_projection(coverage, u0,u1,v0,v1)`；默认值 (360,0,1,0,1) 与上游逐字一致，
     不调用时行为不变。
     唯一的语义差别：经度起点从"i=0 落在 +X"改成"贴图 u 的中点落在镜头正前方(-Z)"。
     上游那个起点是任意的，而 180° 片源**必须**让画面中心朝前，否则开机看到的是接缝。
   - 上游 `updateFov()` 是 static，只能经 `update_distance` 间接设置，而 Architecture
     那条路径把 distance 夹在 [0.5,2] ⇒ 垂直 fov 被限死在 [30,120]。加了一个
     `xl_model_set_fovy()` 直接转发给上游的 `updateFov`，语义不变，只是放开范围。

另外用 CMake 的 `-include sys/time.h -include pthread.h -include stdint.h` 补上游
依赖的间接包含（2017 年的 NDK 头文件会带进来，新 NDK 不一定），同样是为了不动上游文件。

### 14.4 `xl_vr_jni.c`：为什么必须有这一层

上游用 `xl_player_gl_thread.c` 驱动渲染，但那个循环深度绑定 `xl_play_data` 的
FFmpeg 帧队列 / 时钟 / `xl_mediacodec` / `send_message`。保留 MediaCodec 解码就必须
重写这层驱动，但**除驱动逻辑外全部调用上游函数**：

| 环节 | 来源 |
| --- | --- |
| EGL 初始化 | 照搬上游 `init_egl()`（去掉 `xl_play_data` 依赖） |
| OES 纹理 | 直接调上游 `initTexture()` 的硬解分支 |
| 视频 SurfaceTexture | 照搬上游：GL 线程内经 JNI 让 Java 侧 `SurfaceTextureBridge.getSurface(texName)` 创建，于是 `updateTexImage()` 在同一线程调用才合法（`VrSurfaceBridge.kt` 是它的对等实现） |
| 每帧 `updateTexImage` + `getTransformMatrix` | 照搬上游 `draw_video_frame()` 的硬解分支 |
| 头追 | 直接调上游 `xl_tracker_get_last_view()`（NDK 传感器线程 + Cardboard OrientationEKF，自带 33 ms 前视补偿与横屏校正矩阵 `ekf_to_head_tracker`） |
| 网格 / 着色器 / 矩阵 / 模型 | 全部上游原码 |
| 释放 | 照搬上游 `release_egl()` 的顺序，**含 `xl_glsl_program_clear_all()`** —— 上游用静态变量缓存 GL program，不清的话第二次进 VR 页面会复用已销毁上下文里的 id，直接黑屏 |

与上游唯一的行为差别：开启陀螺仪时手动俯仰依然生效。上游 `updateHead()` 只做
`modelMatrix = head; rotateY(_ry)`（手动只保留偏航），我们在组装矩阵时补一个
`rotateX`，用的仍是上游 `xl_mat4` 的函数，没有自己写矩阵运算。

「重置视角」不再调 EKF 的 reset（那是 EKF 线程持锁的内部状态，跨线程改会撕裂），
改成在 GL 线程采样当前头姿作为参考、组合矩阵时右乘它的逆（旋转矩阵的逆 = 转置），
`head == ref` 时结果就是单位阵。

### 14.5 Kotlin / Dart 侧

- `VrGlPipeline.kt` 从 797 行手写 GLES2 缩到 ~300 行转发层，**公开接口保持不变**，
  所以 `VrEngine.kt` 一行未改。属性 setter 把"绝对值"换算成增量下发（native 侧是累加的）。
- `VrHeadTracker.kt` 删除 —— 头追整个搬到 native 的上游 EKF。
  `VrPlayerBridge` 原先在每帧回调里 `tracker.drain()` 累加视角，现在改成一个 10 Hz
  主线程定时器只做读数回报（native 的 GL 循环不再有回调 Kotlin 的钩子）。
- **`flipV` 默认值从 `true` 改成 `false`**：手写渲染器自己算 uv 才需要那个补偿；
  上游直接把 `SurfaceTexture.getTransformMatrix()` 喂给着色器，方向本来就对。
  开关仍在诊断面板里，各机型 transform matrix 有差异时可以当场切。
- 诊断面板新增「左右反向 / 上下反向」两个开关（`setAxisSign`），拖动方向若反了
  不必重新打包即可确认。
- 「原画直通」改用上游的 `Rect` 模型（平面四边形），用途不变：直通有画面 ⇒ 解码与
  纹理链路是好的、问题在投影；直通仍纯色 ⇒ 问题在解码/纹理。
- `System.loadLibrary("xl_vr")` 失败时不崩，退化成"VR 不可用"并给出原因。

### 14.6 已知限制

- 180° 片源在**陀螺仪模式**下不限制偏航（手动拖动仍按 `±(coverage-fov)/2` 夹）：
  头姿是 native 里的一个旋转矩阵，要夹就得先分解出偏航角，代价与收益不匹配。
  转出覆盖范围会看到网格边缘的黑。
- 上游只有单目球面（Ball）与 Cardboard 双眼（VR，带畸变网格）两种全景模型，
  SBS/TB 是靠 14.3 的网格参数化补的，不是上游原生能力。
- 移植后**尚未经真机验证**。CI 只能证明它编得过。画面方向、投影正确性、性能
  都要靠真机 + 诊断面板确认。

## 15. 第十轮：移除独立 VR 播放器，VR 重投影移入定制 libmpv

### 15.1 需求与决策

需求方明确要求：**移除独立 VR 播放器**，参考 xl_player "在硬解之后加入后续处理"，
并且"应该需要改造使用的 mpv"。第 14 轮的移植已经把 xl_player 的渲染层
（球面网格 / Cardboard 畸变网格 / OrientationEKF 头追）搬进了 app 自带的
`libxl_vr.so`，但解码与播放控制仍是第二套栈（MediaCodec + 独立播放页），
弹幕/字幕/手势/倍速/进度全都缺失。本轮把渲染层再往前推一步——**推进 mpv 内部**：

```
改造前(第 14 轮):  MediaExtractor → MediaCodec → OES 纹理 → libxl_vr 球面渲染 → 独立播放页
改造后(本轮):      mpv 硬解(mediacodec/auto) → vo=gpu 常规渲染链(平面画面)
                     → [新增] 球面重投影 / Cardboard 分屏 → 原播放器画面
```

VR 从此就是主播放器的一种输出模式：弹幕（Flutter 层）、字幕、手势、倍速、
截图、画中画、续播、SMB/WebDAV/FTP 源……全部天然可用，也不再有
"FTP 不能进 VR""没有弹幕"这类第二栈边界。

### 15.2 mpv 补丁（tool/libmpv-vr/buildscripts/patches/mpv/vr_vo_gpu.patch）

打在 mpv v0.41.0（与上游 libmpv 构建同版本）上，只动 `vo=gpu`
（安卓端 media_kit 固定用它），不触碰 `gpu-next`：

| 文件 | 内容 |
| --- | --- |
| `video/out/gpu/vr.c/h`（新增） | VR 渲染器：球面网格生成、CPU 端 MVP 变换、单眼/Cardboard 双眼渲染、镜头畸变 pass |
| `video/out/gpu/vr_tracker.c/h`（新增） | 头追：Cardboard OrientationEKF **转写为纯 C**（Vector3d/Matrix3x3d/SO3Util/OrientationEKF 逐行对照移植）+ NDK 传感器线程（xl_tracker.c 移植，含 ALooper_pollOnce 迁移与 (-y,x,z) 轴交换、33ms 前视补偿、横屏校正矩阵） |
| `video/out/gpu/video.h` | `gl_video_opts` 追加 vr 字段 + `VR_LAYOUT_*`/`VR_PROJ_*` 枚举 |
| `video/out/gpu/video.c` | 新选项注册、渲染链末端 VR 分支、**热参数免重建**、插帧/帧缓存/OSD 门控 |
| `video/out/vo_gpu.c` | 头追开启时持续请求重绘（暂停中也能转头看） |
| `meson.build` | 新增两个源文件 |

**新 mpv 选项（即运行时属性）**：

| 属性 | 取值 | 说明 |
| --- | --- | --- |
| `vr` | yes/no | 总开关 |
| `vr-layout` | mono/sbs/tb | 片源立体布局（决定采样的 uv 区域，与 Dart 侧 `VrProjection` 一一映射） |
| `vr-projection` | 360/180 | 水平覆盖角（决定网格经度范围，切换时重建网格） |
| `vr-eye` | left/right | 单屏输出时取哪只眼 |
| `vr-stereo-output` | yes/no | Cardboard 左右分屏 + 镜头畸变输出 |
| `vr-fov` | 10~150 | **水平**视场角（度），native 内按目标宽高比换算垂直 fov（与第 11~13 轮真机验证过的 `apply_fov` 完全一致） |
| `vr-yaw` / `vr-pitch` | 度 | 手动视角偏移 |
| `vr-head-tracking` | yes/no | 启停 native 头追线程 |
| `vr-reset-view` | 递增计数 | 以当前头姿为新参考朝向（"视角摆正"） |

**关键设计点：**

1. **挂接位置**：`pass_draw_to_screen` 末端。常规渲染链（含硬解纹理采样、
   色彩转换、缩放、用户着色器、dither）先把"平面画面"完整渲染到中间纹理，
   VR 再把它投到球面输出。因此：
   - "硬解之后的后续处理"对 hwdec 完全无感——mediacodec（AImageReader→EGLImage）、
     mediacodec-copy、软解统统适用（安卓端唯一的 overlay 直通路径属于 DRM prime，不会走到）；
   - Anime4K 超分辨率与 VR **不再互斥**（用户着色器作用在平面阶段，先超分后投影）；
   - 单眼模式下 mpv 自己的 OSD/字幕仍以平面方式叠在投影画面之上（可读）；
     分屏模式跳过 OSD（横跨两只眼没法看）。
2. **热参数免重建**：`vo=gpu` 的任何选项变更默认走 `reinit_from_options()`
   → 拆掉整条渲染链重建——这正是旧用户着色器方案"改一次视角卡一下"的根源（§9.1）。
   补丁在 `gl_video_update_options()` 里做结构体级 diff：**只有 vr 字段变化时**
   直接热更新 `p->opts`，不重建任何东西；网格重建/头追启停由 `vr_sync_opts()`
   自己按需做（切 360/180 才重建网格，改 yaw/pitch/fov 只改下一帧的顶点数据）。
3. **CPU 顶点变换 + w<=0 剔除**：shader cache 的顶点级是固定的
   `gl_Position = vec4(vertex_position,1,1)` 直通（与 OSD 同一套 dispatch 机制），
   没有自定义 vertex shader 可用，所以 MVP 在 CPU 上做（5° 网格 ≈ 1.5 万顶点，
   每帧 <1ms），顶点按 mpv 的"像素坐标 + `gl_transform_ortho_fbo`"约定提交，
   flip 语义自动正确。背面/侧面三角形若有任何顶点在相机平面之后（w<=0）整体丢弃：
   在 fov<=150°（UI 上限 120°）下这类三角形与可见视锥无交集，无需真正的近平面裁剪。
4. **数学逐行对照移植**：`perspective/lookAt/rotateX/rotateY/multiply`（xl_mat4）、
   球面网格（get_ball_mesh + 第 14 轮的 coverage/uv 参数化，v 轴按 mpv 纹理
   "行 0 = 画面顶部"约定翻转）、Cardboard 畸变网格（get_distortion_mesh 原样，
   含色散 r/g/b 三套 uv 与 vignette；v 同样翻转）、模型矩阵组装顺序
   （头追开：`head × ref⁻¹ × rotY(yaw) × rotX(pitch)`；关：`rotX(pitch) × rotY(yaw)`）
   ——与第 11~13 轮真机验证过的 native 播放器一致，手感不变。
   分屏的双眼内参沿用上游：fovy=60°、眼距 ±0.012、近平面 0.01/远平面 100。
5. **头追线程**只在 Android 编入实现（`libandroid` 在 mpv 安卓构建里本来就链接），
   其它平台 `vr_tracker_create()` 返回 NULL、选项静默降级为手动环视；
   EKF 与传感器循环都有互斥保护，`gl_video_uninit` 时 join 线程，无泄漏。
6. 头追开启时 `vo_gpu.draw_frame` 置 `want_redraw`，暂停中转动设备画面也跟随；
   同时 VR 模式禁用"静止帧缓存 blit"与插帧（缓存会把视角冻在上一帧）。

### 15.3 构建管线（tool/libmpv-vr + .github/workflows/libmpv_vr.yml）

沙盒（2 vCPU）不可能交叉编译 ffmpeg+mpv，全部交给本仓库 CI：

- `tool/libmpv-vr/buildscripts/` 逐字取自
  My-Responsitories/libmpv-android-video-build **`8e50ecc`**——即 app 当前锁定的
  `20260906` jar 的构建状态（mpv 0.41.0 / ffmpeg n9.0.1 / NDK r29 / default flavor），
  只裁掉与产物无关的克隆（libvpx、x264、fftools_ffi、media_kit、android-helper）
  和另外两个 flavor。**不用上游 9 月 30 日之后的状态**：那之后上游删了
  h263/mpeg2/wmv/alac 等解码器并去掉了 helper .so，与本 app 的既有能力不匹配。
- `patches/mpv/`：上游原有的 `mpv_lavc_set_java_vm.patch` + 本次的
  `vr_vo_gpu.patch`（按字母序应用，互不重叠）。
- **jar 组装走"换心"而不是全量重建**：下载上游 `20260906` 的
  `default-arm64-v8a.jar`（校验 sha256），仅替换 `lib/arm64-v8a/libmpv.so`，
  `libmedia_kit_native_event_loop.so` / `libmediakitandroidhelper.so` 逐字节保留
  ——app 运行时唯一的变量就是 mpv 本体。构建脚本还会 `strings` 验证
  `vr-head-tracking` 已编进 .so，防止补丁没打上就出包。
- 产物发布到**本仓库**滚动 release `libmpv-vr`（PAT 只能操作本仓库，
  建外部仓库会被 403 拒绝——见 15.4）。deps/prefix 有 actions/cache：
  只改补丁时约 5~8 分钟出包，全量约 25~35 分钟。

### 15.4 应用侧接入

- **vendored `third_party/media_kit_libs_android_video/`**：从 media-kit fork
  （ref native @ 73771ec）原样复制，唯一改动是 `android/build.gradle`：
  arm64-v8a jar 改从本仓库 `libmpv-vr` release 下载（滚动资产无法钉 sha256，
  构建日志会打印实际校验和，且其上游底包在构建时已验 sha）；
  armeabi-v7a / x86_64 仍用上游 20260906 + sha256 钉死。
  `pubspec.yaml` 的 override 相应改为 path 依赖（lock 已同步）。
  曾经尝试把两个构建仓库 fork 到账号下再推送，但**当前 PAT 只授权了
  PiliPlus 一个仓库**：建仓成功、推送/删仓 403，所以管线全部收进本仓库
  （账号下遗留了两个空仓库 `libmpv-android-video-build`、`media-kit`，
  本 token 无权删除，需要手动清理）。
- **运行时探测**：播放器创建后读一次 `vr` 属性（补丁版返回 yes/no，
  未打补丁返回空串）→ `vrMpvSupported`。不支持时 VR 入口明确提示，
  不会静默失效；`setProperty` 对未知属性静默忽略，误发也无害。
- **Dart 侧协议**：`PlPlayerController` 的视角/布局状态（`vrView`、
  `vrProjection`、`vrEye`、`vrStereoOutput`、`vrGyroEnabled`）原样保留，
  `_applyVrProperties()` 把它们翻译成上表的属性直写 mpv（同步 FFI，
  一轮十来个调用，30ms 节流 + 手势结束尾随下发）。**没有量化、没有变体预算、
  没有着色器文件**——第三、四轮的那套妥协（§9.1）整体删除。
  拖拽/缩放/方向键/摆正/眼位/分屏的手势与 UI（`VrControlLayer`）不变，
  新增"立体分屏输出"按钮与设置项。
- **删除**：`VrEngine.kt`/`VrGlPipeline.kt`/`VrPlayerBridge.kt`/`VrSurfaceBridge.kt`、
  `android/app/src/main/cpp/**`（libxl_vr 及其 CMake）、`vr_player_page.dart`、
  `vr_native_player.dart`、`vr_shader.dart`、`vr_gyro*.dart`、sensors_plus 依赖、
  `LocalMediaService.nativeHeaders/nativePlayerCanPlay`（MediaExtractor 专用，已无调用方）、
  设置项「VR 使用独立播放器」（换成「VR 立体分屏输出」）。
  xl_player 的移植成果没有浪费——它们以 C 转写的形式活在 mpv 补丁里。

### 15.5 已知边界

- 桌面端（Windows/Linux/macOS）的 libmpv 来自 pub.dev 的 media_kit_libs_*，
  未打补丁 → VR 明确提示不可用（VR 本来就是安卓 scope）。
- 分屏（Cardboard）模式无 mpv OSD/字幕；单眼模式字幕保持平面叠加。
- 畸变网格用的是上游写死的 Cardboard 2015 参数（与 xl_player 相同），
  不同头显的光学参数不完全匹配，但可用。
- 头追仍是"陀螺仪+加速度计"的 OrientationEKF（无磁力计），长时间有慢漂，
  「视角摆正」复位——与第 14 轮移植一致。
- **未经真机验证**：沙盒只能做 CI 编译验证 + 数学/约定逐行对照。
  几何约定（v 翻转、flip、w 剔除、fov 换算）全部推导自 mpv v0.41.0 源码与
  前几轮真机结论，若真机出现上下颠倒/镜像，优先怀疑 §15.2 第 3 点的
  flip 约定，vr.c 内已集中注释。

### 15.6 本轮验证

- 补丁在 pristine mpv v0.41.0 上 `git apply --check` 通过（与 java-vm 补丁叠加次序一致）；
- 新增/改动文件在沙盒内以真实头文件树（ffmpeg n7.1 头 + libplacebo v7.360.1 头
  + 手写 config.h/NDK sensor 桩）做 `gcc -fsyntax-only -Wall`：vr.c、vr_tracker.c
  （android 与非 android 两条路径）、video.c、vo_gpu.c 全部 0 error 0 新 warning；
- CI：libmpv 工作流出包（含 strings 自检）→ app 工作流 analyze/test/release 构建，
  结果见对应 run 与 release `v2.1.5-test`。

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

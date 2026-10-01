# libvlc-pvr — PiliPlus 定制 libvlc（VR 投影扩展）

本目录维护 PiliPlus 本地板块所使用的 **定制 libvlc Android AAR** 的构建材料。
仓库中只保存 **补丁与构建脚本**，不保存任何二进制或上游源码，VLC/libvlcjni
源码在 CI 构建时按固定版本拉取（不污染仓库历史，可复现、可持续维护）。

## 为什么需要定制 libvlc

官方 libvlc 3.x 的 VR/360 能力只有「按片源元数据渲染 360° 单目」：

- 立体布局（左右 SBS / 上下 TB）写死只取左眼，不可切换；
- 不支持 180° 片源（半球投影）；
- 无元数据的片源无法手动强制全景模式。

PiliPlus 需要的矩阵是：**水平覆盖 360°/180° × 立体布局 单目/SBS/TB**，
外加「自动（按元数据）」与「强制平面（2D）」，并且要求 **播放中原位切换**
（不重启播放、不丢失进度）。为此对 VLC 的 OpenGL vout（`vout_helper.c`）
及控制链路打了补丁，新增：

| 能力 | 实现 |
| --- | --- |
| 投影模式覆盖 | `auto / flat / 360 / 180`，180° 为前半球网格（新增） |
| 立体布局覆盖 | `auto / mono / SBS / TB`，自动模式读取 `multiview_mode` 元数据 |
| 眼位选择 | 左/右眼纹理裁剪偏移，可运行时切换 |
| 180° 视角收敛 | `SetViewpoint` 中按水平/垂直 FOV 钳制 yaw/pitch，转不出画面 |
| 运行时原位切换 | 新控制命令 `VOUT_DISPLAY_CHANGE_VR_MODE`，切换不重启播放 |
| 新 libvlc API | `libvlc_media_player_set_vr_mode()`、`libvlc_pili_vr_version()` |
| Java/JNI 暴露 | `MediaPlayer.setVrMode(projection, stereo, eye)`、`MediaPlayer.getVrVersion()` |

`getVrVersion()` 在原版（未打补丁）引擎上抛 `UnsatisfiedLinkError` 并返回 0，
应用层据此明确提示「当前引擎不具备 VR 能力」，不会静默失效。

## 版本锁定

| 组件 | 版本 |
| --- | --- |
| VLC core | `3.0.x` @ `84177b2273abc5c4300234e6e18b55a4d2dd5a03`（GitHub 镜像 tarball） |
| libvlcjni | `libvlcjni-3.x` @ `0b8dc65efb203c86a0476bc337ddd99ecf1c0ef6`（VideoLAN GitLab REST 归档，对应已发布 `libvlc-all 3.7.7`） |
| 官方补丁系列 | libvlcjni `libvlc/patches/*.patch`（20 个，含 smb2/upnp/fast-seek 等，`git am` 应用） |
| 预编译 contribs | `vlc-contrib-aarch64-linux-android-58f19304….tar.zst`（artifacts.videolan.org，存在则用，否则源码编译） |
| PiliPlus 补丁 | `patches/vlc/`、`patches/libvlcjni/`（`git apply` 应用在官方补丁之后） |

## 构建

```sh
# 需要：ANDROID_NDK(r27-29)、gradle 9.x、JDK 17+、autotools、zstd
export ANDROID_NDK=/path/to/ndk
./build-aar.sh arm64
# 产物：build-libvlc/libvlcjni/libvlc/build/outputs/aar/libvlc-arm64-v8a-3.7.7.aar
```

CI（`/.github/workflows/piliplayer_libvlc.yml`）在本目录或 workflow 变更时自动
构建，并将产物以固定名 `libvlc-pvr-arm64-v8a.aar`（+ `.sha256` + `BUILD-INFO.txt`）
发布到滚动 release tag **`libvlc-pvr`**（每次覆盖）。应用 CI 从该 release 下载
AAR 放入 `android/app/libs/`，本地文件不存在时自动回退到 Maven Central 的官方
`org.videolan.android:libvlc-all:3.7.7`（此时 VR 扩展不可用，应用内会明确提示）。

## 补丁维护

- 修改补丁：在本地对 `build-libvlc/libvlcjni/{vlc,}` 树直接改代码，然后
  `git diff > patches/vlc/0001-*.patch` 重新生成（vlc 树需先按脚本流程应用
  官方补丁系列，保证 diff 基线一致）。
- 升级基线：更新 `build-aar.sh` 中三个 SHA 与 contrib URL，重新生成补丁并
  解决冲突。

## 许可

VLC/libvlc 以 LGPL-2.1 发布；本补丁不改变许可方式。AAR 中的 `libvlc.so`
由应用动态加载（`System.loadLibrary`），符合 LGPL 动态链接要求。补丁源码
（本目录）随仓库以相同条款提供，上游源码可按上述锁定版本公开获取。

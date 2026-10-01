# libmpv-vr — VR 版 libmpv (arm64-v8a) 构建

本目录为 PiliPlus `piliplayer` 分支构建**带 VR/全景重投影的 libmpv.so**，
产物是 media_kit 安卓端使用的 `default-arm64-v8a.jar`（滚动 release tag
`libmpv-vr`），由 `.github/workflows/libmpv_vr.yml` 在 CI 里构建发布，
应用侧通过 `third_party/media_kit_libs_android_video`（vendored 包）引用。

## 来源与基线

- `buildscripts/` 逐字取自
  [My-Responsitories/libmpv-android-video-build](https://github.com/My-Responsitories/libmpv-android-video-build)
  提交 `8e50ecc` —— 即应用当前锁定的 `20260906` release 的构建状态
  （mpv v0.41.0 / ffmpeg n9.0.1 / libplacebo 7.360.1 / NDK 29，default flavor）。
  只做了两处裁剪：`include/download-deps.sh` 去掉了与本次产物无关的克隆
  （libvpx / libx264 / fftools_ffi / media_kit / media-kit-android-helper /
  shaderc 占位），并移除了 encoders-gpl、full 两个 flavor 的 bundle/patch 脚本。
- `buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch`：上游原有补丁
  （media_kit 需要的 `mpv_lavc_set_java_vm` 导出），原样保留。
- `buildscripts/patches/mpv/vr_vo_gpu.patch`：**本次新增**。给 mpv 的
  `vo=gpu` 加 VR 重投影（在硬解与常规渲染链之后、输出之前，把合成好的
  平面画面投到球面网格上），渲染数学与头部追踪移植自
  [xl_player](https://github.com/xl-player-developers/xl_player)
  （球面网格 / Cardboard 畸变网格 / OrientationEKF 头追，EKF 已转写为 C）。
  新增 mpv 选项（也是运行时属性）：
  `vr`、`vr-layout`(mono/sbs/tb)、`vr-projection`(360/180)、`vr-eye`(left/right)、
  `vr-stereo-output`、`vr-fov`(水平视场角,度)、`vr-yaw`、`vr-pitch`、
  `vr-head-tracking`、`vr-reset-view`(递增计数触发回正)。
  视角参数是"热"参数：变更不触发渲染链重建（见 patch 内
  `only_vr_opts_changed`），头追在 native 侧逐帧运行，不经 Dart 往返。

## jar 组装策略

不重新构建 media_kit 的 event-loop / android-helper：`bundle_vr_arm64.sh`
下载上游 `20260906` 的 `default-arm64-v8a.jar`（校验 sha256），只把其中
`lib/arm64-v8a/libmpv.so` 换成本次构建产物，其余 `.so` 逐字节保留。
这样应用运行时的唯一变化就是 mpv 本体，风险面最小。

## 本地重建

沙盒（2 vCPU）无法承担全量交叉编译，请在 CI 触发：

- push 到 `piliplayer` 且改动 `tool/libmpv-vr/**` 会自动构建并发布；
- 或手动 `workflow_dispatch`（可选是否发布）。

deps/prefix 有 actions/cache：只改 mpv 补丁时约 5-8 分钟出包，全量约 25-35 分钟。

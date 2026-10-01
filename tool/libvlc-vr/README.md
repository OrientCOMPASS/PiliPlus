# libvlc-vr —— VR 增强版 libvlc (arm64-v8a) 构建管线

给官方 `libvlc-all:3.7.6` 打上 VR 补丁后重新构建 arm64-v8a 的 native 库,
再以「换心」方式组装回官方 AAR(其余 ABI、classes.jar、assets、res 逐字节保留)。
产物发布到本仓库滚动 release **`libvlc-vr`**, app 的 gradle
(`android/app/build.gradle.kts`)按 sha256 钉死下载。

设计沿革与决策记录见 `docs/piliplayer.md` §18;整体模式沿用第十轮的
`tool/libmpv-vr`(补丁入库 + CI 按需拉源码 + 滚动 release + 换心)。

## 版本锁定(与官方 libvlc-all 3.7.6 完全同源)

| 组件 | 来源 | 锁定版本 |
| --- | --- | --- |
| vlc-android 构建脚本参照 | github.com/videolan/vlc-android | tag `libvlc-3.7.6` |
| libvlcjni(JNI 层 + vlc 补丁集) | code.videolan.org/videolan/libvlcjni | branch `libvlcjni-3.x` @ `c0cc8ce6443dcb09be9b43c7b7a3ed01e33cb3ac`(**vendored 于本目录**) |
| vlc core | github.com/videolan/vlc(官方镜像) | branch `3.0.x` @ `66455a98c8c515796b4a192acaa125c5d68c76c8`(CI 按需克隆) |
| contribs 预编译包 | artifacts.videolan.org | `vlc-contrib-aarch64-linux-android-4d08fe2a37bfba5ea223758ecd033b15ca53400d.tar.zst`(sha 即 vlc 锁定 commit 的 contrib 状态, 由 vlc 源码内 `extras/ci/get-contrib-sha.sh` 规则算出) |
| 官方底包 AAR | repo1.maven.org | `libvlc-all-3.7.6.aar`,sha256 `6b438ab75eb3b307d9699f4594c043f46b0a9a697521bd03729c02c0a400eb8a` |
| 构建容器 | registry.videolan.org | `vlc-debian-android:20260610055743`(VideoLAN 官方 CI 构建 arm64 libvlc 所用镜像, 内含 NDK r27-r29 与全部构建依赖) |

**为什么 vendored libvlcjni 而不是 CI 现拉**:code.videolan.org 部署了 Anubis
反爬,git clone 对数据中心 IP(沙盒与 GitHub runner 均实测)直接拒绝;
libvlcjni 只有 ~1.2MB,入库一劳永逸。vlc core(数百 MB)则从 GitHub 官方镜像
按需克隆,不入库。

**为什么不直接用 vlc-android 的 compile.sh**:它写死的预编译 contribs URL 是
`.tar.bz2`,而 artifacts 服务器 2026-09 起只发布 `.tar.zst`,check-url 404 后会
静默退化成 1~2 小时的 contribs 源码编译。本管线直接调 libvlcjni 的
`buildsystem/compile-libvlc.sh --with-prebuilt-contribs` 并显式传
`VLC_PREBUILT_CONTRIBS_URL`(zst 地址),contribs 阶段只剩下载+解包(~2 分钟)。

## 补丁

`patches/vlc/0001-opengl-add-VR-projection-layout-coverage-eye-options.patch`
(git format-patch 生成,带 Message-Id,`git am --message-id` 应用;叠加在
libvlcjni 自带的 20 个补丁之后,互不重叠):

新增 4 个 vout display 选项(可作 LibVLC 参数,也可作**单条 media 选项**
`Media.addOption(":vr-layout=2")` 下发——经 input 对象变量沿
display→vout→input 链继承,已在 `src/misc/variables.c`/`src/input/item.c` 核实):

| 选项 | 取值 | 语义 |
| --- | --- | --- |
| `vr-projection` | 0/1/2 | 0=跟随元数据(默认);1=强制等距柱状(进入环视);2=强制平面 |
| `vr-layout` | 0/1/2/3 | 0=跟随元数据;1=单目(不做眼位裁剪);2=左右(SBS);3=上下(TB) |
| `vr-coverage` | 360/180 | 等距柱状水平覆盖角(180=半球顶),默认 360 |
| `vr-eye` | 0/1 | SBS/TB 取左眼(默认)还是右眼 |

实现要点(细节见补丁内注释):

1. `display.c Open()` 在 `vout_display_opengl_New()` **之前**改写
   `vd->fmt.projection_mode/multiview_mode`,于是纹理转换程序、视点初始化、
   网格选择全部一致地看到覆盖结果;coverage/eye 在 New 之后经
   `vout_display_opengl_SetVrParams()` 写入(两者只在出图建网格/裁剪纹理时消费);
2. `BuildSphere()` 覆盖角参数化:经度窗口 `[π-cov/2, π+cov/2]`,以 phi=π 为
   中心(u=0.5 恰好在初始视角正前方,与 `SetViewpoint` 的 `yaw-π/2` 约定吻合);
   cov=2π 时与上游几何逐点一致;
3. 顺手修了上游 bug:`BuildSphere()` 的纹理坐标原来只乘窗口宽高、**没加
   left/top 偏移**,导致右眼窗口采样到的是左眼像素(未裁剪源 left=top=0 不受
   影响);`BuildRectangle`/`BuildCube` 一直是加偏移的,球面路径与之对齐;
4. `TextureCropForStereo()` 眼位从写死左眼改为按 `vr-eye` 选择(该函数在
   平面/球面两条路径共用,平面 SBS/TB 源同样受益);
5. `lib/core.c`:`libvlc_get_changeset()` 返回 `"piliplus-vr1"` 作为运行时特性
   探测标记(Kotlin `LibVLC.changeset()` 一读便知是否 VR 版;真实上游 revision
   仍由启动日志 `revision %s` 输出)。

## CI

`.github/workflows/libvlc_vr.yml`:push 触及本目录或手动 dispatch 触发。
容器内:克隆 vlc(GitHub 镜像, 锁定 hash)→ `git am` libvlcjni 20 补丁 +
本目录 VR 补丁 → `compile-libvlc.sh -a arm64-v8a --with-prebuilt-contribs
--release` → 官方 AAR(sha256 校验)换心 3 个 .so(libvlc/libvlcjni/
libc++_shared)→ `strings` 自检(`vr-coverage`、`piliplus-vr1` 必须编进
libvlc.so)→ 发布到滚动 release `libvlc-vr`。

资产名固定为 `libvlc-all-3.7.6-pvr1-arm64-v8a.aar`:**同名资产内容永不变更**
(补丁迭代一律升 `pvr2`、`pvr3`…),因此 app 侧 gradle 可以 sha256 钉死。

## 本地复现(不在沙盒内做,仅供参考)

```sh
# 需要 docker 与 ~10GB 磁盘;产物在 tool/libvlc-vr/output/
docker run --rm -it -v "$PWD:/w" -w /w/tool/libvlc-vr \
  registry.videolan.org/vlc-debian-android:20260610055743 bash
# 容器内按 .github/workflows/libvlc_vr.yml 的步骤执行
```

## 许可

vlc / libvlcjni 为 LGPL-2.1+ (LICENSE 随 vendored 目录保留);本目录补丁同样
以 LGPL-2.1+ 发布。构建产物 AAR 的其余部分与官方 libvlc-all 一致。

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/pages/local_media/library.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/services/smb/smb_discovery.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/permission_handler.dart' show openAppSettings;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块(顶层 Tab 之一): 本机媒体库 + 局域网。
///
/// 组织方式参照 VLC 安卓版:
///   * 媒体库: 扫描本机文件并**按文件夹排列**, 点进去就是该文件夹的播放列表
///   * 网络: 自动发现局域网里的 SMB 主机, 也可手动添加 SMB/WebDAV/HTTP/FTP
class LocalMediaPage extends StatefulWidget {
  const LocalMediaPage({super.key});

  @override
  State<LocalMediaPage> createState() => _LocalMediaPageState();
}

class _LocalMediaPageState extends State<LocalMediaPage>
    with
        SingleTickerProviderStateMixin,
        AutomaticKeepAliveClientMixin,
        WidgetsBindingObserver {
  /// `putOrFind` 而不是 `put`: 顶层 Tab 页会被 MainApp 的 TabBarView 反复重建,
  /// `put` 每次都会把控制器(连同扫描结果)整个换掉。
  final _controller = Get.putOrFind(LocalMediaController.new);
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );

  /// 与其它顶层板块(首页/动态/我的)一致: 切走再切回来不丢滚动位置与 Tab
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // TabController 不是响应式的, 切 Tab 时用 setState 刷新右上角动作按钮
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (mounted) {
      setState(() {});
    }
    // 切回「媒体库」: 缓存过期就静默补扫(控制器的 onInit 一个进程只跑
    // 一次, 覆盖不到"拷完文件再切回来"的场景)
    if (_tabController.index == 0) {
      _controller.onResumed();
    }
  }

  /// 应用回前台: 用户很可能刚用电脑/文件管理器拷了新视频进来,
  /// 缓存过期就静默补扫, 并刷新"部分访问"权限提示
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.onResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    // 这里必须用真正的 `Scaffold` 而不是 `SimpleScaffold`:
    //
    // `SimpleScaffold` 用 `BoxConstraints.tightFor(width: ...)`(即**高度无界**)
    // 去测量 appBar 槽位。不带 bottom 的 AppBar 恰好能自适应高度, 但带
    // `bottom`(TabBar) 的 AppBar 内部是
    // `Column(mainAxisSize: max, mainAxisAlignment: spaceBetween)` + `Flexible`,
    // 高度无界时直接抛 "RenderFlex children have non-zero flex but incoming
    // height constraints are unbounded", 整页布局失败 -> 板块一片空白。
    // Flutter 自带的 `Scaffold` 会先用 `AppBar.preferredHeightFor` 把 appBar
    // 槽位夹成有限高度, 所以 AppBar + bottom 在它是正常的。
    //
    // `primary: false`: 本页是顶层 Tab, `MainApp` 已经统一加过状态栏内边距
    // (见 lib/pages/main/view.dart 的 padding), AppBar 再加一次会多出一条空白。
    // 同样的写法见 lib/pages/dynamics/view.dart。
    return Scaffold(
      primary: false,
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        primary: false,
        title: const Text('本地'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: '媒体库'), Tab(text: '网络')],
        ),
        actions: [
          if (_tabController.index == 0)
            Obx(
              () => IconButton(
                tooltip: '重新扫描本机文件',
                onPressed: _controller.library.scanning.value
                    ? null
                    : _controller.rescanLibrary,
                icon: const Icon(Icons.refresh),
              ),
            )
          else
            Obx(
              () => IconButton(
                tooltip: '扫描局域网 SMB 主机',
                onPressed: _controller.scanningNetwork.value
                    ? null
                    : _controller.discoverNetwork,
                icon: const Icon(Icons.wifi_find_outlined),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildLibrary(context), _buildNetwork(context)],
      ),
    );
  }

  // ==================== 媒体库 ====================

  Widget _buildLibrary(BuildContext context) {
    final library = _controller.library;
    return Obx(() {
      final scanning = library.scanning.value;
      final folders = library.folders;
      final children = <Widget>[];

      if (scanning) {
        children.add(
          ListTile(
            leading: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: const Text('正在扫描本机文件…'),
            subtitle: Text(
              '已发现 ${folders.length} 个文件夹 / ${library.scannedFiles.value} 个文件',
            ),
          ),
        );
      }

      // 安卓 14+「选择照片和视频」部分访问: 未勾选的文件根本不可见,
      // 必须明说, 不能让用户以为是列表在"过滤"文件
      if (_controller.accessNotice.value case final notice? when !scanning) {
        children.add(
          ListTile(
            leading: const Icon(Icons.lock_person_outlined),
            title: const Text('存储权限为「部分访问」'),
            subtitle: Text('$notice可在系统设置中改为「允许访问全部」。'),
            trailing: const TextButton(
              onPressed: openAppSettings,
              child: Text('去设置'),
            ),
          ),
        );
      }

      // 扫描触到上限: 结果不完整也要明说(不静默吞文件)
      if (!scanning && library.truncated.value) {
        children.add(
          const ListTile(
            leading: Icon(Icons.warning_amber_rounded),
            title: Text('扫描已达上限，结果可能不完整'),
            subtitle: Text(
              '本机文件过多, 只列出了前面一部分; '
              '找不到的文件请用上方「存储卷」直接浏览目录',
            ),
          ),
        );
      }

      // 直接浏览存储卷(不只是有视频的文件夹)
      for (final source in _controller.deviceSources) {
        children.add(
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(source.name),
            subtitle: Text(source.url),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _controller.openDevice(source),
          ),
        );
      }

      // 本机目录的书签(在浏览页里手动收藏的), 与 VLC 的 bookmark 一致
      final shortcuts = _controller.deviceShortcuts;
      if (shortcuts.isNotEmpty) {
        children
          ..add(const Divider(height: 24))
          ..add(
            const ListTile(
              leading: Icon(Icons.bookmark_border),
              title: Text('快捷方式'),
              subtitle: Text('浏览目录时点右上角书签收藏到这里'),
            ),
          );
        for (final source in shortcuts) {
          children.add(_buildSource(context, source));
        }
      }

      if (!scanning && folders.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
            child: Column(
              spacing: 12,
              children: [
                const Icon(Icons.video_library_outlined, size: 56),
                Text(
                  library.lastError.value ?? '还没有扫描到本机文件',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                FilledButton.tonalIcon(
                  onPressed: _controller.rescanLibrary,
                  icon: const Icon(Icons.search),
                  label: const Text('扫描本机文件'),
                ),
              ],
            ),
          ),
        );
      }

      for (final folder in folders) {
        children.add(_buildFolder(context, folder));
      }

      return ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: children,
      );
    });
  }

  Widget _buildFolder(BuildContext context, LocalMediaFolder folder) {
    final subtitle = <String>[
      '${folder.count} 个文件',
      CacheManager.formatSize(folder.totalSize),
      if (folder.latest case final latest?) _formatDate(latest),
      folder.path,
    ].join(' · ');
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _controller.openFolder(folder),
    );
  }

  // ==================== 网络 ====================

  Widget _buildNetwork(BuildContext context) {
    return Obx(() {
      final children = <Widget>[];
      final scanning = _controller.scanningNetwork.value;

      children.add(
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('局域网 SMB 主机'),
          subtitle: Text(
            scanning
                ? '扫描中 ${_controller.scanDone.value}/${_controller.scanTotal.value}'
                : _controller.discovered.isEmpty
                ? '尚未扫描；点右上角按钮自动发现同一局域网内开启 SMB 的主机'
                : '发现 ${_controller.discovered.length} 台',
          ),
          trailing: scanning
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_find_outlined),
          onTap: scanning ? null : _controller.discoverNetwork,
        ),
      );

      if (_controller.networkError.value case final err?) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Text(
              err,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        );
      }

      for (final host in _controller.discovered) {
        children.add(_buildHost(context, host));
      }

      children
        ..add(const Divider(height: 24))
        ..add(
          const ListTile(
            leading: Icon(Icons.bookmark_border),
            title: Text('快捷方式'),
            subtitle: Text(
              '连接过的主机与收藏的目录；SMB / WebDAV 可浏览，HTTP / FTP 为直链',
            ),
          ),
        );
      for (final source in _controller.networkShortcuts) {
        children.add(_buildSource(context, source));
      }
      children.add(
        ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text('添加网络共享'),
          onTap: () => _controller.addSourceFromDialog(context),
        ),
      );

      return ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: children,
      );
    });
  }

  Widget _buildHost(BuildContext context, SmbHost host) {
    return ListTile(
      leading: const Icon(Icons.computer_outlined),
      title: Text(host.displayName),
      subtitle: Text(
        '${host.address}:${host.port}'
        '${host.name == null ? '' : ' · 点击进入主机，共享为其中的子目录'}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _controller.openDiscoveredHost(context, host),
    );
  }

  Widget _buildSource(BuildContext context, LocalMediaSource source) {
    final subtitle = source.type == LocalMediaSourceType.device
        ? source.url
        : LocalMediaService.maskedUrl(source.url);
    return ListTile(
      leading: Icon(_sourceIcon(source.type)),
      title: Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        source.canBrowse ? Icons.chevron_right : Icons.play_arrow_outlined,
      ),
      onTap: () => _controller.openSource(source),
      onLongPress: () => _showSourceMenu(context, source),
    );
  }

  IconData _sourceIcon(LocalMediaSourceType type) => switch (type) {
    LocalMediaSourceType.device => Icons.smartphone_outlined,
    LocalMediaSourceType.smb => Icons.folder_shared_outlined,
    LocalMediaSourceType.webdav => Icons.cloud_outlined,
    LocalMediaSourceType.http => Icons.language_outlined,
    LocalMediaSourceType.ftp => Icons.swap_vert_outlined,
  };

  void _showSourceMenu(BuildContext context, LocalMediaSource source) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(source.name),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (source.canBrowse)
              ListTile(
                dense: true,
                leading: const Icon(Icons.wifi_tethering_outlined),
                title: const Text('测试连接'),
                onTap: () async {
                  Navigator.of(dialogContext).pop();
                  SmartDialog.showLoading(msg: '连接中');
                  final res = await LocalMediaService.testConnection(source);
                  SmartDialog.dismiss();
                  switch (res) {
                    case Success(:final response):
                      SmartDialog.showToast('连接成功，$response 个条目');
                    case Error(:final errMsg):
                      SmartDialog.showToast(errMsg ?? '连接失败');
                    case _:
                      break;
                  }
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () async {
                Navigator.of(dialogContext).pop();
                await _controller.editSource(context, source);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _controller.removeSource(source);
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}

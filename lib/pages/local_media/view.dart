import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:PiliPlus/pages/local_media/browse_page.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/pages/local_media/folder_page.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块(顶层 Tab 之一): 本机媒体库 + 局域网。
///
/// 第十二轮起由 VLC 引擎驱动(docs/piliplayer.md §17):
///   * 媒体库: libmedialibrary 自动索引本机视频, 按文件夹归组(参照 VLC 安卓版),
///     续播位置由 libml 原生持久化;
///   * 网络: libvlc MediaBrowser 发现/浏览 smb、ftp、nfs、upnp,
///     不再依赖 Dart 侧 SMB2 客户端与回环代理;
///   * 播放: 统一进 [VlcPlayerPage](libvlc 硬解 + 原生 360°)。
class LocalMediaPage extends StatefulWidget {
  const LocalMediaPage({super.key});

  @override
  State<LocalMediaPage> createState() => _LocalMediaPageState();
}

class _LocalMediaPageState extends State<LocalMediaPage>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
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
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (mounted) {
      setState(() {});
    }
    // 首次切到网络 Tab 时自动发现一次
    if (_tabController.index == 1 &&
        _controller.shares.isEmpty &&
        !_controller.discovering.value) {
      _controller.discoverShares();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isNetworkTab = _tabController.index == 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: '媒体库'), Tab(text: '网络')],
        ),
        actions: [
          if (!isNetworkTab) ...[
            GestureDetector(
              // 长按 = 强制全盘重建索引(libml forceRescan)
              onLongPress: () => _controller.rescan(full: true),
              child: IconButton(
                tooltip: '重新扫描(长按: 全盘重建)',
                icon: Obx(
                  () => _controller.library.busy.value
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
                onPressed: () => _controller.rescan(),
              ),
            ),
            PopupMenuButton<VlcMediaSort>(
              tooltip: '排序',
              icon: const Icon(Icons.sort),
              initialValue: _controller.sort.value,
              onSelected: _controller.setSort,
              itemBuilder: (context) => [
                for (final s in VlcMediaSort.values)
                  PopupMenuItem(value: s, child: Text(s.label)),
              ],
            ),
          ] else ...[
            IconButton(
              tooltip: '重新发现局域网共享',
              icon: Obx(
                () => _controller.discovering.value
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
              ),
              onPressed: _controller.discoverShares,
            ),
            IconButton(
              tooltip: '添加共享',
              icon: const Icon(Icons.add_link),
              onPressed: () => _showAddShareDialog(context),
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLibraryTab(context),
          _buildNetworkTab(context),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 媒体库

  Widget _buildLibraryTab(BuildContext context) {
    return Obx(() {
      final library = _controller.library;
      if (library.lastError.value case final err? when _controller.videos.isEmpty) {
        return _EmptyHint(
          icon: Icons.error_outline,
          text: err,
          actionLabel: '重试',
          onAction: _controller.bootstrap,
        );
      }
      if (_controller.videos.isEmpty) {
        if (library.busy.value) {
          return const _EmptyHint(
            icon: Icons.travel_explore,
            text: 'VLC 正在索引本机视频…\n(边扫边出, 稍后自动刷新)',
          );
        }
        return _EmptyHint(
          icon: Icons.video_library_outlined,
          text: '还没有索引到视频\n下拉或点右上角刷新开始扫描',
          actionLabel: '扫描',
          onAction: () => _controller.rescan(),
        );
      }
      final groups = _controller.folderGroups();
      return RefreshIndicator(
        onRefresh: () => _controller.refreshVideos(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (_controller.history.isNotEmpty) ...[
              const _SectionTitle('最近播放'),
              for (final h in _controller.history.take(6))
                VideoTile(
                  item: h,
                  onTap: () => _controller.playUri(h.uri, h.displayName),
                ),
              const Divider(height: 18),
            ],
            const _SectionTitle('文件夹'),
            for (final g in groups)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${g.count} 个视频 · 共 '
                  '${DurationUtils.formatDuration(g.totalLengthMs ~/ 1000)}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Get.to(
                    () => LocalFolderPage(folderPath: g.path, folderName: g.name),
                  )?.then((_) => _controller.refreshVideos());
                },
              ),
          ],
        ),
      );
    });
  }

  // ---------------------------------------------------------------- 网络

  Widget _buildNetworkTab(BuildContext context) {
    return Obx(() {
      final saved = _controller.savedShares;
      final shares = _controller.shares;
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_controller.networkError.value case final err?)
            ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.redAccent),
              title: Text(err, style: const TextStyle(fontSize: 13)),
            ),
          const _SectionTitle('已保存的共享'),
          if (saved.isEmpty)
            const ListTile(
              leading: Icon(Icons.bookmark_border),
              title: Text(
                '右上角「添加共享」可保存 smb://user:pass@host/share 之类的地址',
                style: TextStyle(fontSize: 13),
              ),
            )
          else
            for (final s in saved)
              ListTile(
                leading: const Icon(Icons.bookmark),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  s.maskedUri,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Get.to(
                  () => VlcBrowsePage(rootUri: s.uri, rootTitle: s.name),
                ),
                onLongPress: () => _showSavedShareMenu(context, s),
              ),
          const Divider(height: 22),
          const _SectionTitle('局域网共享 (SMB)'),
          if (_controller.discovering.value && shares.isEmpty)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('正在发现…', style: TextStyle(fontSize: 13)),
            ),
          if (shares.isEmpty && !_controller.discovering.value)
            const ListTile(
              leading: Icon(Icons.dns_outlined),
              title: Text(
                '未发现共享。设备需开启 SMB 服务并与本机同一局域网;\n'
                '也可以手动「添加共享」。',
                style: TextStyle(fontSize: 13),
              ),
            )
          else
            for (final s in shares)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  s.uri,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Get.to(
                  () => VlcBrowsePage(rootUri: s.uri, rootTitle: s.name),
                ),
                onLongPress: () {
                  _controller.addSavedShare(s.name, s.uri);
                  SmartDialog.showToast('已保存到共享书签');
                },
              ),
        ],
      );
    });
  }

  Future<void> _showAddShareDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final uriCtrl = TextEditingController();
    final result = await showDialog<VlcSavedShare>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加共享'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '名称(可留空)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: uriCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: 'smb://user:pass@192.168.1.5/share',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(
              result: VlcSavedShare(
                name: nameCtrl.text,
                uri: uriCtrl.text.trim(),
              ),
            ),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    uriCtrl.dispose();
    if (result != null && result.uri.isNotEmpty) {
      _controller.addSavedShare(result.name, result.uri);
    }
  }

  void _showSavedShareMenu(BuildContext context, VlcSavedShare share) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('浏览'),
              onTap: () {
                Get.back();
                Get.to(
                  () => VlcBrowsePage(
                    rootUri: share.uri,
                    rootTitle: share.name,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除书签'),
              onTap: () {
                Get.back();
                _controller.removeSavedShare(share);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.outline,
      ),
    ),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

/// 视频条目行(媒体库/文件夹页共用): 标题 + 时长 + 续播进度
class VideoTile extends StatelessWidget {
  const VideoTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.trailing,
  });

  final VlcMediaItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final progress = item.finished ? null : item.progress;
    return ListTile(
      leading: const Icon(Icons.movie_outlined),
      title: Text(
        item.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (item.lengthMs > 0)
            DurationUtils.formatDuration(item.lengthMs ~/ 1000),
          if (item.width > 0) '${item.width}×${item.height}',
          if (progress != null && progress > Duration.zero)
            '看到 ${DurationUtils.formatDuration(progress.inSeconds)}',
          if (item.playCount > 0) '播放过 ${item.playCount} 次',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: trailing,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

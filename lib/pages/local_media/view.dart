import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/local_media/local_media_item.dart';
import 'package:PiliPlus/models/local_media/local_media_sort.dart';
import 'package:PiliPlus/models/local_media/local_media_source.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/pages/local_media/widgets/source_editor.dart';
import 'package:PiliPlus/services/local_media_service.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/local_media_progress.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 「本地」板块: 播放本机与局域网(WebDAV / HTTP / FTP)里的视频。
///
/// 交互参照 VLC / OPlayer 的安卓版: 先是来源列表, 进入后是目录浏览,
/// 点文件直接播放, 同目录的其他视频自动成为播放列表。
class LocalMediaPage extends StatefulWidget {
  const LocalMediaPage({super.key});

  @override
  State<LocalMediaPage> createState() => _LocalMediaPageState();
}

class _LocalMediaPageState extends State<LocalMediaPage> {
  final _controller = Get.put(LocalMediaController());

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isRoot = _controller.isRoot;
      return popScope(
        canPop: isRoot,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            _controller.back();
          }
        },
        child: SimpleScaffold(
          appBar: AppBar(
            title: Text(isRoot ? '本地' : _controller.current!.title),
            actions: [
              if (!isRoot) ...[
                PopupMenuButton<LocalMediaSort>(
                  tooltip: '排序',
                  initialValue: _controller.sort,
                  icon: const Icon(Icons.sort),
                  onSelected: _controller.setSort,
                  itemBuilder: (context) => LocalMediaSort.values
                      .map(
                        (e) => PopupMenuItem(value: e, child: Text(e.label)),
                      )
                      .toList(),
                ),
                IconButton(
                  tooltip: _controller.showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
                  onPressed: _controller.toggleHidden,
                  icon: Icon(
                    _controller.showHidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _controller.refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
              const SizedBox(width: 6),
            ],
          ),
          body: isRoot ? _buildSources() : _buildBrowser(),
        ),
      );
    });
  }

  // ==================== 来源列表 ====================

  Widget _buildSources() {
    final devices = _controller.deviceSources;
    final saved = _controller.savedSources;
    final count = devices.length + saved.length + 1;
    return CustomScrollView(
      slivers: [
        ViewSliverSafeArea(
          sliver: SliverList.builder(
            itemCount: count,
            itemBuilder: (context, index) {
              if (index < devices.length) {
                return _sourceTile(devices[index], editable: false);
              }
              final i = index - devices.length;
              if (i < saved.length) {
                return _sourceTile(saved[i], editable: true);
              }
              return ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('添加网络共享'),
                subtitle: const Text('WebDAV 可浏览目录，HTTP / FTP 为直链播放'),
                onTap: () async {
                  final source = await showSourceEditor(context);
                  if (source != null) {
                    await _controller.addSource(source);
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sourceTile(LocalMediaSource source, {required bool editable}) {
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
      onLongPress: editable ? () => _showSourceMenu(source) : null,
    );
  }

  IconData _sourceIcon(LocalMediaSourceType type) => switch (type) {
    LocalMediaSourceType.device => Icons.smartphone_outlined,
    LocalMediaSourceType.webdav => Icons.cloud_outlined,
    LocalMediaSourceType.http => Icons.language_outlined,
    LocalMediaSourceType.ftp => Icons.folder_shared_outlined,
  };

  void _showSourceMenu(LocalMediaSource source) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(source.name),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (source.type == LocalMediaSourceType.webdav)
              ListTile(
                dense: true,
                leading: const Icon(Icons.wifi_tethering_outlined),
                title: const Text('测试连接'),
                onTap: () async {
                  Navigator.of(dialogContext).pop();
                  final res = await LocalMediaService.testWebDav(source);
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
                final updated = await showSourceEditor(
                  this.context,
                  initial: source,
                );
                if (updated != null) {
                  await _controller.replaceSource(source, updated);
                }
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

  // ==================== 目录浏览 ====================

  Widget _buildBrowser() {
    final state = _controller.state.value;
    return CustomScrollView(
      slivers: [
        ViewSliverSafeArea(
          sliver: switch (state) {
            Loading() => linearLoading,
            Error(:final errMsg) => HttpError(
              errMsg: errMsg,
              onReload: _controller.refresh,
            ),
            Success() => _buildItems(),
          },
        ),
      ],
    );
  }

  Widget _buildItems() {
    final items = _controller.items;
    if (items.isEmpty) {
      return HttpError(errMsg: '这里没有可播放的媒体文件', onReload: _controller.refresh);
    }
    return SliverList.builder(
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildBreadcrumb();
        }
        return _buildItem(items[index - 1]);
      },
    );
  }

  Widget _buildBreadcrumb() {
    final stack = _controller.stack;
    final labels = <String>['来源', ...stack.map((e) => e.title)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0) const Icon(Icons.chevron_right, size: 16),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: () => _controller.goToLevel(i - 1),
                child: Text(
                  labels[i],
                  style: const TextStyle(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildItem(LocalMediaItem item) {
    final progress = _controller.progressOf(item);
    final subtitle = <String>[
      if (item.size case final size?) CacheManager.formatSize(size),
      if (item.modified case final modified?) _formatDate(modified),
      if (progress case final p?) '看到 ${DurationUtils.formatDuration(p.inSeconds)}',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        item.isDirectory
            ? Icons.folder_outlined
            : item.isAudio
            ? Icons.audiotrack_outlined
            : Icons.movie_outlined,
      ),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: item.isDirectory
          ? const Icon(Icons.chevron_right)
          : progress == null
          ? null
          : const Icon(Icons.history_outlined, size: 18),
      onTap: () => _controller.openItem(item),
      onLongPress: () => _showItemMenu(item),
    );
  }

  void _showItemMenu(LocalMediaItem item) {
    final masked = LocalMediaService.maskedUrl(item.uri);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              subtitle: Text(
                [
                  '来源: ${item.source.name}',
                  if (item.size case final size?)
                    '大小: ${CacheManager.formatSize(size)}',
                  if (item.modified case final modified?)
                    '修改: ${_formatDate(modified)}',
                  '路径: $masked',
                ].join('\n'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link),
              title: const Text('复制播放地址(不含密码)'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                Clipboard.setData(ClipboardData(text: masked));
                SmartDialog.showToast('已复制');
              },
            ),
            if (LocalMediaProgress.get(item.uri) != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('清除播放进度'),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  LocalMediaProgress.clear(item.uri);
                  SmartDialog.showToast('已清除');
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

import 'package:PiliPlus/models/local_media/vlc_media.dart';
import 'package:PiliPlus/pages/local_media/controller.dart';
import 'package:PiliPlus/pages/local_media/view.dart' show VideoTile;
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 媒体库某个文件夹下的视频列表。
///
/// 点任意视频即以"该文件夹全部视频"为播放列表进入 VLC 播放页
/// (上一个/下一个 + 列表循环), 与旧实现的目录播放列表语义一致。
class LocalFolderPage extends StatelessWidget {
  const LocalFolderPage({
    super.key,
    required this.folderPath,
    required this.folderName,
  });

  final String folderPath;
  final String folderName;

  @override
  Widget build(BuildContext context) {
    final controller = Get.putOrFind(LocalMediaController.new);
    return Scaffold(
      appBar: AppBar(
        title: Text(folderName),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: controller.refreshVideos,
          ),
        ],
      ),
      body: Obx(() {
        // 依赖 videos 让 libml 索引更新后自动重建
        final items = controller.videos
            .where((e) => e.folderPath == folderPath)
            .toList();
        final sorted = _applySort(items, controller.sort.value);
        if (sorted.isEmpty) {
          return const Center(
            child: Text(
              '这个文件夹里没有已索引的视频',
              style: TextStyle(fontSize: 13),
            ),
          );
        }
        return ListView.builder(
          itemCount: sorted.length,
          itemBuilder: (context, i) {
            final item = sorted[i];
            return VideoTile(
              item: item,
              onTap: () => controller.playLibraryItem(item),
              onLongPress: () => _showItemMenu(context, controller, item),
            );
          },
        );
      }),
    );
  }

  static List<VlcMediaItem> _applySort(
    List<VlcMediaItem> items,
    VlcMediaSort sort,
  ) {
    final list = List<VlcMediaItem>.of(items);
    switch (sort) {
      case VlcMediaSort.name:
        list.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
      case VlcMediaSort.duration:
        list.sort((a, b) => b.lengthMs.compareTo(a.lengthMs));
      case VlcMediaSort.progress:
        list.sort((a, b) => b.timeMs.compareTo(a.timeMs));
      case VlcMediaSort.folder:
        break;
    }
    return list;
  }

  void _showItemMenu(
    BuildContext context,
    LocalMediaController controller,
    VlcMediaItem item,
  ) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('播放'),
              onTap: () {
                Get.back();
                controller.playLibraryItem(item);
              },
            ),
            if (item.timeMs > 0 && !item.finished)
              ListTile(
                leading: const Icon(Icons.replay),
                title: const Text('从头播放'),
                onTap: () {
                  Get.back();
                  controller.playLibraryItemSingle(item, fromStart: true);
                },
              ),
            if (!item.finished)
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: const Text('单独播放(不带列表)'),
                onTap: () {
                  Get.back();
                  controller.playLibraryItemSingle(item);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              onTap: () {
                Get.back();
                SmartDialog.showToast(
                  '${item.displayName}\n${item.uri}\n'
                  '${item.width}×${item.height}',
                  displayTime: const Duration(seconds: 4),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:PiliPlus/pages/local_player/controller.dart';
import 'package:PiliPlus/services/local_media/local_library_service.dart';
import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 媒体库（本机视频）Tab：
///  - 首次进入即开始索引（进度可见、边扫边出）
///  - 按文件夹归组浏览；点文件即播（同目录自动成为播放列表）
///  - 排序：文件夹归组 / 名称 / 时长 / 最近添加 / 续播优先
///  - 目录内检索（当前目录及全库，按文件名，硬上限 300）
///  - 返回时即时刷新「看到 xx:xx」
class LocalLibraryView extends StatefulWidget {
  const LocalLibraryView({super.key});

  @override
  State<LocalLibraryView> createState() => _LocalLibraryViewState();
}

class _LocalLibraryViewState extends State<LocalLibraryView>
    with AutomaticKeepAliveClientMixin {
  final LocalLibraryService _service = Get.put(LocalLibraryService());

  bool _permissionAsked = false;
  bool _permissionGranted = false;
  LocalFolder? _currentFolder;
  List<LocalVideo>? _searchResults;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _checkPermissionAndScan();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionAndScan() async {
    try {
      int sdkInt = 0;
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        sdkInt = info.version.sdkInt;
      }
      PermissionStatus status;
      if (Platform.isAndroid && sdkInt >= 33) {
        status = await Permission.videos.status;
        if (!status.isGranted) status = await Permission.videos.request();
      } else {
        status = await Permission.storage.status;
        if (!status.isGranted) status = await Permission.storage.request();
      }
      _permissionAsked = true;
      _permissionGranted = status.isGranted || status.isLimited;
    } catch (_) {
      _permissionAsked = true;
      _permissionGranted = false;
    }
    if (!mounted) return;
    setState(() {});
    if (_permissionGranted && _service.videos.isEmpty && !_service.scanning.value) {
      _service.startScan();
    }
  }

  Future<void> _runSearch() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults = null;
        _searchQuery = '';
      });
      return;
    }
    final results = await _service.search(
      q,
      bucketId: _currentFolder?.bucketId,
    );
    if (!mounted) return;
    setState(() {
      _searchResults = results;
      _searchQuery = q;
    });
  }

  void _openVideo(List<LocalVideo> playlist, int index) {
    final v = playlist[index];
    final controller = LocalPlayerController(
      uris: playlist.map((e) => e.uri).toList(),
      titles: playlist.map((e) => e.name).toList(),
      paths: playlist.map((e) => e.path).toList(),
      initialIndex: index,
      isNetwork: false,
      playlistName: _currentFolder?.name ?? '媒体库',
    );
    HapticFeedback.lightImpact();
    Get.toNamed('/localPlayer', arguments: controller);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_permissionAsked && !_permissionGranted) {
      return _buildPermissionGate();
    }
    return Column(
      children: [
        Obx(() {
          if (!_service.scanning.value) return const SizedBox.shrink();
          return LinearProgressIndicator(minHeight: 3);
        }),
        _buildSearchBar(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildPermissionGate() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.perm_media_outlined, size: 64),
            const SizedBox(height: 16),
            const Text(
              '需要媒体权限才能扫描本机视频\n（Android 13+ 仅需要「视频和音频」权限）',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _checkPermissionAndScan,
              icon: const Icon(Icons.refresh),
              label: const Text('重新授权'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: openAppSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('前往系统设置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8,12, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _currentFolder == null ? '搜索全部视频' : '在「${_currentFolder!.name}」中搜索',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _searchResults != null
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          _runSearch();
                        },
                      )
                    : null,
              ),
              onSubmitted: (_) => _runSearch(),
            ),
          ),
          const SizedBox(width: 8),
          Obx(
            () => PopupMenuButton<LibrarySort>(
              icon: const Icon(Icons.sort),
              tooltip: '排序',
              initialValue: _service.sort.value,
              onSelected: _service.setSort,
              itemBuilder: (context) => LibrarySort.values
                  .map(
                    (e) => PopupMenuItem(value: e, child: Text(e.label)),
                  )
                  .toList(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新（增量扫描）',
            onPressed: () {
              if (_service.videos.isEmpty) {
                _service.startScan();
              } else {
                _service.deltaRefresh();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return RefreshIndicator(
      onRefresh: () async {
        if (_service.videos.isEmpty) {
          await _service.startScan();
        } else {
          await _service.deltaRefresh();
        }
      },
      child: Obx(() {
        // 触发对记录变化的重建（看完/续播后返回即时刷新）
        _service.recordsVersion.value;
        if (_searchResults != null) {
          return _buildVideoList(_searchResults!);
        }
        if (_currentFolder != null) {
          final list = _service.videosOfBucket(_currentFolder!.bucketId);
          return _buildVideoList(list);
        }
        if (_service.videos.isEmpty && _service.scanning.value) {
          return _buildScanningPlaceholder();
        }
        if (_service.videos.isEmpty) {
          return ListView(
            children: [
              const SizedBox(height: 120),
              const Center(child: Text('暂无视频，下拉刷新开始扫描')),
            ],
          );
        }
        return _buildFolderList();
      }),
    );
  }

  Widget _buildScanningPlaceholder() {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Center(
          child: Obx(
            () => Text('正在扫描媒体库… 已发现 ${_service.scanCount.value} 个视频'),
          ),
        ),
      ],
    );
  }

  Widget _buildFolderList() {
    final folders = _service.folders;
    return ListView.builder(
      itemCount: folders.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Obx(
            () => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                _service.scanning.value
                    ? '正在扫描… 已发现 ${_service.scanCount.value} 个视频（边扫边出）'
                    : '共 ${_service.videos.length} 个视频 · ${folders.length} 个文件夹',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          );
        }
        final f = folders[i - 1];
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${f.count} 个视频 · 总时长 ${DurationUtils.formatDuration(f.totalDurationMs ~/ 1000)}',
          ),
          trailing: f.volume.contains('primary') || f.volume == '__legacy__'
              ? null
              : const Icon(Icons.sd_card_outlined, size: 18),
          onTap: () {
            setState(() {
              _currentFolder = f;
              _searchResults = null;
            });
          },
        );
      },
    );
  }

  Widget _buildVideoList(List<LocalVideo> list) {
    return Column(
      children: [
        if (_currentFolder != null || _searchResults != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _currentFolder = null;
                    _searchResults = null;
                    _searchController.clear();
                  });
                },
                icon: const Icon(Icons.arrow_back),
                label: Text(
                  _searchResults != null
                      ? '「$_searchQuery」的结果（${_searchResults!.length}）'
                      : _currentFolder!.name,
                ),
              ),
            ),
          ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('无匹配视频'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final v = list[i];
                    return _VideoTile(
                      video: v,
                      showFolder: _currentFolder == null && _searchResults != null,
                      onTap: () => _openVideo(list, i),
                      onLongPress: () => _showVideoMenu(v),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showVideoMenu(LocalVideo v) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('文件信息'),
              subtitle: Text(
                '${v.path}\n${(v.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                maxLines: 3,
              ),
            ),
            Obx(() {
              final record = _service.recordFor(v.uri);
              if (record == null) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('清除续播记录'),
                onTap: () {
                  _service.clearRecord(v.uri);
                  Navigator.pop(context);
                },
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  final LocalVideo video;
  final bool showFolder;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _VideoTile({
    required this.video,
    required this.showFolder,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final service = Get.find<LocalLibraryService>();
    final record = service.recordFor(video.uri);
    final progress = record == null || record.durationMs == 0
        ? null
        : (record.positionMs / record.durationMs).clamp(0.0, 1.0);
    return ListTile(
      leading: const Icon(Icons.movie_outlined),
      title: Text(video.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showFolder)
            Text(
              video.bucketName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Row(
            children: [
              Text(DurationUtils.formatDuration(video.durationMs ~/ 1000)),
              if (record != null && record.positionMs > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '看到 ${DurationUtils.formatDuration(record.positionMs ~/ 1000)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
              ],
              if (record != null && record.playCount > 1) ...[
                const SizedBox(width: 8),
                Text('×${record.playCount}'),
              ],
            ],
          ),
          if (progress != null && progress > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(value: progress, minHeight: 3),
              ),
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

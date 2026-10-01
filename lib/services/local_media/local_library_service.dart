import 'dart:async';

import 'package:PiliPlus/services/local_media/local_media_channel.dart';
import 'package:PiliPlus/services/local_media/log_ring.dart';
import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:get/get.dart';

enum LibrarySort {
  folderGroup('文件夹归组'),
  nameAsc('名称升序'),
  nameDesc('名称降序'),
  durationDesc('时长最长'),
  dateDesc('最近添加'),
  progressDesc('续播优先');

  final String label;
  const LibrarySort(this.label);
}

class PlayRecord {
  final int positionMs;
  final int durationMs;
  final int playCount;
  final int updatedAt;

  const PlayRecord({
    required this.positionMs,
    required this.durationMs,
    required this.playCount,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'pos': positionMs,
    'dur': durationMs,
    'cnt': playCount,
    'ts': updatedAt,
  };

  factory PlayRecord.fromMap(Map map) => PlayRecord(
    positionMs: (map['pos'] as num?)?.toInt() ?? 0,
    durationMs: (map['dur'] as num?)?.toInt() ?? 0,
    playCount: (map['cnt'] as num?)?.toInt() ?? 0,
    updatedAt: (map['ts'] as num?)?.toInt() ?? 0,
  );

  /// Considered watched (and therefore cleared) near the end.
  bool get finished =>
      durationMs > 0 && positionMs >= durationMs - 10 * 1000;
}

/// Holds the media library state and the local-only playback records
/// (resume position / play count). Records are stored in the `localMedia`
/// hive box and are NEVER reported to any server.
class LocalLibraryService extends GetxService {
  static LocalLibraryService get to => Get.find<LocalLibraryService>();

  final LocalMediaChannel _ch = LocalMediaChannel.instance;

  final RxList<LocalVideo> videos = <LocalVideo>[].obs;
  final RxList<LocalFolder> folders = <LocalFolder>[].obs;
  final RxBool scanning = false.obs;
  final RxInt scanCount = 0.obs;
  final RxnString scanError = RxnString();
  final Rx<LibrarySort> sort = LibrarySort.folderGroup.obs;
  /// Bumped whenever a play record changes so list UIs refresh instantly.
  final RxInt recordsVersion = 0.obs;

  final Map<int, LocalVideo> _byId = {};
  StreamSubscription<Map>? _sub;
  bool _deltaPending = false;

  @override
  void onInit() {
    super.onInit();
    _sub = _ch.events.listen(_onEvent);
  }

  @override
  void onClose() {
    _sub?.cancel();
    super.onClose();
  }

  void _onEvent(Map event) {
    switch (event['type'] as String? ?? '') {
      case 'scanBatch':
        final list = (event['videos'] as List? ?? const [])
            .cast<Map>()
            .map(LocalVideo.fromMap)
            .toList();
        for (final v in list) {
          _byId[v.id] = v;
        }
        videos.addAll(list);
        scanCount.value = (event['count'] as num?)?.toInt() ?? videos.length;
        _rebuildFolders();
        break;
      case 'scanProgress':
        scanning.value = true;
        scanCount.value = (event['count'] as num?)?.toInt() ?? 0;
        break;
      case 'scanDone':
        scanning.value = false;
        scanError.value = null;
        _rebuildFolders();
        LocalLogRing.instance.i(
          'LocalLibrary',
          'scan done: ${event['count']} videos',
        );
        break;
      case 'scanError':
        scanning.value = false;
        scanError.value = event['message'] as String?;
        LocalLogRing.instance.e(
          'LocalLibrary',
          'scan error: ${event['message']}',
        );
        break;
      case 'scanRemoved':
        final ids = (event['ids'] as List? ?? const []).cast<num>();
        if (ids.isNotEmpty) {
          videos.removeWhere((v) => ids.contains(v.id));
          for (final id in ids) {
            _byId.remove(id.toInt());
          }
          _rebuildFolders();
        }
        break;
    }
  }

  void _rebuildFolders() {
    final map = <int, List<LocalVideo>>{};
    for (final v in videos) {
      (map[v.bucketId] ??= []).add(v);
    }
    final list = map.entries.map((e) {
      final vs = e.value;
      var total = 0, latest = 0;
      String path = '';
      for (final v in vs) {
        total += v.durationMs;
        if (v.dateAddedMs > latest) latest = v.dateAddedMs;
        if (path.isEmpty && v.path.isNotEmpty) {
          final i = v.path.lastIndexOf('/');
          path = i > 0 ? v.path.substring(0, i) : v.path;
        }
      }
      return LocalFolder(
        bucketId: e.key,
        name: vs.first.bucketName,
        path: path,
        volume: vs.first.volume,
        count: vs.length,
        totalDurationMs: total,
        latestMs: latest,
      );
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    folders.assignAll(list);
    applySort();
  }

  Future<void> startScan() async {
    if (scanning.value) return;
    videos.clear();
    _byId.clear();
    scanCount.value = 0;
    scanError.value = null;
    scanning.value = true;
    try {
      final started = await _ch.libraryScan();
      if (!started) {
        scanning.value = false;
      }
    } catch (e) {
      scanning.value = false;
      scanError.value = e.toString();
    }
  }

  Future<void> deltaRefresh() async {
    if (scanning.value || _deltaPending) return;
    _deltaPending = true;
    try {
      await _ch.libraryDelta();
    } catch (e) {
      LocalLogRing.instance.w('LocalLibrary', 'delta refresh failed: $e');
    } finally {
      _deltaPending = false;
    }
  }

  Future<List<LocalVideo>> search(String query, {int? bucketId}) async {
    final res = await _ch.librarySearch(query, bucketId: bucketId);
    return res.map(LocalVideo.fromMap).toList();
  }

  List<LocalVideo> videosOfBucket(int bucketId) {
    final list = videos.where((v) => v.bucketId == bucketId).toList();
    _sortList(list);
    return list;
  }

  void setSort(LibrarySort s) {
    sort.value = s;
    applySort();
  }

  void applySort() {
    final list = videos.toList();
    _sortList(list);
    videos.assignAll(list);
  }

  void _sortList(List<LocalVideo> list) {
    switch (sort.value) {
      case LibrarySort.folderGroup:
        list.sort(
          (a, b) => a.bucketName == b.bucketName
              ? a.name.compareTo(b.name)
              : a.bucketName.compareTo(b.bucketName),
        );
      case LibrarySort.nameAsc:
        list.sort((a, b) => a.name.compareTo(b.name));
      case LibrarySort.nameDesc:
        list.sort((a, b) => b.name.compareTo(a.name));
      case LibrarySort.durationDesc:
        list.sort((a, b) => b.durationMs.compareTo(a.durationMs));
      case LibrarySort.dateDesc:
        list.sort((a, b) => b.dateAddedMs.compareTo(a.dateAddedMs));
      case LibrarySort.progressDesc:
        list.sort((a, b) {
          final ra = recordFor(a.uri), rb = recordFor(b.uri);
          final pa = ra == null ? 0.0 : (ra.durationMs == 0 ? 0.0 : ra.positionMs / ra.durationMs);
          final pb = rb == null ? 0.0 : (rb.durationMs == 0 ? 0.0 : rb.positionMs / rb.durationMs);
          return pb.compareTo(pa);
        });
    }
  }

  // ---- playback records (local only) ----

  PlayRecord? recordFor(String uri) {
    final raw = GStorage.localMedia.get('${LocalBoxKey.progressPrefix}$uri');
    if (raw is Map) {
      final r = PlayRecord.fromMap(raw);
      return r.positionMs > 0 ? r : null;
    }
    return null;
  }

  void saveRecord(String uri, int positionMs, int durationMs) {
    final key = '${LocalBoxKey.progressPrefix}$uri';
    final old = GStorage.localMedia.get(key);
    final cnt = old is Map ? (old['cnt'] as num?)?.toInt() ?? 0 : 0;
    if (durationMs > 0 && positionMs >= durationMs - 10 * 1000) {
      // watched to the end -> drop the resume point
      GStorage.localMedia.delete(key);
    } else if (positionMs > 5 * 1000) {
      GStorage.localMedia.put(
        key,
        PlayRecord(
          positionMs: positionMs,
          durationMs: durationMs,
          playCount: cnt,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ).toMap(),
      );
    }
    recordsVersion.value++;
  }

  void countPlay(String uri) {
    final key = '${LocalBoxKey.progressPrefix}$uri';
    final old = GStorage.localMedia.get(key);
    final map = old is Map ? Map<String, dynamic>.from(old) : <String, dynamic>{};
    map['cnt'] = ((map['cnt'] as num?)?.toInt() ?? 0) + 1;
    map['ts'] = DateTime.now().millisecondsSinceEpoch;
    map.putIfAbsent('pos', () => 0);
    map.putIfAbsent('dur', () => 0);
    GStorage.localMedia.put(key, map);
    recordsVersion.value++;
  }

  void clearRecord(String uri) {
    GStorage.localMedia.delete('${LocalBoxKey.progressPrefix}$uri');
    recordsVersion.value++;
  }

  // ---- per-source VR overrides ----

  Map? vrOverrideFor(String uri) {
    final raw = GStorage.localMedia.get('${LocalBoxKey.vrOverridePrefix}$uri');
    return raw is Map ? raw : null;
  }

  void saveVrOverride(String uri, int projection, int stereo, int eye) {
    GStorage.localMedia.put(
      '${LocalBoxKey.vrOverridePrefix}$uri',
      {'proj': projection, 'stereo': stereo, 'eye': eye},
    );
  }
}

import 'dart:async';

import 'package:PiliPlus/services/local_media/log_ring.dart';
import 'package:flutter/services.dart';

/// Single access point to the native local-media bridge
/// (android/app/src/main/kotlin/com/example/piliplus/localmedia).
///
/// Android only; every entry point is guarded so that other platforms and
/// unit tests can import this file safely.
class LocalMediaChannel {
  LocalMediaChannel._();

  static final LocalMediaChannel instance = LocalMediaChannel._();

  static const MethodChannel _channel = MethodChannel('piliplus/local');
  static const EventChannel _events = EventChannel('piliplus/local_events');

  StreamSubscription<dynamic>? _sub;
  final StreamController<Map> _controller = StreamController<Map>.broadcast();

  bool _engineInitTried = false;
  bool _engineReady = false;
  int _vrVersion = 0;
  String _libvlcVersion = '';
  String? _initError;

  bool get engineReady => _engineReady;
  int get vrVersion => _vrVersion;
  String get libvlcVersion => _libvlcVersion;
  String? get initError => _initError;

  /// Shared stream of all native events ({type: ...} maps).
  Stream<Map> get events {
    _ensureListening();
    return _controller.stream;
  }

  void _ensureListening() {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) _controller.add(event);
      },
      onError: (Object e, StackTrace st) {
        LocalLogRing.instance.add('E', 'LocalMediaChannel', 'event error: $e');
      },
    );
  }

  Future<Map> engineInit() async {
    _ensureListening();
    if (_engineInitTried && _engineReady) {
      return {'vrVersion': _vrVersion, 'version': _libvlcVersion};
    }
    _engineInitTried = true;
    try {
      final result = await _channel.invokeMethod<Map>('engineInit');
      _vrVersion = (result?['vrVersion'] as num?)?.toInt() ?? 0;
      _libvlcVersion = result?['version'] as String? ?? '';
      _engineReady = true;
      _initError = null;
      LocalLogRing.instance.add(
        'I',
        'LocalMediaChannel',
        'engine ready: libvlc=$_libvlcVersion vr=$_vrVersion',
      );
      return {'vrVersion': _vrVersion, 'version': _libvlcVersion};
    } on PlatformException catch (e) {
      _engineReady = false;
      _initError = '${e.code}: ${e.message}';
      LocalLogRing.instance.add('E', 'LocalMediaChannel', 'engine init failed: $_initError');
      rethrow;
    }
  }

  Future<Map> engineInfo() async {
    final info = await _channel.invokeMethod<Map>('engineInfo');
    return info?.cast<String, dynamic>() ?? {};
  }

  Future<void> engineRelease() => _channel.invokeMethod('engineRelease');

  // ---- player ----

  Future<void> playerAttach(int viewId) =>
      _channel.invokeMethod('playerAttach', {'viewId': viewId});

  Future<void> playerOpen({
    required List<String> uris,
    required int index,
    int startMs = 0,
    double rate = 1.0,
    bool glVout = false,
    int networkCachingMs = 2000,
  }) => _channel.invokeMethod('playerOpen', {
    'uris': uris,
    'index': index,
    'startMs': startMs,
    'rate': rate,
    'glVout': glVout,
    'networkCachingMs': networkCachingMs,
  });

  Future<void> playerReopen({bool glVout = false, int networkCachingMs = 2000}) =>
      _channel.invokeMethod('playerReopen', {
        'glVout': glVout,
        'networkCachingMs': networkCachingMs,
      });

  Future<void> playerPlay() => _channel.invokeMethod('playerPlay');
  Future<void> playerPause() => _channel.invokeMethod('playerPause');
  Future<void> playerStop() => _channel.invokeMethod('playerStop');
  Future<void> playerRelease() => _channel.invokeMethod('playerRelease');

  Future<void> playerSeek(int ms, {bool fast = false}) =>
      _channel.invokeMethod('playerSeek', {'ms': ms, 'fast': fast});

  Future<void> playerSetRate(double rate) =>
      _channel.invokeMethod('playerSetRate', {'rate': rate});

  Future<int> playerTime() async =>
      (await _channel.invokeMethod<int>('playerTime')) ?? 0;

  Future<bool> playerIsPlaying() async =>
      (await _channel.invokeMethod<bool>('playerIsPlaying')) ?? false;

  Future<List<Map>> playerTracks(String type) async {
    final res = await _channel.invokeMethod<List>('playerTracks', {'type': type});
    return res?.cast<Map>() ?? const [];
  }

  Future<int> playerSelectedTrack(String type) async =>
      (await _channel.invokeMethod<int>('playerSelectedTrack', {'type': type})) ?? -1;

  Future<bool> playerSelectTrack(String type, int id) async =>
      (await _channel.invokeMethod<bool>(
            'playerSelectTrack',
            {'type': type, 'id': id},
          )) ??
      false;

  Future<bool> playerAddSubtitle(String uri) async =>
      (await _channel.invokeMethod<bool>('playerAddSubtitle', {'uri': uri})) ??
      false;

  // ---- VR ----

  Future<int> playerVrVersion() async =>
      (await _channel.invokeMethod<int>('playerVrVersion')) ?? 0;

  Future<bool> playerSetVrMode({
    required int projection,
    required int stereo,
    required int eye,
  }) async =>
      (await _channel.invokeMethod<bool>('playerSetVrMode', {
        'projection': projection,
        'stereo': stereo,
        'eye': eye,
      })) ??
      false;

  Future<bool> playerUpdateViewpoint({
    required double yaw,
    required double pitch,
    required double fov,
    bool absolute = true,
  }) async =>
      (await _channel.invokeMethod<bool>('playerUpdateViewpoint', {
        'yaw': yaw,
        'pitch': pitch,
        'fov': fov,
        'absolute': absolute,
      })) ??
      false;

  Future<void> playerSetGyro(bool enabled) =>
      _channel.invokeMethod('playerSetGyro', {'enabled': enabled});

  Future<void> playerResetViewpoint() =>
      _channel.invokeMethod('playerResetViewpoint');

  Future<void> playerSetFov(double fov) =>
      _channel.invokeMethod('playerSetFov', {'fov': fov});

  Future<Map> playerViewpoint() async =>
      (await _channel.invokeMethod<Map>('playerViewpoint')) ?? const {};

  // ---- aspect / snapshot ----

  Future<void> playerSetAspect(String? aspect) =>
      _channel.invokeMethod('playerSetAspect', {'aspect': aspect});

  Future<bool> playerSnapshot(String path) async =>
      (await _channel.invokeMethod<bool>('playerSnapshot', {'path': path})) ??
      false;

  // ---- library ----

  Future<bool> libraryScan() async =>
      (await _channel.invokeMethod<bool>('libraryScan')) ?? false;

  Future<void> libraryDelta() => _channel.invokeMethod('libraryDelta');

  Future<List<Map>> librarySearch(String query, {int? bucketId, int limit = 300}) async {
    final res = await _channel.invokeMethod<List>('librarySearch', {
      'query': query,
      'bucketId': bucketId,
      'limit': limit,
    });
    return (res ?? const []).cast<Map>().toList();
  }

  // ---- network ----

  Future<void> netDiscover({String? service}) =>
      _channel.invokeMethod('netDiscover', {'service': service});

  Future<void> netStopDiscovery() => _channel.invokeMethod('netStopDiscovery');

  Future<void> netBrowse(String url) =>
      _channel.invokeMethod('netBrowse', {'url': url});

  Future<int> netDownload({
    required String url,
    required String destDir,
    required String fileName,
  }) async =>
      (await _channel.invokeMethod<int>('netDownload', {
        'url': url,
        'destDir': destDir,
        'fileName': fileName,
      })) ??
      -1;

  Future<void> netDownloadCancel(int id) =>
      _channel.invokeMethod('netDownloadCancel', {'id': id});

  // ---- dialogs ----

  Future<void> dialogPostLogin({
    required int id,
    required String username,
    required String password,
    bool store = false,
  }) => _channel.invokeMethod('dialogPostLogin', {
    'id': id,
    'username': username,
    'password': password,
    'store': store,
  });

  Future<void> dialogPostAction(int id, int action) =>
      _channel.invokeMethod('dialogPostAction', {'id': id, 'action': action});

  Future<void> dialogDismiss(int id) =>
      _channel.invokeMethod('dialogDismiss', {'id': id});

  // ---- diagnostics ----

  Future<List<String>> logGet() async {
    final res = await _channel.invokeMethod<List>('logGet');
    return res?.cast<String>() ?? const [];
  }

  Future<void> logClear() => _channel.invokeMethod('logClear');

  Future<void> logAdd(String level, String tag, String msg) =>
      _channel.invokeMethod('logAdd', {'level': level, 'tag': tag, 'msg': msg});

  Future<Map> deviceInfo() async =>
      (await _channel.invokeMethod<Map>('deviceInfo')) ?? const {};
}

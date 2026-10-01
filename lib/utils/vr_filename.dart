import 'package:PiliPlus/services/local_media/models.dart';

/// Filename-based VR format detection (requirement §2.5.5).
///
/// Rules:
///  - projection keywords: 360 / 180 / vr / 全景 / equirect / panoram
///  - layout keywords: sbs / side-by-side / tb / over-under / 左右 / 上下
///  - `3d` alone marks the file as VR but never implies a layout
///  - anti false-positive guards:
///      * `360p` / `1080p` style quality tags never count
///      * numbers glued to other numbers/dimensions (1920x360, 3600) never
///        count
///      * bare short tags (tb/ou) only count together with another VR signal
///      * aspect ratio / dimensions are never used as evidence
///  - when nothing is recognised the player falls back to
///    `VrProjection.auto` (source metadata).
class VrDetectResult {
  /// Detected VR hint at all (should the VR panel be highlighted / gl vout
  /// be preselected).
  final bool vrHint;
  final VrProjection projection;
  final VrStereo stereo;

  const VrDetectResult({
    required this.vrHint,
    required this.projection,
    required this.stereo,
  });

  static const none = VrDetectResult(
    vrHint: false,
    projection: VrProjection.auto,
    stereo: VrStereo.auto,
  );

  @override
  String toString() =>
      'VrDetect(vr=$vrHint, proj=$projection, stereo=$stereo)';
}

abstract final class VrFilename {
  // 360/180 not part of a resolution or bigger number:
  //  - not preceded by a digit, 'x' or '×' (1920x360, 4360)
  //  - not followed by a digit or 'p' (360p, 1080p, 3600)
  static final RegExp _r360 = RegExp(
    r'(?<![0-9x×])360(?![0-9pP])',
  );
  static final RegExp _r180 = RegExp(
    r'(?<![0-9x×])180(?![0-9pP])',
  );

  static final RegExp _rVr = RegExp(r'(?:^|[^a-z0-9])vr(?:[^a-z]|$)', caseSensitive: false);
  static final RegExp _r3d = RegExp(r'(?:^|[^a-z0-9])3d(?:[^a-z]|$)', caseSensitive: false);
  static final RegExp _rQuanJing = RegExp(r'全景');
  static final RegExp _rEquirect = RegExp(r'equirect', caseSensitive: false);
  static final RegExp _rPanoram = RegExp(r'panoram', caseSensitive: false);

  static final RegExp _rSbs = RegExp(
    r'(?:^|[^a-z0-9])sbs(?:[^a-z0-9]|$)|side[\s._-]*by[\s._-]*side|左右',
    caseSensitive: false,
  );
  static final RegExp _rTb = RegExp(
    r'(?:^|[^a-z0-9])tb(?:[^a-z0-9]|$)|over[\s._-]*under|上下',
    caseSensitive: false,
  );

  static VrDetectResult detect(String filename) {
    // Only the base name matters; strip directories to reduce noise.
    var name = filename;
    final slash = name.lastIndexOf('/');
    if (slash >= 0) name = name.substring(slash + 1);

    final has360 = _r360.hasMatch(name);
    final has180 = _r180.hasMatch(name);
    final hasVrWord = _rVr.hasMatch(name);
    final has3d = _r3d.hasMatch(name);
    final hasQuanJing = _rQuanJing.hasMatch(name);
    final hasEquirect = _rEquirect.hasMatch(name);
    final hasPanoram = _rPanoram.hasMatch(name);
    final hasSbs = _rSbs.hasMatch(name);
    final hasTb = _rTb.hasMatch(name);

    final projectionSignal =
        has360 || has180 || hasVrWord || has3d || hasQuanJing || hasEquirect || hasPanoram;

    // Bare layout tags alone are NOT a VR signal (release-group tags like
    // "TB" must not trigger); they only refine an existing signal.
    final vrHint = projectionSignal;
    if (!vrHint) return VrDetectResult.none;

    VrProjection projection;
    if (has360 && !has180) {
      projection = VrProjection.e360;
    } else if (has180 && !has360) {
      projection = VrProjection.e180;
    } else {
      // both/neither coverage keywords -> trust source metadata
      projection = VrProjection.auto;
    }

    VrStereo stereo;
    if (hasSbs && !hasTb) {
      stereo = VrStereo.sbs;
    } else if (hasTb && !hasSbs) {
      stereo = VrStereo.tb;
    } else {
      // `3d` alone must not imply a layout; conflicting tags cancel out.
      stereo = VrStereo.auto;
    }

    return VrDetectResult(vrHint: true, projection: projection, stereo: stereo);
  }
}

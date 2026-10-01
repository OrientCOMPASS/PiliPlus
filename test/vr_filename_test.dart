import 'package:PiliPlus/services/local_media/models.dart';
import 'package:PiliPlus/utils/vr_filename.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VrFilename.detect', () {
    test('plain files are not VR', () {
      expect(VrFilename.detect('Movie.2023.1080p.BluRay.x264.mkv').vrHint, false);
      expect(VrFilename.detect('第3集.mp4').vrHint, false);
      expect(VrFilename.detect('Show.S01E05.720p.WEB-DL.mp4').vrHint, false);
    });

    test('quality tags must not be mistaken for projections', () {
      expect(VrFilename.detect('video.360p.h264.mp4').vrHint, false);
      expect(VrFilename.detect('video.1080p.x265.mkv').vrHint, false);
      expect(VrFilename.detect('cam_2160p_4k.mp4').vrHint, false);
      expect(VrFilename.detect('clip 480p TS group.mp4').vrHint, false);
    });

    test('numbers glued to dimensions do not trigger', () {
      expect(VrFilename.detect('test_1920x360_edge.mp4').vrHint, false);
      expect(VrFilename.detect('render3600frames.mp4').vrHint, false);
      expect(VrFilename.detect('x180sample.mp4').vrHint, false);
    });

    test('360 detection', () {
      final r = VrFilename.detect('Beach.360.VR.mkv');
      expect(r.vrHint, true);
      expect(r.projection, VrProjection.e360);

      final r2 = VrFilename.detect('全景视频 360.mp4');
      expect(r2.projection, VrProjection.e360);
    });

    test('180 detection', () {
      final r = VrFilename.detect('Cabin.VR180.mp4');
      expect(r.vrHint, true);
      expect(r.projection, VrProjection.e180);

      final r2 = VrFilename.detect('舞台 180 全景.mp4');
      expect(r2.projection, VrProjection.e180);
    });

    test('stereo layouts', () {
      expect(
        VrFilename.detect('Tour.360.SBS.mp4').stereo,
        VrStereo.sbs,
      );
      expect(
        VrFilename.detect('Tour.360.side_by_side.mp4').stereo,
        VrStereo.sbs,
      );
      expect(
        VrFilename.detect('Dive.180.Over-Under.mp4').stereo,
        VrStereo.tb,
      );
      expect(
        VrFilename.detect('Dive.180.TB.mp4').stereo,
        VrStereo.tb,
      );
      expect(
        VrFilename.detect('演唱会.360.左右3D.mkv').stereo,
        VrStereo.sbs,
      );
      expect(
        VrFilename.detect('演唱会.180.上下格式.mkv').stereo,
        VrStereo.tb,
      );
    });

    test('3d alone never guesses layout, projection stays auto', () {
      final r = VrFilename.detect('Some.Movie.3D.2016.mkv');
      expect(r.vrHint, true);
      expect(r.stereo, VrStereo.auto);
      expect(r.projection, VrProjection.auto);
    });

    test('bare layout tags without VR signal are ignored', () {
      // "TB" as part of a group tag must not make a flat file VR
      expect(VrFilename.detect('Show.1x01.TB-group.720p.mp4').vrHint, false);
    });

    test('vr/panorama keywords without coverage fall back to auto', () {
      final r = VrFilename.detect('Holiday.VR.experience.mp4');
      expect(r.vrHint, true);
      expect(r.projection, VrProjection.auto);

      final r2 = VrFilename.detect('Equirectangular_Panorama_8k.mp4');
      expect(r2.vrHint, true);
      expect(r2.projection, VrProjection.auto);
    });

    test('both 360 and 180 present -> auto', () {
      final r = VrFilename.detect('weird.360.and.180.mix.mp4');
      expect(r.projection, VrProjection.auto);
    });

    test('directory prefixes do not interfere', () {
      final r = VrFilename.detect('/storage/emulated/0/VR视频/Movie.180.SBS.mkv');
      expect(r.projection, VrProjection.e180);
      expect(r.stereo, VrStereo.sbs);
    });
  });
}

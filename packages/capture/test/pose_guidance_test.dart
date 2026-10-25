import 'dart:io';

import 'package:facetrack_capture/src/pose_guidance.dart';
import 'package:facetrack_capture/src/pending.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProvider, (call) async {
        if (call.method == 'getApplicationSupportDirectory' ||
            call.method == 'getTemporaryDirectory') {
          return Directory.systemTemp.path;
        }
        return null;
      });
  final start = DateTime.utc(2026, 10, 23);
  PoseObservation observation(
    int milliseconds, {
    int faces = 1,
    Rect? bounds = const Rect.fromLTRB(.28, .20, .72, .80),
    double yaw = 0,
    double pitch = 0,
    double brightness = 120,
  }) => PoseObservation(
    timestamp: start.add(Duration(milliseconds: milliseconds)),
    faceCount: faces,
    bounds: bounds,
    yaw: yaw,
    pitch: pitch,
    luminance: brightness,
  );

  test('advances only after two separated usable observations in order', () {
    final guide = PoseGuidance(order: ['front', 'left', 'down']);
    guide.observe(observation(0));
    expect(guide.current, 'front');
    guide.observe(observation(250));
    expect(guide.current, 'front');
    guide.observe(observation(500));
    expect(guide.current, 'left');
    guide.observe(observation(1000, yaw: -24));
    guide.observe(observation(1500, yaw: -24));
    expect(guide.current, 'down');
    guide.observe(observation(2000, pitch: -22));
    guide.observe(observation(2500, pitch: -22));
    expect(guide.allCaptured, isTrue);
    expect(guide.progress, 1);
  });

  test('rejects multiple, distant, dark and wrong-direction observations', () {
    final guide = PoseGuidance(order: ['front', 'right']);
    guide.observe(observation(0, faces: 2));
    expect(guide.hint, contains('Only one'));
    guide.observe(
      observation(500, bounds: const Rect.fromLTRB(.45, .45, .55, .55)),
    );
    expect(guide.hint, contains('Move closer'));
    guide.observe(observation(1000, brightness: 20));
    expect(guide.hint, contains('lighting'));
    guide.observe(observation(1500, yaw: 25));
    expect(guide.current, 'front');
    guide.observe(observation(2000));
    guide.observe(observation(2500));
    expect(guide.current, 'right');
    guide.observe(observation(3000, yaw: -25));
    expect(guide.current, 'right');
  });

  test(
    'stale analyzer reports a neutral fallback rather than a pose success',
    () {
      final guide = PoseGuidance(order: ['front']);
      guide.observe(observation(0));
      guide.unavailable(start.add(const Duration(seconds: 3)));
      expect(guide.allCaptured, isFalse);
      expect(guide.hint, contains('guidance unavailable'));
    },
  );

  test(
    'pending recording retains advisory missing poses across native recovery',
    () {
      final clip = PendingClip(
        owner: 'owner',
        institute: 'institute',
        attempt: 'attempt',
        path: '/private/clip.mp4',
        mime: 'video/mp4',
        completeKey: 'key',
        created: start,
        missedGuidance: const ['left', 'up'],
      );
      expect(PendingClip.fromJson(clip.toJson()).missedGuidance, [
        'left',
        'up',
      ]);
      final old = clip.toJson()..remove('missed_guidance');
      expect(PendingClip.fromJson(old).missedGuidance, isEmpty);
    },
  );

  test('late upload checkpoint cannot resurrect cleared private media', () async {
    SharedPreferences.setMockInitialValues({});
    final file = File(
      '${Directory.systemTemp.path}/facetrack-pending-${DateTime.now().microsecondsSinceEpoch}.mp4',
    )..writeAsBytesSync([1, 2, 3]);
    final clip = PendingClip(
      owner: 'owner',
      institute: 'institute',
      attempt: '00000000-0000-4000-8000-000000000001',
      path: file.path,
      mime: 'video/mp4',
      completeKey: 'key',
      created: DateTime.now(),
    );
    await PendingClips.save(clip);
    await PendingClips.clear();
    clip.uploadUrl = 'https://fixture.invalid/resumable/private';
    expect(await PendingClips.update(clip), isFalse);
    expect(await PendingClips.read(), isNull);
    if (file.existsSync()) file.deleteSync();
  });
}

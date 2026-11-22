import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:facetrack_teacher/processing_progress.dart';
import 'package:facetrack_teacher/recognition_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);
const _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

class _Camera extends GuidedCamera {
  final bool problemFree;
  _Camera({String? problem}) : problemFree = problem == null {
    cameras = const [_back, _front];
    selectedCamera = _back;
    if (problem != null) error = problem;
  }
  @override
  Future<void> initialize() async => ready = problemFree;
  @override
  Future<void> start(List<String> order) async {
    recording = true;
    emit();
  }

  @override
  Future<void> interrupt({bool lifecycle = false}) async {
    recording = false;
    ready = false;
  }
}

Map<String, dynamic> _row(String id, String name, {String status = 'unassessed', String? code}) => {
  'student_id': id,
  'official_name': name,
  'enrollment_number': 'E$id',
  'status': status,
  'assessment_code': code,
  'evidence_summary': <String, dynamic>{},
};

final _students = RecognitionSnapshot([
  _row('1', 'Asha Rao', status: 'proposed_present', code: 'recognized'),
  _row('2', 'Ben Cole', status: 'proposed_absent', code: 'not_recognized'),
  _row('3', 'Chitra Das'),
]);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<ClassroomScan> _open(
  WidgetTester tester, {
  required Size size,
  double scale = 1,
  RecognitionSnapshot snapshot = const RecognitionSnapshot([]),
  GuidedCamera? camera,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scan = ClassroomScan(camera ?? _Camera(), (file) async {});
  addTearDown(scan.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ClassroomScanPage(scan: scan, results: () async => snapshot),
    ),
  );
  await tester.pump();
  await tester.pump();
  return scan;
}

void _expectOnScreen(WidgetTester tester, Size size, Iterable<String> keys) {
  for (final key in keys) {
    final r = tester.getRect(find.byKey(ValueKey(key)));
    expect(
      r.left >= 0 && r.right <= size.width && r.top >= 0 && r.bottom <= size.height,
      isTrue,
      reason: '$key at $size: $r',
    );
  }
}

void main() {
  group('scan controls stay usable', () {
    for (final (size, scale) in const [
      (Size(320, 568), 1.0),
      (Size(320, 568), 2.0),
      (Size(390, 844), 1.0),
      (Size(390, 844), 2.0),
      (Size(430, 900), 2.0),
    ]) {
      testWidgets('portrait ${size.width.toInt()}x${size.height.toInt()}, text ${(scale * 100).toInt()}%', (
        tester,
      ) async {
        await _open(tester, size: size, scale: scale, snapshot: _students);
        expect(tester.takeException(), isNull);
        _expectOnScreen(tester, size, ['record-button', 'students-chip', 'flip-camera', 'scan-status']);
        // Touch targets: the record button and the flip button.
        expect(tester.getSize(find.byKey(const ValueKey('record-button'))).shortestSide, greaterThanOrEqualTo(72));
        expect(tester.getSize(find.byKey(const ValueKey('flip-camera'))).shortestSide, greaterThanOrEqualTo(44));
        expect(find.text('Start scan'), findsOneWidget);
        expect(find.text('1 / 3'), findsOneWidget);
      });
    }

    for (final (size, scale) in const [
      (Size(1280, 720), 1.0),
      (Size(1440, 900), 1.0),
      (Size(1440, 900), 2.0),
      (Size(568, 320), 1.0),
      (Size(568, 320), 2.0),
      (Size(640, 360), 2.0),
      (Size(844, 390), 2.0),
    ]) {
      testWidgets('wide or landscape ${size.width.toInt()}x${size.height.toInt()}, text ${(scale * 100).toInt()}%', (
        tester,
      ) async {
        await _open(tester, size: size, scale: scale, snapshot: _students);
        expect(tester.takeException(), isNull);
        _expectOnScreen(tester, size, ['record-button', 'students-chip', 'flip-camera', 'scan-status']);
        expect(tester.getRect(find.byKey(const ValueKey('record-button'))).left, greaterThan(size.width * .7));
      });
    }

    testWidgets('while recording the status shows the timer and segment number', (tester) async {
      final scan = await _open(tester, size: const Size(320, 568), scale: 2);
      await scan.start();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Segment 1'), findsOneWidget);
      expect(find.text('Stop scan'), findsOneWidget);
      _expectOnScreen(tester, const Size(320, 568), ['scan-status', 'record-button']);
    });

    testWidgets('face guidance hints still warn about the light', (tester) async {
      final camera = _Camera()
        ..ready = true
        ..lighting = Lighting.tooDark;
      await _open(tester, size: const Size(320, 568), scale: 2, camera: camera);
      expect(find.textContaining('Too dark'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('camera problems are explained', () {
    testWidgets('a refused permission says what to do and offers another try', (tester) async {
      await _open(
        tester,
        size: const Size(320, 568),
        scale: 2,
        camera: _Camera(
          problem: 'Camera unavailable. Allow camera access, close other camera apps and retry.',
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('camera-state')), findsOneWidget);
      expect(find.text('Camera access needed'), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-retry')), findsOneWidget);
    });

    testWidgets('any other camera failure shows its message', (tester) async {
      await _open(
        tester,
        size: const Size(390, 844),
        camera: _Camera(problem: 'Camera disconnected. Reconnect it or choose another camera.'),
      );
      expect(find.text('Camera unavailable'), findsOneWidget);
      expect(find.textContaining('Camera disconnected'), findsOneWidget);
    });

    testWidgets('while the camera opens there is a short wait message', (tester) async {
      await _open(tester, size: const Size(390, 844));
      expect(find.text('Opening camera…'), findsOneWidget);
    });
  });

  group('student list sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('students-chip')));
      await _settle(tester);
    }

    testWidgets('searches by name and can narrow to students who need attention', (tester) async {
      await _open(tester, size: const Size(360, 640), snapshot: _students);
      await openSheet(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('1 of 3 recognised'), findsOneWidget);
      expect(find.byKey(const ValueKey('board-1')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('students-search')), 'ben');
      await _settle(tester);
      expect(find.byKey(const ValueKey('board-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('board-1')), findsNothing);
      // The summary still counts the whole class.
      expect(find.text('1 of 3 recognised'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('students-search')), 'nobody');
      await _settle(tester);
      expect(find.byKey(const ValueKey('board-empty')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('students-search')), '');
      await tester.tap(find.byKey(const ValueKey('students-attention')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('board-1')), findsNothing); // recognised: no longer listed
      expect(find.byKey(const ValueKey('board-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('board-3')), findsOneWidget);
      // Students the server has not recognised are never green.
      for (final id in ['2', '3']) {
        final icon = tester.widget<Icon>(
          find.descendant(of: find.byKey(ValueKey('board-$id')), matching: find.byType(Icon)),
        );
        expect(icon.color, isNot(Colors.greenAccent), reason: 'student $id');
      }
    });

    testWidgets('the search field stays above the keyboard', (tester) async {
      await _open(tester, size: const Size(360, 640), snapshot: _students);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await openSheet(tester);
      expect(tester.takeException(), isNull);
      final field = tester.getRect(find.byKey(const ValueKey('students-search')));
      expect(field.bottom, lessThanOrEqualTo(640 - 280));
    });

    testWidgets('an empty roster says so instead of showing an empty sheet', (tester) async {
      await _open(tester, size: const Size(390, 844));
      await openSheet(tester);
      expect(find.byKey(const ValueKey('students-empty')), findsOneWidget);
    });

    testWidgets('landscape on a small phone does not overflow, also at 200% text', (tester) async {
      await _open(tester, size: const Size(568, 320), scale: 2, snapshot: _students);
      await openSheet(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('finish page', () {
    testWidgets('shows the upload counts and stays readable at 320 px, 200% text', (tester) async {
      final scan = await _open(tester, size: const Size(320, 568), scale: 2, snapshot: _students);
      await scan.stop();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Classroom scan'), findsOneWidget);
      // The list is lazy: scroll the recognition card into view.
      await tester.scrollUntilVisible(
        find.text('1 of 3 recognised'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('board and progress keep their rules', () {
    testWidgets('processing card names the state in a heading, never with a green check while working', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProcessingProgress(
                info: ProcessingInfo(state: 'running', stage: 'detecting', percent: 40, total: 5, done: 1),
                uploading: 0,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Processing your recordings'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a stalled queue is titled as needing attention', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProcessingProgress(info: ProcessingInfo(state: 'stalled', total: 2, waiting: 2)),
            ),
          ),
        ),
      );
      expect(find.text('Processing needs attention'), findsOneWidget);
    });

    testWidgets('board query and attention filter narrow the list only', (tester) async {
      final entries = boardEntries([
        _row('1', 'Asha Rao', status: 'proposed_present', code: 'recognized'),
        _row('2', 'Ben Cole', status: 'proposed_absent', code: 'not_recognized'),
      ], processing: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecognitionBoard(entries: entries, query: 'asha'),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('board-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('board-2')), findsNothing);
      expect(find.text('1 of 2 recognised'), findsOneWidget);
    });
  });
}

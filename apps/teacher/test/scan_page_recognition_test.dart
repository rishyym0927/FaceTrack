import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:facetrack_teacher/recognition_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);
const back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const wide = CameraDescription(
  name: 'ultrawide',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

class QuietCamera extends GuidedCamera {
  QuietCamera({List<CameraDescription> available = const [back, front]}) {
    cameras = available;
    selectedCamera = available.first;
  }
  final selections = <String>[];
  @override
  Future<void> initialize() async => ready = true;
  @override
  Future<void> start(List<String> order) async {
    recording = true;
    emit();
  }

  @override
  Future<void> selectCamera(CameraDescription choice) async {
    selections.add(choice.name);
    selectedCamera = choice;
    ready = true;
    emit();
  }

  @override
  Future<void> interrupt({bool lifecycle = false}) async {
    recording = false;
    ready = false;
  }
}

Map<String, dynamic> row(String id, String name,
        {String status = 'unassessed', String? code, Map<String, dynamic>? why}) =>
    {
      'student_id': id,
      'official_name': name,
      'enrollment_number': 'E$id',
      'status': status,
      'assessment_code': code,
      'evidence_summary': why ?? <String, dynamic>{},
    };

// The preview shows a spinner while there is no real camera, so pumpAndSettle would never end.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  late RecognitionSnapshot current;
  Future<RecognitionSnapshot> results() async => current;

  Future<ClassroomScan> open(WidgetTester tester, {QuietCamera? camera}) async {
    final scan = ClassroomScan(camera ?? QuietCamera(), (file) async {});
    addTearDown(scan.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ClassroomScanPage(scan: scan, results: results)),
    );
    await tester.pump();
    await tester.pump();
    return scan;
  }

  Future<void> openStudents(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('students-chip')));
    await settle(tester);
  }

  group('recognition list', () {
    testWidgets('the chip summarises, and the list opens on demand by name', (tester) async {
      current = RecognitionSnapshot([
        row('1', 'Asha Rao', status: 'proposed_present', code: 'recognized'),
        row('2', 'Ben Cole',
            status: 'proposed_absent', code: 'not_recognized', why: {'reason': 'not_seen'}),
      ]);
      await open(tester);
      expect(find.text('1 / 2'), findsOneWidget); // visible without opening anything
      expect(find.textContaining('Asha Rao'), findsNothing); // the list is not blocking the camera
      await openStudents(tester);
      expect(find.text('1 of 2 recognised'), findsOneWidget);
      expect(find.textContaining('Asha Rao'), findsOneWidget);
      expect(find.textContaining('Ben Cole'), findsOneWidget);
      expect(find.textContaining('Green means the server recognised'), findsOneWidget);
    });

    testWidgets('nobody is green before the server has recognised anyone', (tester) async {
      current = RecognitionSnapshot([row('1', 'Asha Rao'), row('2', 'Ben Cole')]);
      await open(tester);
      await openStudents(tester);
      expect(find.text('0 of 2 recognised'), findsOneWidget);
      expect(
        tester.widgetList<Icon>(find.byType(Icon)).where((i) => i.color == Colors.greenAccent),
        isEmpty,
      );
    });

    testWidgets('students turn yellow while a segment is still being processed', (tester) async {
      current = RecognitionSnapshot([
        row('1', 'Asha Rao', status: 'proposed_absent', code: 'not_recognized'),
      ], processing: true);
      await open(tester);
      await openStudents(tester);
      expect(find.text('Checking the latest recording…'), findsOneWidget);
      final icon = tester.widget<Icon>(find.descendant(
        of: find.byKey(const ValueKey('board-1')),
        matching: find.byType(Icon),
      ));
      expect(icon.color, Colors.amber);
    });

    testWidgets('the finish screen keeps showing the board, readable on light', (tester) async {
      current = RecognitionSnapshot([
        row('1', 'Asha Rao', status: 'proposed_present', code: 'recognized'),
      ]);
      final scan = await open(tester);
      await scan.stop();
      await tester.pump();
      expect(find.text('Classroom scan'), findsOneWidget);
      expect(find.text('1 of 1 recognised'), findsOneWidget);
      final icon = tester.widget<Icon>(find.descendant(
        of: find.byKey(const ValueKey('board-1')),
        matching: find.byType(Icon),
      ));
      expect(icon.color, RecognitionState.recognized.colorOnLight);
    });
  });

  group('layout keeps the camera visible', () {
    for (final size in [
      const Size(320, 568),
      const Size(360, 640),
      const Size(412, 915),
      const Size(768, 1024),
    ]) {
      testWidgets('portrait $size: compact controls, nothing overflows', (tester) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        current = RecognitionSnapshot([
          for (var i = 0; i < 100; i++)
            row('$i', 'Student number $i with a rather long name',
                status: i % 3 == 0 ? 'proposed_present' : 'proposed_absent',
                code: i % 3 == 0 ? 'recognized' : 'not_recognized'),
        ]);
        await open(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('34 / 100'), findsOneWidget);
        // The controls take well under a quarter of the screen height, so the camera stays large.
        final record = tester.getRect(find.byKey(const ValueKey('record-button')));
        expect(record.bottom, lessThanOrEqualTo(size.height));
        final chip = tester.getRect(find.byKey(const ValueKey('students-chip')));
        final controlsTop = chip.top < record.top ? chip.top : record.top;
        expect(size.height - controlsTop, lessThan(size.height * .30), reason: '$size');
        // Everything important is reachable on screen.
        for (final key in ['record-button', 'students-chip', 'flip-camera', 'scan-status']) {
          final r = tester.getRect(find.byKey(ValueKey(key)));
          expect(r.left >= 0 && r.right <= size.width && r.top >= 0 && r.bottom <= size.height, isTrue,
              reason: '$key at $size: $r');
        }
      });
    }
    testWidgets('landscape: controls move to a side rail and nothing overflows', (tester) async {
      tester.view.physicalSize = const Size(915, 412) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      current = RecognitionSnapshot([row('1', 'Asha Rao')]);
      await open(tester);
      expect(tester.takeException(), isNull);
      final record = tester.getRect(find.byKey(const ValueKey('record-button')));
      expect(record.left, greaterThan(915 * .8)); // on the right edge, not under the preview
      expect(record.bottom, lessThanOrEqualTo(412));
    });
    testWidgets('200% text does not overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 640) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      current = RecognitionSnapshot([row('1', 'Asha Rao')]);
      final scan = ClassroomScan(QuietCamera(), (file) async {});
      addTearDown(scan.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ClassroomScanPage(scan: scan, results: results),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('camera switching', () {
    testWidgets('the flip button is on the top bar and switches front and rear', (tester) async {
      current = const RecognitionSnapshot([]);
      final camera = QuietCamera();
      await open(tester, camera: camera);
      expect(find.byTooltip('Switch to front camera'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flip-camera')));
      await settle(tester);
      expect(camera.selections, ['front']);
      expect(find.byTooltip('Switch to rear camera'), findsOneWidget);
      expect(find.byTooltip('Toggle torch'), findsNothing); // a front camera has no torch
      await tester.tap(find.byKey(const ValueKey('flip-camera')));
      await settle(tester);
      expect(camera.selections, ['front', 'back']);
    });
    testWidgets('a phone with several rear lenses still toggles front and rear', (tester) async {
      current = const RecognitionSnapshot([]);
      final camera = QuietCamera(available: const [back, wide, front]);
      await open(tester, camera: camera);
      await tester.tap(find.byKey(const ValueKey('flip-camera')));
      await settle(tester);
      expect(camera.selections, ['front']);
      await tester.tap(find.byKey(const ValueKey('flip-camera')));
      await settle(tester);
      expect(camera.selections, ['front', 'back']); // the main lens, not the ultra-wide
    });
    testWidgets('there is no flip button on a phone with one camera', (tester) async {
      current = const RecognitionSnapshot([]);
      await open(tester, camera: QuietCamera(available: const [back]));
      expect(find.byKey(const ValueKey('flip-camera')), findsNothing);
    });
    testWidgets('it works while recording and recording continues', (tester) async {
      current = const RecognitionSnapshot([]);
      final camera = QuietCamera();
      final scan = await open(tester, camera: camera);
      await scan.start();
      await tester.pump();
      expect(camera.recording, isTrue);
      await tester.tap(find.byKey(const ValueKey('flip-camera')));
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(camera.selections, ['front']);
      expect(camera.recording, isTrue); // started again on the new camera
      expect(scan.scanning, isTrue);
    });
  });
}

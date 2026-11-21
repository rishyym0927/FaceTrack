import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:facetrack_teacher/recognition_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class QuietCamera extends GuidedCamera {
  @override
  Future<void> initialize() async => ready = true;
  @override
  Future<void> start(List<String> order) async => recording = true;
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

void main() {
  late RecognitionSnapshot current;
  Future<RecognitionSnapshot> results() async => current;

  Future<ClassroomScan> open(WidgetTester tester) async {
    final scan = ClassroomScan(QuietCamera(), (file) async {});
    addTearDown(scan.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ClassroomScanPage(scan: scan, results: results)),
    );
    await tester.pump();
    await tester.pump();
    return scan;
  }

  testWidgets('the camera view lists who is recognised, by name, and who is not', (tester) async {
    current = RecognitionSnapshot([
      row('1', 'Asha Rao', status: 'proposed_present', code: 'recognized'),
      row('2', 'Ben Cole',
          status: 'proposed_absent', code: 'not_recognized', why: {'reason': 'not_seen'}),
    ]);
    await open(tester);
    expect(find.text('1 of 2 recognised'), findsOneWidget);
    expect(find.textContaining('Asha Rao'), findsOneWidget);
    expect(find.textContaining('Ben Cole'), findsOneWidget);
    expect(find.textContaining('A student turns green on the list only after'), findsOneWidget);
    expect(find.textContaining('green box'), findsNothing); // the old, misleading wording
  });

  testWidgets('nobody is green before the server has recognised anyone', (tester) async {
    current = RecognitionSnapshot([row('1', 'Asha Rao'), row('2', 'Ben Cole')]);
    await open(tester);
    expect(find.text('0 of 2 recognised'), findsOneWidget);
    final greens = tester
        .widgetList<Icon>(find.byType(Icon))
        .where((i) => i.color == Colors.greenAccent);
    expect(greens, isEmpty);
  });

  testWidgets('students turn yellow while a segment is still being processed', (tester) async {
    current = RecognitionSnapshot([
      row('1', 'Asha Rao', status: 'proposed_absent', code: 'not_recognized'),
    ], processing: true);
    await open(tester);
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

  for (final size in [const Size(360, 640), const Size(640, 360)]) {
    testWidgets('a class of 100 fits a small phone at $size without overflow', (tester) async {
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
      expect(find.text('34 of 100 recognised'), findsOneWidget);
      // The Stop control stays reachable above the list.
      expect(find.textContaining('Stop'), findsWidgets);
    });
  }
}

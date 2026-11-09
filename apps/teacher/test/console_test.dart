import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:facetrack_teacher/console_api.dart';
import 'package:facetrack_teacher/spike_capture.dart';
import 'package:facetrack_teacher/test_console.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCamera implements CameraGateway {
  @override
  Future<void> initialize() async {}
  @override
  Future<void> start() async {}
  @override
  Future<XFile> stop() async => XFile('blob:synthetic-test-only');
  @override
  Future<void> release() async {}
  @override
  Widget preview() => const Text('Synthetic preview fixture');
}

class FakeBackend implements ConsoleBackend {
  FakeBackend({this.integrityOk = true, this.volunteers = const [], this.done = 0});
  final bool integrityOk;
  final List<Map<String, dynamic>> volunteers;
  final int done;

  @override
  Future<Map<String, dynamic>> status() async => {
    'integrity': {
      'ok': integrityOk,
      'message': integrityOk
          ? 'Model and settings are unchanged.'
          : 'The model or settings changed since testing began. Stop and contact the project owner.',
    },
    'volunteers': volunteers,
  };

  @override
  Future<List<Map<String, dynamic>>> scenarios() async => [
    {
      'id': 'both_known',
      'title': 'Everyone enrolled is present',
      'how': 'Two or more enrolled volunteers sit in view.',
      'unknown_person': false,
      'min_present': 2,
      'max_present': null,
    },
    {
      'id': 'no_face',
      'title': 'Nobody in view',
      'how': 'An empty scene.',
      'unknown_person': false,
      'min_present': 0,
      'max_present': 0,
    },
  ];

  @override
  Future<Map<String, dynamic>> summary() async => {
    'verdict': 'In progress: $done of 6 scenarios done.',
    'done': done,
    'total': 6,
    'passed': 0,
    'false_presence_total': 0,
    'missed_total': 0,
    'all_stable': null,
    'slowest_clip_processing_ms': null,
    'disclaimer': 'Not a guarantee of classroom accuracy.',
    'rule': 'First scored attempt is official.',
    'scenarios': [
      {'id': 'both_known', 'title': 'x', 'status': 'pass', 'attempts': 1, 'rejected': 0},
      {'id': 'no_face', 'title': 'y', 'status': 'not_done', 'attempts': 0, 'rejected': 0},
    ],
  };

  @override
  Future<Map<String, dynamic>> exportData() async => {};
  @override
  Future<Map<String, dynamic>> enrol({
    required String label,
    required Uint8List video,
    required String extension,
  }) async => {'id': 'p01', 'label': label};
  @override
  Future<void> removePerson(String id) async {}
  @override
  Future<Map<String, dynamic>> run({
    required String scenario,
    required List<String> present,
    required bool stranger,
    required Uint8List video,
    required String extension,
  }) async => {};
  @override
  Future<void> wipe() async {}
}

Future<void> open(WidgetTester tester, FakeBackend backend) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = CaptureSession(FakeCamera());
  addTearDown(session.dispose);
  await tester.pumpWidget(ModelTestConsoleApp(backend: backend, session: session));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Changed model hides every test step and says to stop', (tester) async {
    await open(tester, FakeBackend(integrityOk: false));
    expect(find.textContaining('Stop and contact the project owner'), findsOneWidget);
    expect(find.text('2. Volunteers'), findsNothing);
    expect(find.text('3. The six test recordings'), findsNothing);
  });

  testWidgets('Fresh start asks for volunteers and blocks recordings', (tester) async {
    await open(tester, FakeBackend());
    expect(find.text('1. System check'), findsOneWidget);
    expect(find.textContaining('Enrol at least 2 volunteers'), findsOneWidget);
    final save = find.widgetWithText(FilledButton, 'Save this volunteer');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.textContaining('To save: type a name'), findsOneWidget);
    final start = find.widgetWithText(OutlinedButton, 'Start this recording');
    final again = find.widgetWithText(OutlinedButton, 'Record again (extra try)');
    expect(start, findsOneWidget);
    expect(again, findsOneWidget);
    expect(tester.widget<OutlinedButton>(start).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(again).onPressed, isNull);
    expect(find.text('Everyone enrolled is present'), findsOneWidget);
    expect(find.text('Matched'), findsOneWidget);
    expect(find.text('Not done'), findsOneWidget);
    expect(find.textContaining('In progress'), findsOneWidget);
    expect(find.text('Delete all test data'), findsOneWidget);
  });

  testWidgets('Volunteers appear as choices once a scenario is opened', (tester) async {
    await open(
      tester,
      FakeBackend(
        volunteers: [
          {'id': 'p01', 'label': 'Asha'},
          {'id': 'p02', 'label': 'Ravi'},
        ],
      ),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Record again (extra try)'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'Asha'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Ravi'), findsOneWidget);
    final check = find.widgetWithText(FilledButton, 'Check this recording');
    expect(tester.widget<FilledButton>(check).onPressed, isNull);
    expect(find.textContaining('Everyone in view has agreed'), findsOneWidget);
  });

  testWidgets('Guided console stays usable on a phone with large text', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = CaptureSession(FakeCamera());
    addTearDown(session.dispose);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: ModelTestConsoleApp(backend: FakeBackend(), session: session),
    ));
    await tester.pumpAndSettle();
    expect(find.text('See how the face model performs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

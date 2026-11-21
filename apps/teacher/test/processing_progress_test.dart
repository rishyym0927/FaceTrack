import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:facetrack_teacher/processing_progress.dart';
import 'package:facetrack_teacher/recognition_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessingInfo info({
  String state = 'running',
  String? stage,
  int? percent,
  int waiting = 0,
  int running = 1,
  int done = 0,
  int failed = 0,
  int total = 5,
  int wait = 0,
  bool online = true,
}) => ProcessingInfo(
  state: state,
  stage: stage,
  percent: percent,
  waiting: waiting,
  running: running,
  done: done,
  failed: failed,
  total: total,
  oldestWaitSeconds: wait,
  workerOnline: online,
);

ProgressState? at(List<ProgressStep> steps, int i) => steps[i].state;
int activeIndex(List<ProgressStep> steps) =>
    steps.indexWhere((s) => s.state == ProgressState.active || s.state == ProgressState.warning);

void main() {
  group('server block', () {
    test('is read leniently, so an older server shows nothing rather than failing', () {
      expect(ProcessingInfo.fromJson(null).state, 'idle');
      expect(ProcessingInfo.fromJson('nonsense').total, 0);
      final parsed = ProcessingInfo.fromJson({
        'state': 'running', 'stage': 'detecting', 'percent': 40, 'waiting': 1,
        'running': 1, 'done': 2, 'failed': 0, 'total': 4, 'oldest_wait_seconds': 12,
        'worker_online': true,
      });
      expect(parsed.stage, 'detecting');
      expect(parsed.percent, 40);
      expect(parsed.done, 2);
      expect(parsed.currentSegment, 3);
    });
  });

  group('the six stages', () {
    test('uploading comes first and shows how many are left to send', () {
      final steps = progressSteps(info(state: 'idle', running: 0, total: 0), uploading: 2);
      expect(steps.map((s) => s.label), [
        'Uploading segments', 'Preparing videos', 'Detecting faces',
        'Recognizing students', 'Matching attendance', 'Finalizing results',
      ]);
      expect(activeIndex(steps), 0);
      expect(steps[0].detail, '2 segments left to send');
      expect(steps.skip(1).every((s) => s.state == ProgressState.pending), isTrue);
    });
    test('each server stage lights the matching step, earlier ones done, later ones pending', () {
      const stages = {
        'preparing': 1, 'detecting': 2, 'recognizing': 3, 'matching': 4, 'finalizing': 5,
      };
      stages.forEach((stage, index) {
        final steps = progressSteps(info(stage: stage), uploading: 0);
        expect(activeIndex(steps), index, reason: stage);
        for (var i = 0; i < steps.length; i++) {
          if (i < index) expect(at(steps, i), ProgressState.done, reason: '$stage $i');
          if (i > index) expect(at(steps, i), ProgressState.pending, reason: '$stage $i');
        }
      });
    });
    test('percent is shown only where it is meaningful', () {
      expect(progressSteps(info(stage: 'detecting', percent: 40), uploading: 0)[2].detail, '40%');
      expect(progressSteps(info(stage: 'recognizing', percent: 75), uploading: 0)[3].detail, '75%');
      expect(progressSteps(info(stage: 'matching', percent: 0), uploading: 0)[4].detail, isNull);
    });
    test('an unknown stage from a newer server falls back to preparing', () {
      expect(activeIndex(progressSteps(info(stage: 'something-new'), uploading: 0)), 1);
    });
    test('waiting for a worker marks the preparing step as waiting', () {
      final steps = progressSteps(info(state: 'waiting', running: 0, waiting: 3), uploading: 0);
      expect(activeIndex(steps), 1);
      expect(steps[1].state, ProgressState.active);
      expect(steps[1].detail, 'Waiting for its turn');
    });
    test('no worker running is a warning, not a spinner', () {
      final steps = progressSteps(
        info(state: 'stalled', running: 0, waiting: 5, wait: 200, online: false), uploading: 0);
      expect(steps[1].state, ProgressState.warning);
      expect(steps[1].detail, contains('No processing worker'));
    });
    test('everything finished shows all six as done, and nothing before any recording', () {
      final done = progressSteps(info(state: 'idle', running: 0, done: 3, total: 3), uploading: 0);
      expect(done.length, 6);
      expect(done.every((s) => s.state == ProgressState.done), isTrue);
      expect(progressSteps(info(state: 'idle', running: 0, total: 0), uploading: 0), isEmpty);
    });
  });

  group('overall progress', () {
    test('moves forward through every stage of every segment and stays within 0 to 1', () {
      var last = -1.0;
      for (var done = 0; done < 5; done++) {
        for (final (stage, percent) in [
          ('preparing', null), ('detecting', 0), ('detecting', 50), ('detecting', 100),
          ('recognizing', 0), ('recognizing', 100), ('matching', null), ('finalizing', null),
        ]) {
          final value = overallProgress(info(stage: stage, percent: percent, done: done));
          expect(value, inInclusiveRange(0, 1));
          expect(value, greaterThanOrEqualTo(last), reason: '$done $stage $percent');
          last = value;
        }
      }
      expect(overallProgress(info(state: 'idle', running: 0, done: 5)), 1);
      expect(overallProgress(info(state: 'idle', running: 0, total: 0)), 0);
    });
  });

  group('problems are explained, never left as a spinner', () {
    test('a stalled queue says processing is not running and that recordings are safe', () {
      final text = processingProblem(
        info(state: 'stalled', running: 0, waiting: 5, wait: 200, online: false))!;
      expect(text, contains('not running'));
      expect(text, contains('saved'));
      expect(text, contains('administrator'));
    });
    test('a busy queue explains the delay', () {
      expect(processingProblem(info(state: 'waiting', running: 0, waiting: 4, wait: 200)),
          contains('4 segments are waiting'));
      expect(processingProblem(info(state: 'waiting', running: 0, waiting: 4, wait: 20)), isNull);
    });
    test('failed segments say what to do', () {
      expect(processingProblem(info(state: 'idle', running: 0, failed: 2, done: 3)),
          contains('2 segments could not be processed'));
    });
    test('healthy processing has no problem text', () {
      expect(processingProblem(info(stage: 'detecting', percent: 20)), isNull);
    });
    test('the one-line summary names the segment and the step', () {
      expect(processingSummary(info(stage: 'detecting', percent: 40, done: 1), uploading: 0),
          'Segment 2 of 5 · Detecting faces 40%');
      expect(processingSummary(info(state: 'idle', running: 0, total: 0), uploading: 3),
          'Uploading · 3 left');
      expect(processingSummary(info(state: 'idle', running: 0, total: 0), uploading: 0), '');
      expect(processingSummary(info(state: 'stalled', running: 0, waiting: 2, online: false),
          uploading: 0), 'Processing is not running');
    });
  });

  group('widget', () {
    Future<void> show(WidgetTester tester, ProcessingProgress widget, {bool dark = false}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            backgroundColor: dark ? Colors.black : null,
            body: SingleChildScrollView(child: widget),
          ),
        ));

    testWidgets('shows all six stages with the current one in progress', (tester) async {
      await show(tester,
          ProcessingProgress(info: info(stage: 'detecting', percent: 40, done: 1)));
      for (final label in ['Uploading segments', 'Preparing videos', 'Detecting faces',
          'Recognizing students', 'Matching attendance', 'Finalizing results']) {
        expect(find.textContaining(label), findsOneWidget, reason: label);
      }
      expect(find.textContaining('40%'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2)); // uploading, preparing
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('2 of 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('processing-problem')), findsNothing);
    });
    testWidgets('a stalled queue shows the explanation and a reference to quote', (tester) async {
      await show(
        tester,
        ProcessingProgress(
          info: info(state: 'stalled', running: 0, waiting: 5, wait: 200, online: false),
          reference: '6ffb6331',
        ),
      );
      expect(find.byKey(const ValueKey('processing-problem')), findsOneWidget);
      expect(find.textContaining('not running right now'), findsOneWidget);
      expect(find.text('Reference: 6ffb6331'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
    });
    testWidgets('finished work shows six ticks and no progress bar', (tester) async {
      await show(tester,
          ProcessingProgress(info: info(state: 'idle', running: 0, done: 3, total: 3)));
      expect(find.byIcon(Icons.check_circle), findsNWidgets(6));
      expect(find.byKey(const ValueKey('overall-progress')), findsNothing);
    });
    testWidgets('nothing is drawn when there is nothing to show', (tester) async {
      await show(tester,
          ProcessingProgress(info: info(state: 'idle', running: 0, total: 0)));
      expect(find.byKey(const ValueKey('processing-progress')), findsNothing);
    });
    testWidgets('readable on the dark camera view too, and at 200% text', (tester) async {
      tester.view.physicalSize = const Size(360, 640) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SingleChildScrollView(
            child: ProcessingProgress(
              onDark: true,
              info: info(state: 'stalled', running: 0, waiting: 5, wait: 200, online: false),
              reference: 'abc12345',
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('on the scan screens', () {
    const rear = CameraDescription(
      name: 'rear', lensDirection: CameraLensDirection.back, sensorOrientation: 90);
    late RecognitionSnapshot current;
    Future<RecognitionSnapshot> results() async => current;

    Future<ClassroomScan> open(WidgetTester tester) async {
      final camera = _Camera()..cameras = [rear]..selectedCamera = rear;
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ClassroomScanPage(scan: scan, results: results, reference: '6ffb6331'),
      ));
      await tester.pump();
      await tester.pump();
      return scan;
    }

    testWidgets('the camera view names the segment and step without covering the camera', (tester) async {
      current = RecognitionSnapshot(const [],
          info: info(stage: 'detecting', percent: 40, done: 1), processing: true);
      await open(tester);
      expect(find.byKey(const ValueKey('processing-banner')), findsOneWidget);
      expect(find.text('Segment 2 of 5 · Detecting faces 40%'), findsOneWidget);
    });
    testWidgets('a stalled queue is a clear warning on the camera view', (tester) async {
      current = RecognitionSnapshot(const [],
          info: info(state: 'stalled', running: 0, waiting: 5, wait: 200, online: false),
          processing: true);
      await open(tester);
      expect(find.textContaining('not running right now'), findsOneWidget);
    });
    testWidgets('the finish screen lists the six stages and the reference', (tester) async {
      current = RecognitionSnapshot(const [],
          info: info(state: 'stalled', running: 0, waiting: 5, wait: 200, online: false),
          processing: true);
      final scan = await open(tester);
      await scan.stop();
      await tester.pump();
      expect(find.byKey(const ValueKey('processing-progress')), findsOneWidget);
      expect(find.text('Reference: 6ffb6331'), findsOneWidget);
      expect(find.textContaining('Matching attendance'), findsOneWidget);
    });
  });
}

class _Camera extends GuidedCamera {
  @override
  Future<void> initialize() async => ready = true;
  @override
  Future<void> interrupt({bool lifecycle = false}) async {
    recording = false;
    ready = false;
  }
}

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> capture(int sampled, int faces, int rejects) => {
  'status': 'review_required',
  'quality_json': {
    'counts': {
      'sampled_frames': sampled,
      'detections': faces,
      'quality_rejects': rejects,
    },
  },
};

void main() {
  test('Explains the real poor capture: 1 of 12 faces usable', () {
    final q = captureQuality(capture(12, 12, 11))!;
    expect(q.poor, isTrue);
    expect(q.text, startsWith('Only 1 of 12 faces found were clear enough'));
    expect(q.text, contains('0.5–1 m'));
  });

  test('No faces found asks to point the camera at faces', () {
    final q = captureQuality(capture(12, 0, 0))!;
    expect(q.poor, isTrue);
    expect(q.text, startsWith('No faces were found in the 12 frames checked'));
  });

  test('A good capture is reported without retake tips', () {
    final q = captureQuality(capture(12, 30, 4))!;
    expect(q.poor, isFalse);
    expect(q.text, '26 of 30 faces found were clear enough to use.');
  });

  test('Nothing is shown before processing has counts', () {
    expect(captureQuality({'status': 'queued', 'quality_json': {}}), isNull);
    expect(captureQuality({'status': 'queued'}), isNull);
  });

  for (final width in const [360.0, 1440.0]) {
    testWidgets(
      'Upload problem and quality note fit at $width px with 200% text',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: ListView(
                  children: [
                    const CaptureProblem(
                      failure: AppFailure(
                        'Upload failed. Check the connection.',
                      ),
                      clipKept: true,
                    ),
                    CaptureQualityNote(captureQuality(capture(12, 12, 11))!),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('The recording was not uploaded'), findsOneWidget);
        expect(find.textContaining('Your recording is kept'), findsOneWidget);
        expect(find.textContaining('Only 1 of 12'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'Coverage counts recognised students among those with face enrolment',
    () {
      Map<String, dynamic> row(String? code) => {'assessment_code': code};
      expect(captureCoverage([row(null), row(null)]), isNull);
      final partial = captureCoverage([
        row('recognized'),
        row('limited_capture'),
        row('not_recognized'),
        row('template_ineligible'),
      ])!;
      expect(partial.poor, isTrue);
      expect(
        partial.text,
        'Recognised so far: 1 of 3 students with face enrolment. '
        '2 not seen yet: record another clip covering them. '
        '1 without face enrolment must be marked manually.',
      );
      final none = captureCoverage([row('template_ineligible')])!;
      expect(
        none.text,
        startsWith('No student on this roster has an approved face enrolment'),
      );
      final all = captureCoverage([row('recognized'), row('recognized')])!;
      expect(all.poor, isFalse);
      expect(
        all.text,
        'Recognised so far: 2 of 2 students with face enrolment.',
      );
    },
  );
}

import 'package:facetrack_teacher/scan_quality.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('No breakdown gives no cause', () {
    expect(rejectCause(null), isNull);
    expect(rejectCause('x'), isNull);
    expect(rejectCause({}), isNull);
    expect(rejectCause({'reject_reasons': null}), isNull);
    expect(rejectCause({'reject_reasons': {}}), isNull);
    expect(rejectCause({'reject_reasons': 5}), isNull);
  });

  test('Unknown, zero, negative and non-numeric entries are ignored', () {
    expect(
      rejectCause({
        'reject_reasons': {
          'mystery': 9,
          'blur': 0,
          'small': -3,
          'edge': 'many',
        },
      }),
      isNull,
    );
  });

  test('One dominant reason is named in plain words', () {
    final text = rejectCause({
      'reject_reasons': {'brightness': 9, 'blur': 1},
    })!;
    expect(text, startsWith('Mostly: the picture was too dark or too bright'));
    expect(text, isNot(contains('blurred')));
  });

  test('A strong second reason is added, a weak one is not', () {
    final both = rejectCause({
      'reject_reasons': {'small': 5, 'blur': 3, 'edge': 1},
    })!;
    expect(both, contains('too small'));
    expect(both, contains('also faces were blurred'));
    expect(both, isNot(contains('cut off')));
  });

  test('A split between reasons says Mainly', () {
    final text = rejectCause({
      'reject_reasons': {'small': 4, 'blur': 3, 'edge': 3},
    })!;
    expect(text, startsWith('Mainly: faces were too small'));
  });

  test('Ties are broken the same way every time', () {
    final a = rejectCause({
      'reject_reasons': {'small': 2, 'blur': 2},
    });
    final b = rejectCause({
      'reject_reasons': {'blur': 2, 'small': 2},
    });
    expect(a, b);
  });

  Map<String, dynamic> capture(Map<String, dynamic> reasons) => {
    'quality_json': {
      'counts': {'sampled_frames': 12, 'detections': 20, 'quality_rejects': 15},
      'reject_reasons': reasons,
    },
  };

  test('A poor capture names the cause before the retake tips', () {
    final q = captureQuality(capture({'brightness': 12, 'blur': 3}))!;
    expect(q.poor, isTrue);
    expect(q.text, startsWith('The camera did not get a clear view'));
    expect(q.text, contains('Mostly: the picture was too dark'));
    expect(q.text.indexOf('Mostly'), lessThan(q.text.indexOf('0.5–1 m')));
  });

  test('A poor capture without a breakdown keeps the old text', () {
    final q = captureQuality(capture({}))!;
    expect(q.text, isNot(contains('Mostly')));
    expect(q.text, contains('0.5–1 m'));
  });

  test('A good capture stays quiet even with some rejected faces', () {
    expect(
      captureQuality({
        'quality_json': {
          'counts': {
            'sampled_frames': 12,
            'detections': 30,
            'quality_rejects': 4,
          },
          'reject_reasons': {'blur': 4},
        },
      }),
      isNull,
    );
  });
}

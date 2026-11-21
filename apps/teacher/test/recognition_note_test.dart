import 'package:facetrack_teacher/attendance_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Each worker reason becomes plain advice for the teacher', () {
    String? note(String? reason) =>
        recognitionNote({'evidence_summary': {'reason': reason}});
    expect(note('not_seen'), contains('closer'));
    expect(note('seen_too_briefly'), contains('3 seconds'));
    expect(note('weak_match'), contains('lighting'));
    expect(note('look_alike'), contains('similar'));
    expect(note('recognized'), isNull);
    expect(note(null), isNull);
  });
  test('A student without an approved enrolment is told why', () {
    expect(
      recognitionNote({'assessment_code': 'template_ineligible'}),
      contains('No approved face enrolment'),
    );
  });
  test('Results from an older worker, with no reason, show nothing', () {
    expect(recognitionNote({'evidence_summary': {'usable_observations': 5}}), isNull);
    expect(recognitionNote({'evidence_summary': null}), isNull);
  });
}

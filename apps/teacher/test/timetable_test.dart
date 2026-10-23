import 'package:facetrack_teacher/teacher_timetable.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Timetable preview suggests the next actual class date', () {
    final rows = [
      {
        'weekday': 'MON',
        'effective_from': '2026-10-26',
        'effective_until': '2026-11-30',
      },
    ];
    expect(
      nextTimetableDate(rows, referenceDate: DateTime(2026, 10, 23)),
      DateTime(2026, 10, 26),
    );
    expect(
      nextTimetableDate(rows, referenceDate: DateTime(2026, 12, 1)),
      isNull,
    );
  });
}

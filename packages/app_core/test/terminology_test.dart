import 'package:facetrack_models/facetrack_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semesters read as ordinals', () {
    expect(
      [1, 2, 3, 4, 5, 7, 11, 12, 13, 21].map(semesterLabel),
      [
        '1st Semester',
        '2nd Semester',
        '3rd Semester',
        '4th Semester',
        '5th Semester',
        '7th Semester',
        '11th Semester',
        '12th Semester',
        '13th Semester',
        '21st Semester',
      ],
    );
  });

  test('semester terms use the institute wording, other codes pass through', () {
    expect(termLabel('2026-ODD'), 'Odd Semester 2026');
    expect(termLabel('2026-even'), 'Even Semester 2026');
    expect(termLabel('T1'), 'T1');
  });

  test('a subject line shows subject code, branch, semester and section', () {
    final o = Offering.fromJson({
      'id': 'o1',
      'title': 'Design & Analysis of Algorithm',
      'course_code': 'BCS 201',
      'term_code': '2026-ODD',
      'branch': 'CSE',
      'semester': 3,
      'section': 'CSE1',
      'version': 1,
      'status': 'active',
    });
    expect(o.subtitle, 'BCS 201 · CSE · 3rd Semester · Section CSE1');
    expect(o.termTitle, 'Odd Semester 2026');
  });
}

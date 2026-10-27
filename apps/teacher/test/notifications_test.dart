import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_teacher/teacher_notifications.dart';

Offering offering() => Offering.fromJson({
  'id': 'o1',
  'title': 'Data Structures',
  'course_code': 'BCS 201',
  'term_code': '2026-ODD',
  'branch': 'CSE',
  'semester': 3,
  'section': 'CSE1',
  'version': 1,
  'status': 'active',
});

void main() {
  test('Pending subject work becomes action notices with links', () {
    final w = SubjectWork(offering())
      ..joinRequests = 2
      ..faceReviews = 1
      ..openQueries = 0
      ..sessions = [
        {
          'id': 's1',
          'status': 'review_required',
          'starts_at': '2026-10-27T04:00:00Z',
        },
        {
          'id': 's2',
          'status': 'finalized',
          'starts_at': '2026-10-26T04:00:00Z',
        },
        {'id': 's3', 'status': 'no_data', 'starts_at': '2026-10-25T04:00:00Z'},
        {'id': 's4', 'status': 'open', 'starts_at': '2026-10-27T01:00:00Z'},
        {'id': 's5', 'status': 'open', 'starts_at': '2026-10-27T05:30:00Z'},
      ];
    final notices = subjectNotices(
      w,
      now: DateTime.utc(2026, 10, 27, 6),
    ).toList();
    expect(notices.map((n) => n.id), [
      'join:o1:2',
      'face:o1:1',
      'session:s1:review_required',
      'session:s3:no_data',
      'session:s4:open',
    ]);
    expect(notices.first.title, '2 join requests · Data Structures');
    expect(notices[2].route, '/sessions/s1');
    expect(notices[3].body, contains('manually'));
    expect(notices.last.tone, NoticeTone.warning);
  });

  test('Admin notices cover setup and missing logins', () {
    final notices = adminNotices(
      offerings: 0,
      teachers: [
        {'auth_user_id': null},
        {'auth_user_id': 'u'},
      ],
      students: [
        {'auth_user_id': null},
        {'auth_user_id': null},
      ],
    ).toList();
    expect(notices.map((n) => n.title), [
      'Finish institute setup',
      '1 faculty without a login',
      '2 students without a login',
    ]);
    expect(notices.every((n) => n.route == '/admin'), isTrue);
    expect(
      adminNotices(offerings: 3, teachers: const [], students: null),
      isEmpty,
    );
  });
}

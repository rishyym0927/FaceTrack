import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_student/student_notifications.dart';

Json offering(String id, String title) => {
  'id': id,
  'title': title,
  'course_code': 'BCS 201',
  'term_code': '2026-ODD',
  'branch': 'CSE',
  'semester': 3,
  'section': 'CSE1',
  'version': 1,
  'status': 'active',
};

Enrollment enrolment(String id, String status, {String? reason}) =>
    Enrollment.fromJson({
      'id': id,
      'offering_id': 'o-$id',
      'student_id': 's1',
      'status': status,
      'version': 1,
      'offering': offering('o-$id', 'Subject $id'),
      'reason': reason,
    });

Json publication(String id, String offering, String status, String at) => {
  'id': id,
  'offering_id': offering,
  'status': status,
  'starts_at': at,
  'published_at': at,
};

void main() {
  test('Enrolment requests become waiting, approved and declined notices', () {
    final notices = enrolmentNotices([
      enrolment('a', 'requested'),
      enrolment('b', 'active'),
      enrolment('c', 'rejected', reason: 'Wrong section'),
      enrolment('d', 'withdrawn'),
    ]).toList();
    expect(notices.map((n) => n.title), [
      'Waiting for approval: Subject a',
      'Enrolled in Subject b',
      'Request declined: Subject c',
    ]);
    expect(notices[1].route, '/classes/o-b');
    expect(notices[2].body, contains('Wrong section'));
  });

  test('Face enrolment state picks the most relevant single notice', () {
    String title(Json s) => faceNotices(s).single.title;
    expect(
      title({'attempt': null, 'active_sets': []}),
      'Set up face enrolment',
    );
    expect(
      title({
        'attempt': {'id': 'x', 'status': 'review_required'},
        'active_sets': [],
      }),
      'Face enrolment is waiting for review',
    );
    expect(
      title({
        'attempt': {'id': 'x', 'status': 'active'},
        'active_sets': [
          {'id': 't', 'activated_at': '2026-10-20T10:00:00Z'},
        ],
      }),
      'Face enrolment is active',
    );
    final rejected = faceNotices({
      'attempt': {'id': 'x', 'status': 'rejected', 'reason': 'Face too dark'},
      'active_sets': [],
    }).single;
    expect(rejected.tone, NoticeTone.action);
    expect(rejected.body, contains('Face too dark'));
  });

  test('Published attendance lists newest first and flags low attendance', () {
    final rows = [
      publication('p1', 'o1', 'present', '2026-10-01T09:00:00Z'),
      publication('p2', 'o1', 'absent', '2026-10-03T09:00:00Z'),
      publication('p3', 'o1', 'absent', '2026-10-05T09:00:00Z'),
      publication('p4', 'o1', 'unassessed', '2026-10-06T09:00:00Z'),
      publication('p5', 'o2', 'present', '2026-10-02T09:00:00Z'),
    ];
    final notices = attendanceNotices(rows, {
      'o1': 'Maths',
      'o2': 'Physics',
    }).toList();
    final published = notices.where((n) => n.id.startsWith('pub:')).toList();
    expect(published.first.id, 'pub:p3');
    expect(published.any((n) => n.id == 'pub:p4'), isFalse);
    expect(
      published.firstWhere((n) => n.id == 'pub:p2').tone,
      NoticeTone.warning,
    );
    // Maths: 1 of 3 assessed (unassessed excluded) = 33.3%; Physics is 100%.
    final low = notices.where((n) => n.id.startsWith('low:')).toList();
    expect(low.single.title, 'Below 75% in Maths');
    expect(low.single.body, contains('33.3%'));
  });

  test('Only resolved queries notify', () {
    final notices = queryNotices(
      [
        {'id': 'q1', 'status': 'open', 'offering_id': 'o1'},
        {
          'id': 'q2',
          'status': 'accepted',
          'offering_id': 'o1',
          'resolution_reason': 'Was present',
        },
        {'id': 'q3', 'status': 'rejected', 'offering_id': 'o1'},
      ],
      {'o1': 'Maths'},
    ).toList();
    expect(notices.map((n) => n.title), [
      'Query accepted: Maths',
      'Query declined: Maths',
    ]);
    expect(notices.first.body, contains('Was present'));
  });
}

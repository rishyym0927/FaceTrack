import 'package:flutter/material.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

String _date(DateTime t) {
  final l = t.toLocal();
  return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')} '
      '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

bool isActiveAdmin(AuthController auth) =>
    auth.account?.members.any(
      (m) =>
          m.role == 'admin' &&
          m.status == 'active' &&
          m.instituteId == auth.institute,
    ) ??
    false;

/// What one subject needs from its faculty, from four existing endpoints.
class SubjectWork {
  SubjectWork(this.offering);
  final Offering offering;
  int joinRequests = 0, faceReviews = 0, openQueries = 0;
  List<Json> sessions = [];
  final failed = <String>[];
}

Future<SubjectWork> loadSubjectWork(
  ApiClient api,
  String institute,
  Offering o,
) async {
  final w = SubjectWork(o);
  Future<void> part(String name, Future<void> Function() load) async {
    try {
      await load();
    } catch (_) {
      w.failed.add(name);
    }
  }

  await Future.wait([
    part('join requests', () async {
      w.joinRequests = (await fetchAllPages(
        api,
        '/v1/offerings/${o.id}/roster',
        institute,
        query: {'status': 'requested'},
        maxPages: 2,
      )).length;
    }),
    part('face reviews', () async {
      w.faceReviews = (await fetchAllPages(
        api,
        '/v1/offerings/${o.id}/biometric-enrollments',
        institute,
        maxPages: 2,
      )).length;
    }),
    part('attendance queries', () async {
      w.openQueries = (await fetchAllPages(
        api,
        '/v1/offerings/${o.id}/attendance-disputes',
        institute,
        query: {'status': 'open'},
        maxPages: 2,
      )).length;
    }),
    part('sessions', () async {
      w.sessions = await fetchAllPages(
        api,
        '/v1/sessions',
        institute,
        query: {'offering_id': o.id},
        maxPages: 3,
      );
    }),
  ]);
  return w;
}

Iterable<AppNotice> subjectNotices(SubjectWork w, {DateTime? now}) sync* {
  final o = w.offering, route = '/classes/${o.id}';
  if (w.joinRequests > 0) {
    yield AppNotice(
      id: 'join:${o.id}:${w.joinRequests}',
      title:
          '${w.joinRequests} join ${w.joinRequests == 1 ? 'request' : 'requests'} · ${o.title}',
      body:
          'Students are waiting for you to approve or decline their enrolment.',
      tone: NoticeTone.action,
      icon: Icons.person_add_alt,
      route: route,
      ongoing: true,
    );
  }
  if (w.faceReviews > 0) {
    yield AppNotice(
      id: 'face:${o.id}:${w.faceReviews}',
      title:
          '${w.faceReviews} face ${w.faceReviews == 1 ? 'enrolment' : 'enrolments'} to review · ${o.title}',
      body: 'Check each recording and approve or reject it so the student can be recognised.',
      tone: NoticeTone.action,
      icon: Icons.face_retouching_natural,
      route: route,
      ongoing: true,
    );
  }
  if (w.openQueries > 0) {
    yield AppNotice(
      id: 'query:${o.id}:${w.openQueries}',
      title:
          '${w.openQueries} attendance ${w.openQueries == 1 ? 'query' : 'queries'} · ${o.title}',
      body: 'Students asked you to recheck a published result.',
      tone: NoticeTone.action,
      icon: Icons.chat_bubble_outline,
      route: route,
      ongoing: true,
    );
  }
  final current = now ?? DateTime.now();
  for (final s in w.sessions) {
    final status = s['status'], starts = _time(s['starts_at']);
    final when = starts == null ? '' : ' · ${_date(starts)}';
    if (status == 'closed' ||
        status == 'review_required' ||
        status == 'no_data') {
      yield AppNotice(
        id: 'session:${s['id']}:$status',
        title: 'Review and publish: ${o.title}$when',
        body: status == 'no_data'
            ? 'No usable recording was captured. Mark attendance manually, then publish.'
            : 'Recognition has finished. Check the suggestions and publish attendance.',
        tone: NoticeTone.action,
        icon: Icons.fact_check_outlined,
        route: '/sessions/${s['id']}',
        time: starts,
        ongoing: true,
      );
    } else if (status == 'open' &&
        starts != null &&
        current.difference(starts).inHours >= 3) {
      yield AppNotice(
        id: 'session:${s['id']}:open',
        title: 'Session still open: ${o.title}$when',
        body: 'Close it once the final recording has processed, then review and publish.',
        tone: NoticeTone.warning,
        icon: Icons.timer_outlined,
        route: '/sessions/${s['id']}',
        time: starts,
        ongoing: true,
      );
    }
  }
}

Iterable<AppNotice> adminNotices({
  required int offerings,
  required List<Json> teachers,
  required List<Json>? students,
}) sync* {
  if (offerings == 0) {
    yield const AppNotice(
      id: 'admin:setup',
      title: 'Finish institute setup',
      body: 'No subjects are allocated to sections yet. Follow the setup checklist in Admin.',
      tone: NoticeTone.action,
      icon: Icons.checklist,
      route: '/admin',
      ongoing: true,
    );
  }
  final noLoginTeachers = teachers
      .where((t) => t['auth_user_id'] == null)
      .length;
  if (noLoginTeachers > 0) {
    yield AppNotice(
      id: 'admin:faculty-login:$noLoginTeachers',
      title: '$noLoginTeachers faculty without a login',
      body: 'Create their login from Admin › People so they can sign in.',
      tone: NoticeTone.info,
      icon: Icons.key_outlined,
      route: '/admin',
      ongoing: true,
    );
  }
  final noLoginStudents =
      students?.where((t) => t['auth_user_id'] == null).length ?? 0;
  if (noLoginStudents > 0) {
    yield AppNotice(
      id: 'admin:student-login:$noLoginStudents',
      title: '$noLoginStudents students without a login',
      body: 'Create logins from Admin › People, or let students sign up and link their enrolment number.',
      tone: NoticeTone.info,
      icon: Icons.key_outlined,
      route: '/admin',
      ongoing: true,
    );
  }
}

/// Notices for faculty (and, for active admins, institute setup items).
Future<NoticeBatch> teacherNotifications(
  ApiClient api,
  String institute,
  AuthController auth,
) async {
  final c = NoticeCollector();
  var offeringCount = 0;
  var truncated = false;
  await c.source('subjects', () async {
    final result = await api.send(
      'GET',
      '/v1/teacher/work-summary',
      institute: institute,
    );
    final subjects = (result['items'] as List).cast<Json>();
    offeringCount = subjects.length;
    truncated = result['truncated'] == true;
    return [
      for (final subject in subjects)
        ...subjectNotices(
          SubjectWork(Offering.fromJson(subject))
            ..joinRequests = subject['join_requests'] as int
            ..faceReviews = subject['face_reviews'] as int
            ..openQueries = subject['open_queries'] as int
            ..sessions = (subject['sessions'] as List).cast<Json>(),
        ),
    ];
  });
  if (isActiveAdmin(auth) && !c.failed.contains('subjects')) {
    await c.source('admin', () async {
      final teachers = await fetchAllPages(
        api,
        '/v1/admin/teachers',
        institute,
      );
      List<Json>? students;
      try {
        students = await fetchAllPages(api, '/v1/admin/students', institute);
      } catch (_) {
        c.failed.add('student directory');
      }
      return adminNotices(
        offerings: offeringCount,
        teachers: teachers,
        students: students,
      );
    });
  }
  return c.done(
    note: truncated ? 'Showing work for the first 100 subjects.' : null,
  );
}

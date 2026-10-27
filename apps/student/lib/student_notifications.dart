import 'package:flutter/material.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

const attendanceThreshold = 75;

/// Only the most recent publications are listed; older ones are in History.
const _recentPublications = 15;

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

String _statusWord(String status) => switch (status) {
  'present' => 'Present',
  'late' => 'Late',
  'absent' => 'Absent',
  'excused' => 'Excused',
  _ => 'Unassessed',
};

/// Notices for a student, built from their own enrolments, face enrolment,
/// published attendance and attendance queries.
Future<NoticeBatch> studentNotifications(
  ApiClient api,
  String institute,
  AuthController auth,
) async {
  final c = NoticeCollector();
  final titles = <String, String>{};

  await c.source('subjects', () async {
    final rows = <Enrollment>[];
    String? cursor;
    var pages = 0;
    do {
      final page = await api.enrollments(institute, cursor: cursor);
      rows.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null && ++pages < 5);
    for (final e in rows) {
      if (e.offering != null) titles[e.offeringId] = e.offering!.title;
    }
    return enrolmentNotices(rows);
  });

  await Future.wait([
    c.source('face enrolment', () async {
      final state = await api.send(
        'GET',
        '/v1/me/biometric-enrollment',
        institute: institute,
      );
      return faceNotices(state);
    }),
    c.source('attendance', () async {
      final rows = await fetchAllPages(api, '/v1/me/attendance', institute);
      return attendanceNotices(rows, titles);
    }),
    c.source('attendance queries', () async {
      final rows = await fetchAllPages(
        api,
        '/v1/me/attendance-disputes',
        institute,
      );
      return queryNotices(rows, titles);
    }),
  ]);
  return c.done();
}

Iterable<AppNotice> enrolmentNotices(List<Enrollment> rows) sync* {
  for (final e in rows) {
    final title = e.offering?.title ?? 'a subject';
    switch (e.status) {
      case 'requested':
        yield AppNotice(
          id: 'enrol:${e.id}:requested',
          title: 'Waiting for approval: $title',
          body: 'Your faculty must approve your request before attendance is recorded.',
          tone: NoticeTone.info,
          icon: Icons.hourglass_top,
          ongoing: true,
        );
      case 'active':
        yield AppNotice(
          id: 'enrol:${e.id}:active',
          title: 'Enrolled in $title',
          body: 'Your request was approved. Attendance for this subject now appears in History.',
          tone: NoticeTone.success,
          icon: Icons.check_circle_outline,
          route: '/classes/${e.offeringId}',
        );
      case 'rejected':
        yield AppNotice(
          id: 'enrol:${e.id}:rejected',
          title: 'Request declined: $title',
          body: e.reason == null || e.reason!.isEmpty
              ? 'Contact your faculty if you think this is a mistake.'
              : 'Faculty note: ${e.reason}',
          tone: NoticeTone.warning,
          icon: Icons.block,
        );
    }
  }
}

Iterable<AppNotice> faceNotices(Json state) sync* {
  final active = (state['active_sets'] as List?) ?? const [];
  final attempt = state['attempt'] as Map?;
  final status = attempt?['status'] as String?;
  // An unfinished or failed new attempt is more relevant than an older
  // active template; otherwise an active template means all is well.
  if (status == 'review_required') {
    yield AppNotice(
      id: 'face:${attempt!['id']}:review',
      title: 'Face enrolment is waiting for review',
      body: 'Your faculty will check the recording. Nothing else is needed from you.',
      tone: NoticeTone.info,
      icon: Icons.manage_search,
      route: '/enrolment',
      ongoing: true,
    );
  } else if (const {
    'awaiting_upload',
    'queued',
    'processing',
  }.contains(status)) {
    yield AppNotice(
      id: 'face:${attempt!['id']}:processing',
      title: 'Face enrolment in progress',
      body: status == 'awaiting_upload'
          ? 'Finish uploading your recording on the Enrolment page.'
          : 'Your recording is being checked. This usually takes a few minutes.',
      tone: status == 'awaiting_upload' ? NoticeTone.action : NoticeTone.info,
      icon: Icons.cloud_upload_outlined,
      route: '/enrolment',
      ongoing: true,
    );
  } else if (active.isNotEmpty) {
    final set = Map<String, dynamic>.from(active.first as Map);
    yield AppNotice(
      id: 'face:active:${set['id']}',
      title: 'Face enrolment is active',
      body: 'You can now be suggested as present in recorded classes.',
      tone: NoticeTone.success,
      icon: Icons.verified_outlined,
      route: '/enrolment',
      time: _time(set['activated_at']),
    );
  } else if (const {
    'rejected',
    'failed',
    'expired',
    'cancelled',
  }.contains(status)) {
    yield AppNotice(
      id: 'face:${attempt!['id']}:$status',
      title: status == 'rejected'
          ? 'Face enrolment needs a new recording'
          : 'Face enrolment did not complete',
      body:
          attempt['reason'] is String &&
              (attempt['reason'] as String).isNotEmpty
          ? 'Reason: ${attempt['reason']}. Record again on the Enrolment page.'
          : 'Record again on the Enrolment page.',
      tone: NoticeTone.action,
      icon: Icons.replay,
      route: '/enrolment',
      ongoing: true,
    );
  } else {
    yield const AppNotice(
      id: 'face:none',
      title: 'Set up face enrolment',
      body: 'With your consent, a short guided recording lets recorded classes suggest you as present.',
      tone: NoticeTone.action,
      icon: Icons.face_outlined,
      route: '/enrolment',
      ongoing: true,
    );
  }
}

Iterable<AppNotice> attendanceNotices(
  List<Json> rows,
  Map<String, String> titles,
) sync* {
  final sorted = [...rows]
    ..sort(
      (a, b) => (_time(b['published_at']) ?? DateTime(0)).compareTo(
        _time(a['published_at']) ?? DateTime(0),
      ),
    );
  for (final r in sorted.take(_recentPublications)) {
    final status = r['status'] as String;
    final subject = titles[r['offering_id']] ?? 'Subject';
    final starts = _time(r['starts_at'])?.toLocal();
    final date = starts == null
        ? ''
        : ' · ${starts.day.toString().padLeft(2, '0')}/${starts.month.toString().padLeft(2, '0')}';
    yield AppNotice(
      id: 'pub:${r['id']}',
      title: 'Attendance published: $subject$date',
      body:
          'You were marked ${_statusWord(status)}.'
          '${status == 'absent' ? ' You can raise a query from History if this is wrong.' : ''}',
      tone: status == 'absent' ? NoticeTone.warning : NoticeTone.success,
      icon: status == 'absent'
          ? Icons.event_busy_outlined
          : Icons.event_available_outlined,
      route: '/classes/${r['offering_id']}',
      time: _time(r['published_at']),
    );
  }
  // Per-subject percentage, with the same rule as History: unassessed and
  // excused results never count.
  final attended = <String, int>{}, assessed = <String, int>{};
  for (final r in rows) {
    final o = r['offering_id'] as String, s = r['status'];
    if (s == 'present' || s == 'late' || s == 'absent') {
      assessed[o] = (assessed[o] ?? 0) + 1;
      if (s != 'absent') attended[o] = (attended[o] ?? 0) + 1;
    }
  }
  for (final o in assessed.keys) {
    final pct = (attended[o] ?? 0) * 100 / assessed[o]!;
    if (pct < attendanceThreshold) {
      yield AppNotice(
        id: 'low:$o:${pct.round()}',
        title: 'Below $attendanceThreshold% in ${titles[o] ?? 'a subject'}',
        body:
            'Your attendance is ${pct.toStringAsFixed(1)}% (${attended[o] ?? 0} of ${assessed[o]} assessed classes).',
        tone: NoticeTone.warning,
        icon: Icons.trending_down,
        route: '/classes/$o',
        ongoing: true,
      );
    }
  }
}

Iterable<AppNotice> queryNotices(
  List<Json> rows,
  Map<String, String> titles,
) sync* {
  for (final d in rows) {
    final status = d['status'];
    if (status != 'accepted' && status != 'rejected') continue;
    final subject = titles[d['offering_id']] ?? 'a subject';
    final reason = d['resolution_reason'];
    yield AppNotice(
      id: 'query:${d['id']}:$status',
      title: status == 'accepted'
          ? 'Query accepted: $subject'
          : 'Query declined: $subject',
      body: [
        status == 'accepted'
            ? 'Your faculty corrected the attendance.'
            : 'Your faculty reviewed the query and kept the result.',
        if (reason is String && reason.isNotEmpty) 'Response: $reason',
      ].join(' '),
      tone: status == 'accepted' ? NoticeTone.success : NoticeTone.info,
      icon: Icons.chat_bubble_outline,
      route: '/classes/${d['offering_id']}',
      time: _time(d['resolved_at']),
    );
  }
}

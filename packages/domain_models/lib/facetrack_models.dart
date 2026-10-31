typedef Json = Map<String, dynamic>;

/// 1 -> "1st", 2 -> "2nd", 3 -> "3rd", 11 -> "11th".
String ordinal(int n) {
  final tens = n % 100;
  if (tens >= 11 && tens <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

String semesterLabel(int semester) => '${ordinal(semester)} Semester';

/// "2026-ODD" -> "Odd Semester 2026"; any other code is shown unchanged.
String termLabel(String code) {
  final m = RegExp(r'^(\d{4})-(ODD|EVEN)$', caseSensitive: false).firstMatch(code);
  if (m == null) return code;
  final kind = m.group(2)!.toLowerCase();
  return '${kind[0].toUpperCase()}${kind.substring(1)} Semester ${m.group(1)}';
}

class Member {
  Member.fromJson(Json j)
    : instituteId = j['institute_id'] as String,
      instituteName = j['institute_name'] as String,
      role = j['role'] as String,
      status = j['status'] as String;
  final String instituteId, instituteName, role, status;
}

class Person {
  Person.fromJson(Json j)
    : id = j['id'] as String,
      instituteId = j['institute_id'] as String,
      name = j['official_name'] as String,
      number = (j['enrollment_number'] ?? j['employee_number']) as String,
      status = j['status'] as String;
  final String id, instituteId, name, number, status;
}

class Account {
  Account.fromJson(Json j)
    : userId = j['user_id'] as String,
      members = (j['memberships'] as List)
          .map((x) => Member.fromJson(Map<String, dynamic>.from(x)))
          .toList(),
      students = (j['students'] as List)
          .map((x) => Person.fromJson(Map<String, dynamic>.from(x)))
          .toList(),
      teachers = (j['teachers'] as List)
          .map((x) => Person.fromJson(Map<String, dynamic>.from(x)))
          .toList();
  final String userId;
  final List<Member> members;
  final List<Person> students, teachers;
  List<Member> eligible(String role) => members
      .where(
        (m) =>
            m.role == role &&
            m.status == 'active' &&
            (role == 'student' ? students : teachers).any(
              (p) => p.instituteId == m.instituteId && p.status == 'approved',
            ),
      )
      .toList();
  bool get canClaim =>
      !members.any((m) => m.role == 'student') &&
      students.isEmpty &&
      teachers.isEmpty;
}

class Offering {
  Offering.fromJson(Json j)
    : id = j['id'] as String,
      title = j['title'] as String,
      courseCode = j['course_code'] as String,
      termCode = j['term_code'] as String,
      branch = j['branch'] as String,
      semester = j['semester'] as int,
      section = j['section'] as String,
      version = j['version'] as int,
      status = j['status'] as String;
  final String id, title, courseCode, termCode, branch, section, status;
  final int semester, version;
  String get subtitle =>
      '$courseCode · $branch · ${semesterLabel(semester)} · Section $section';
  String get termTitle => termLabel(termCode);
}

class Enrollment {
  Enrollment.fromJson(Json j)
    : id = j['id'] as String,
      offeringId = j['offering_id'] as String,
      studentId = j['student_id'] as String,
      status = j['status'] as String,
      version = j['version'] as int,
      offering = j['offering'] == null
          ? null
          : Offering.fromJson(Map<String, dynamic>.from(j['offering'])),
      name = j['official_name'] as String?,
      number = j['enrollment_number'] as String?,
      reason = j['reason'] as String?;
  final String id, offeringId, studentId, status;
  final int version;
  final Offering? offering;
  final String? name, number, reason;
}

class JoinCode {
  JoinCode.fromJson(Json j)
    : code = j['code'] as String,
      expires = DateTime.parse(j['expires_at'] as String);
  final String code;
  final DateTime expires;
}

/// A subject, semester term or section from the institute's academic setup.
class Academic {
  Academic.fromJson(Json j)
    : id = j['id'] as String,
      termId = j['term_id'] as String?,
      code = j['code'] as String?,
      title = j['title'] as String?,
      branch = j['branch'] as String?,
      section = j['section'] as String?,
      semester = (j['semester'] as num?)?.toInt();
  final String id;
  final String? termId, code, title, branch, section;
  final int? semester;

  /// "BCS 201 · Design & Analysis of Algorithm", "Odd Semester 2026 (2026-ODD)"
  /// or "CSE · 3rd Semester · Section CSE1".
  String get label {
    if (semester != null) {
      return '$branch · ${semesterLabel(semester!)} · Section $section';
    }
    if (title != null) return code == null ? title! : '$code · $title';
    final c = code ?? '';
    final pretty = termLabel(c);
    return pretty == c ? c : '$pretty ($c)';
  }
}

class PageData<T> {
  PageData(this.items, this.nextCursor);
  factory PageData.fromJson(Json j, T Function(Json) parse) => PageData(
    (j['items'] as List)
        .map((x) => parse(Map<String, dynamic>.from(x)))
        .toList(),
    j['next_cursor'] as String?,
  );
  final List<T> items;
  final String? nextCursor;
}

String statusLabel(String status) => switch (status) {
  'requested' => 'Awaiting approval',
  'active' => 'Approved',
  'rejected' => 'Declined',
  'withdrawn' => 'Withdrawn',
  _ => 'Unavailable',
};

/// The three final attendance states shown everywhere.
const finalStatuses = ['present', 'absent', 'unassessed'];

/// Folds any stored attendance status into one of [finalStatuses]. Older
/// publications may hold `late` (shown as Present) or `excused` (shown as
/// Unassessed, which never counts towards the percentage either way).
String finalStatus(String? status) => switch (status) {
  'present' || 'late' => 'present',
  'absent' => 'absent',
  _ => 'unassessed',
};

String attendanceLabel(String? status) => switch (finalStatus(status)) {
  'present' => 'Present',
  'absent' => 'Absent',
  _ => 'Unassessed',
};

/// Unassessed count of an attendance-summary row, including legacy excused.
num unassessedCount(Map s) =>
    ((s['unassessed'] as num?) ?? 0) + ((s['excused'] as num?) ?? 0);

class BiometricAttempt {
  BiometricAttempt.fromJson(Json j)
    : id = j['id'],
      assetId = j['asset_id'],
      status = j['status'],
      version = j['version'],
      poses = List<String>.from(j['pose_order']),
      quality = Map<String, dynamic>.from(j['quality_json'] ?? {}),
      reason = j['reason'],
      name = j['official_name'],
      number = j['enrollment_number'],
      expiresAt = DateTime.parse(j['expires_at']);
  final String id, assetId, status;
  final int version;
  final List<String> poses;
  final Json quality;
  final String? reason, name, number;
  final DateTime expiresAt;
  bool get unfinished => [
    'awaiting_upload',
    'queued',
    'processing',
    'review_required',
  ].contains(status);
}

class BiometricState {
  BiometricState.fromJson(Json j)
    : attempt = j['attempt'] == null
          ? null
          : BiometricAttempt.fromJson(Map<String, dynamic>.from(j['attempt'])),
      consentId = j['consent']?['id'],
      active = (j['active_sets'] as List).isNotEmpty;
  final BiometricAttempt? attempt;
  final String? consentId;
  final bool active;
}

String biometricStatus(String status) => switch (status) {
  'awaiting_upload' => 'Waiting for your video',
  'queued' => 'Waiting for processing',
  'processing' => 'Processing your video',
  'review_required' => 'Waiting for faculty review',
  'active' => 'Face enrolment active',
  'failed' => 'Recording needs attention',
  'rejected' => 'Faculty requested a new recording',
  'cancelled' => 'Enrolment cancelled',
  'expired' => 'Recording expired',
  _ => 'Not enrolled',
};

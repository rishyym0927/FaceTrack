import 'dart:convert';

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Uses unrounded counts so 74.95% is not mistaken for 75%.
bool belowAttendanceThreshold(Json student) {
  final attended = (student['attended'] as num?)?.toInt() ?? 0;
  final assessed =
      (student['assessed'] as num?)?.toInt() ??
      attended + ((student['absent'] as num?)?.toInt() ?? 0);
  return assessed > 0 && attended * 4 < assessed * 3;
}

/// Attendance below this percentage (of assessed classes) needs attention.
const attendanceThreshold = 75;

const _lightGreen = Color(0xff3f9e6b);

/// Colour of an attendance percentage that agrees with
/// [belowAttendanceThreshold] on the 75% boundary: a student on 74.96% is
/// shown in the warning colour even though the label rounds to 75.0%.
Color attendanceTone(Json student) {
  final attended = (student['attended'] as num?)?.toInt() ?? 0;
  final assessed =
      (student['assessed'] as num?)?.toInt() ??
      attended + ((student['absent'] as num?)?.toInt() ?? 0);
  if (assessed <= 0) return AppTone.neutral;
  if (!belowAttendanceThreshold(student)) return AppTone.success;
  return attended * 2 < assessed ? AppTone.danger : AppTone.warning;
}

/// One subject's published-attendance summary, or the reason it could not load.
class SubjectStats {
  SubjectStats(this.offering, {this.summary, this.error});
  final Offering offering;
  final Json? summary;
  final AppFailure? error;

  List<Json> get students =>
      (summary?['students'] as List?)?.cast<Json>() ?? const [];
  int get conducted => (summary?['sessions_conducted'] as num?)?.toInt() ?? 0;
  int _sum(String key) =>
      students.fold(0, (t, s) => t + ((s[key] as num?)?.toInt() ?? 0));
  int get attended => _sum('attended');
  int get absent => _sum('absent');

  /// Attended over assessed (attended + absent). Unassessed and excused
  /// classes are never counted as absence.
  double? get percentage {
    final assessed = attended + absent;
    return assessed == 0 ? null : 100 * attended / assessed;
  }

  int get below => students.where(_isBelow).length;
  static bool _isBelow(Json s) => belowAttendanceThreshold(s);
}

/// One subject's attendance summary; a failure is kept on the subject so the
/// rest of a dashboard still loads.
Future<SubjectStats> fetchSubjectStats(
  ApiClient api,
  String institute,
  Offering o,
) async {
  try {
    final data = await api.send(
      'GET',
      '/v1/offerings/${o.id}/attendance-summary',
      institute: institute,
    );
    return SubjectStats(o, summary: data);
  } catch (e) {
    return SubjectStats(
      o,
      error: e is AppFailure
          ? e
          : const AppFailure('Could not load this subject.'),
    );
  }
}

/// A student's record in one subject, for the attention list and exports.
class StudentRecord {
  StudentRecord(this.subject, this.data);
  final SubjectStats subject;
  final Json data;
  String get id => '${data['student_id']}';
  String get name => '${data['official_name']}';
  String get number => '${data['enrollment_number']}';
  num? get percentage => data['percentage'] as num?;
  int get attended => (data['attended'] as num?)?.toInt() ?? 0;
  int get assessed =>
      (data['assessed'] as num?)?.toInt() ??
      attended + ((data['absent'] as num?)?.toInt() ?? 0);
  double? get exactPercentage =>
      assessed == 0 ? null : 100 * attended / assessed;

  bool get belowThreshold => belowAttendanceThreshold(data);
}

/// Cross-subject totals for whatever subjects are currently in view.
class DashboardTotals {
  DashboardTotals(List<SubjectStats> subjects) {
    final atRisk = <String>{}, everyone = <String>{};
    for (final s in subjects) {
      if (s.error != null) continue;
      loaded++;
      classes += s.conducted;
      attended += s.attended;
      assessed += s.attended + s.absent;
      var subjectHasRisk = false;
      for (final d in s.students) {
        final r = StudentRecord(s, d);
        everyone.add(r.id);
        final p = r.exactPercentage;
        if (p == null) continue;
        percentages.add(p);
        if (r.belowThreshold) {
          atRisk.add(r.id);
          lowest.add(r);
          subjectHasRisk = true;
        }
      }
      if (subjectHasRisk) subjectsWithRisk++;
    }
    students = everyone.length;
    atRiskStudents = atRisk.length;
    lowest.sort((a, b) => a.exactPercentage!.compareTo(b.exactPercentage!));
  }
  int loaded = 0, classes = 0, attended = 0, assessed = 0;
  int students = 0, atRiskStudents = 0, subjectsWithRisk = 0;
  final List<num> percentages = [];
  final List<StudentRecord> lowest = [];

  /// Weighted across every assessed class, not an average of averages.
  double? get overall => assessed == 0 ? null : 100 * attended / assessed;
  int bucket(num lo, num hi) =>
      percentages.where((p) => p >= lo && p < hi).length;
}

class MonthlyAttendance {
  const MonthlyAttendance(this.month, this.attended, this.assessed);
  final String month;
  final int attended, assessed;
  double? get percentage => assessed == 0 ? null : 100 * attended / assessed;
}

/// Valid monthly buckets of one subject summary, oldest first.
List<MonthlyAttendance> _monthsOf(SubjectStats subject) {
  final byMonth = <String, MonthlyAttendance>{};
  for (final raw in (subject.summary?['monthly'] as List?) ?? const []) {
    if (raw is! Map) continue;
    final month = raw['month'];
    if (month is! String || !RegExp(r'^\d{4}-\d{2}$').hasMatch(month)) continue;
    final attended = (raw['attended'] as num?)?.toInt() ?? 0;
    final assessed = (raw['assessed'] as num?)?.toInt() ?? 0;
    if (attended < 0 || assessed < attended) continue;
    final old = byMonth[month];
    byMonth[month] = MonthlyAttendance(
      month,
      attended + (old?.attended ?? 0),
      assessed + (old?.assessed ?? 0),
    );
  }
  return byMonth.values.toList()..sort((a, b) => a.month.compareTo(b.month));
}

/// Merge subject months by assessed marks, never average percentages.
List<MonthlyAttendance> attendanceTrend(List<SubjectStats> subjects) {
  final totals = <String, (int, int)>{};
  for (final subject in subjects) {
    if (subject.error != null) continue;
    for (final m in _monthsOf(subject)) {
      final old = totals[m.month] ?? (0, 0);
      totals[m.month] = (old.$1 + m.attended, old.$2 + m.assessed);
    }
  }
  final months = totals.keys.toList()..sort();
  return [
    for (final month in months)
      MonthlyAttendance(month, totals[month]!.$1, totals[month]!.$2),
  ];
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "2026-11" -> "Nov 2026"; anything unexpected is shown unchanged.
String monthLabel(String yearMonth) {
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(yearMonth);
  if (m == null) return yearMonth;
  final index = int.parse(m.group(2)!);
  if (index < 1 || index > 12) return yearMonth;
  return '${_monthNames[index - 1]} ${m.group(1)}';
}

/// How a subject moved between its last two months with assessed marks.
/// [delta] is in percentage points and null with only one month of data.
class SubjectTrend {
  const SubjectTrend({required this.month, this.previousMonth, this.delta});
  final String month;
  final String? previousMonth;
  final double? delta;
}

/// The latest published month of a subject and, with two or more months of
/// assessed marks, the change against the month before. Null when the
/// subject has no monthly data (nothing is invented).
SubjectTrend? subjectTrend(SubjectStats subject) {
  if (subject.error != null) return null;
  final months = _monthsOf(subject).where((m) => m.assessed > 0).toList();
  if (months.isEmpty) return null;
  final last = months.last;
  if (months.length < 2) return SubjectTrend(month: last.month);
  final prev = months[months.length - 2];
  return SubjectTrend(
    month: last.month,
    previousMonth: prev.month,
    delta: last.percentage! - prev.percentage!,
  );
}

/// A semester group: subjects of the same semester (and term).
class SemesterGroup {
  SemesterGroup(this.key, this.label, this.subjects);
  final String key, label;
  final List<SubjectStats> subjects;
}

/// The semester/term group a subject belongs to (see [groupBySemester]).
String subjectGroupKey(SubjectStats s) =>
    '${s.offering.termCode}|${s.offering.semester}';

List<SemesterGroup> groupBySemester(List<SubjectStats> all) {
  final terms = {for (final s in all) s.offering.termCode};
  final map = <String, List<SubjectStats>>{};
  for (final s in all) {
    map.putIfAbsent(subjectGroupKey(s), () => []).add(s);
  }
  final keys = map.keys.toList()
    ..sort((a, b) {
      final x = map[a]!.first.offering, y = map[b]!.first.offering;
      final t = y.termCode.compareTo(x.termCode);
      return t != 0 ? t : x.semester.compareTo(y.semester);
    });
  return [
    for (final k in keys)
      SemesterGroup(
        k,
        terms.length > 1
            ? '${semesterLabel(map[k]!.first.offering.semester)} · ${map[k]!.first.offering.termTitle}'
            : semesterLabel(map[k]!.first.offering.semester),
        map[k]!,
      ),
  ];
}

/// How the per-subject list is ordered. Subjects with no assessed marks yet
/// always come last for the percentage orders.
enum SubjectSort { lowest, highest, name }

/// Whether a subject belongs under the "Below 75% only" filter: its own
/// aggregate is under the threshold (or it could not be loaded).
bool subjectNeedsAttention(SubjectStats s) =>
    s.error != null || (s.attended * 4 < (s.attended + s.absent) * 3);

/// Narrows already-loaded subjects by semester group, a free-text query over
/// title, code, branch and section, and the below-threshold toggle. Pure, so
/// it can be tested without a widget.
List<SubjectStats> filterSubjects(
  List<SubjectStats> all, {
  String? group,
  String query = '',
  bool belowOnly = false,
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  return all.where((s) {
    if (group != null && subjectGroupKey(s) != group) return false;
    if (belowOnly && !subjectNeedsAttention(s)) return false;
    if (words.isEmpty) return true;
    final o = s.offering;
    final haystack = '${o.title} ${o.courseCode} ${o.branch} ${o.section}'
        .toLowerCase();
    return words.every(haystack.contains);
  }).toList();
}

/// Returns a sorted copy; the input list is not modified.
List<SubjectStats> sortSubjects(List<SubjectStats> list, SubjectSort sort) {
  int byTitle(SubjectStats a, SubjectStats b) =>
      a.offering.title.toLowerCase().compareTo(b.offering.title.toLowerCase());
  final l = [...list];
  l.sort((a, b) {
    if (sort == SubjectSort.name) return byTitle(a, b);
    final x = a.percentage, y = b.percentage;
    if (x == null && y == null) return byTitle(a, b);
    if (x == null) return 1;
    if (y == null) return -1;
    final c = sort == SubjectSort.lowest ? x.compareTo(y) : y.compareTo(x);
    return c != 0 ? c : byTitle(a, b);
  });
  return l;
}

/// A single figure: label, a large value that scales down rather than
/// overflowing, and an optional caption. Used by the dashboard and the
/// per-subject overview so both read the same way.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.tone,
    this.caption,
  });
  final String label, value;
  final IconData? icon;
  final Color? tone;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tone ?? scheme.primary;
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: scheme.outline),
        ),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null && box.maxWidth >= 150) ...[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppTone.tint(color),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(icon, size: 16, color: color),
                    ),
                    const SizedBox(width: AppSpace.sm),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.6,
                    color: color,
                  ),
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 2),
                Text(
                  caption!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Tile grid that keeps two tiles per row on a phone and drops to one column
/// when text is enlarged so labels stay readable.
class MetricGrid extends StatelessWidget {
  const MetricGrid({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return StatGrid(minTileWidth: 120 * scale, children: children);
  }
}

/// A [TrackBar] with a small tick at the 75% threshold.
class ThresholdBar extends StatelessWidget {
  const ThresholdBar({
    super.key,
    required this.value,
    required this.color,
    this.height = 8,
  });
  final double? value;
  final Color color;
  final double height;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Stack(
      clipBehavior: Clip.none,
      children: [
        TrackBar(value: (value ?? 0) / 100, color: color, height: height),
        Positioned(
          left: box.maxWidth * attendanceThreshold / 100 - 1,
          top: -2,
          bottom: -2,
          width: 2,
          child: ExcludeSemantics(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .45),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Dedicated faculty analytics destination. Data is fetched only when opened.
class TeacherAttendancePage extends ConsumerStatefulWidget {
  const TeacherAttendancePage({super.key});

  @override
  ConsumerState<TeacherAttendancePage> createState() =>
      _TeacherAttendancePageState();
}

class _TeacherAttendancePageState extends ConsumerState<TeacherAttendancePage>
    with ResumeRefresh<TeacherAttendancePage> {
  int refreshTick = 0;

  @override
  void initState() {
    super.initState();
    watchLifecycle();
  }

  @override
  void dispose() {
    unwatchLifecycle();
    super.dispose();
  }

  @override
  void refreshOnResume() => setState(() => refreshTick++);

  @override
  Widget build(BuildContext context) {
    final api = ref.read(servicesProvider).api;
    final institute = ref.watch(authProvider).institute;
    if (institute == null) return const SizedBox.shrink();
    return ContentPage(
      onRefresh: () async => setState(() => refreshTick++),
      children: [
        const PageHeader(
          title: 'Attendance',
          subtitle:
              'Published results across your subjects, with the students who need attention.',
        ),
        TeacherDashboard(
          api: api,
          institute: institute,
          refreshTick: refreshTick,
        ),
      ],
    );
  }
}

/// The faculty's attendance dashboard: a summary, the students who need
/// attention, a filterable subject list, then distribution and trend. It is
/// based on the published attendance summaries returned by the faculty API.
class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({
    super.key,
    required this.api,
    required this.institute,
    this.refreshTick = 0,
  });
  final ApiClient api;
  final String institute;
  final int refreshTick;
  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

class _TeacherDashboardState extends State<TeacherDashboard> {
  static const _maxPages = 10;
  static const _attentionPreview = 5, _attentionCap = 60;
  final _search = TextEditingController();
  List<SubjectStats> _subjects = [];
  AppFailure? _error;
  bool _loading = true;
  bool _hasMore = false;
  String? _group; // null = all semesters
  SubjectSort _sort = SubjectSort.lowest;
  bool _attentionOnly = false;
  bool _showAllAttention = false;
  int _trendPage = 0;
  String? _selectedMonth;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TeacherDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.institute != widget.institute ||
        oldWidget.api != widget.api) {
      _subjects = [];
      _group = null;
      _hasMore = false;
      _load();
    } else if (oldWidget.refreshTick != widget.refreshTick) {
      ApiClient.freshReads(_load);
    }
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    final results = <SubjectStats>[];
    try {
      String? cursor;
      var pages = 0;
      do {
        final page = await widget.api.send(
          'GET',
          '/v1/teacher/attendance-dashboard',
          institute: widget.institute,
          query: {'cursor': ?cursor},
        );
        if (!mounted || generation != _generation) return;
        for (final item in (page['items'] as List).cast<Json>()) {
          results.add(
            SubjectStats(
              Offering.fromJson(item['offering'] as Json),
              summary: item['summary'] as Json,
            ),
          );
        }
        cursor = page['next_cursor'] as String?;
      } while (cursor != null && ++pages < _maxPages);
      setState(() {
        _subjects = results;
        _hasMore = cursor != null;
        if (_group != null &&
            !_subjects.any((s) => subjectGroupKey(s) == _group)) {
          _group = null;
        }
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          if (e is AppFailure && const {401, 403, 404}.contains(e.status)) {
            _subjects = [];
            _group = null;
            _hasMore = false;
          } else if (_subjects.isEmpty && results.isNotEmpty) {
            _subjects = results;
            _hasMore = true;
          }
          _error = e is AppFailure
              ? e
              : const AppFailure('Could not load the dashboard. Retry.');
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  /// Subjects in the chosen semester group (the scope of every figure).
  List<SubjectStats> get _visible => filterSubjects(_subjects, group: _group);

  Future<void> _export() async {
    String esc(Object? v) {
      final s = '${v ?? ''}';
      return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final lines = <String>[
      'Semester,Branch,Section,Subject code,Subject,Enrolment,Name,Classes conducted,Present,Absent,Percentage',
    ];
    for (final s in sortSubjects(_visible, _sort)) {
      if (s.error != null) continue;
      final o = s.offering;
      for (final d in s.students) {
        lines.add(
          [
            esc(semesterLabel(o.semester)),
            esc(o.branch),
            esc(o.section),
            esc(o.courseCode),
            esc(o.title),
            esc(d['enrollment_number']),
            esc(d['official_name']),
            esc(d['conducted']),
            esc(d['attended']),
            esc(d['absent']),
            esc(d['percentage']),
          ].join(','),
        );
      }
    }
    final label = _group == null
        ? 'all-semesters'
        : _groups
              .firstWhere((g) => g.key == _group)
              .label
              .toLowerCase()
              .replaceAll(RegExp('[^a-z0-9]+'), '-');
    await FilePicker.saveFile(
      fileName: 'attendance-$label.csv',
      bytes: utf8.encode('${lines.join('\n')}\n'),
      mimeType: 'text/csv',
      dialogTitle: 'Save semester attendance report',
    );
  }

  List<SemesterGroup> get _groups => groupBySemester(_subjects);

  bool get _filtersActive => _attentionOnly || _search.text.trim().isNotEmpty;

  void _clearFilters() => setState(() {
    _attentionOnly = false;
    _search.clear();
  });

  @override
  Widget build(BuildContext context) {
    if (_loading && _subjects.isEmpty) {
      return Semantics(
        label: 'Loading your attendance overview',
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SkeletonStatGrid(count: 4),
            SizedBox(height: AppSpace.lg),
            SkeletonPanel(rows: 3),
          ],
        ),
      );
    }
    if (_error != null && _subjects.isEmpty) {
      return ErrorView(_error!, retry: _load);
    }
    if (_subjects.isEmpty) {
      return EmptyState(
        icon: Icons.insights_outlined,
        title: 'No published attendance yet',
        message: 'Publish attendance in a subject to see its overview here.',
        action: FilledButton.icon(
          onPressed: () => context.go('/classes'),
          icon: const Icon(Icons.menu_book_outlined),
          label: const Text('Go to subjects'),
        ),
      );
    }

    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final pad = compact ? 16.0 : 24.0;
    final visible = _visible;
    final totals = DashboardTotals(visible);
    final groups = _groups;
    final failed = visible.where((s) => s.error != null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _overviewPanel(theme, pad, visible, totals, groups, failed),
        const SizedBox(height: AppSpace.lg),
        _attentionPanel(theme, pad),
        const SizedBox(height: AppSpace.lg),
        _subjectsPanel(theme, pad, visible),
        const SizedBox(height: AppSpace.lg),
        Panel(
          padding: pad,
          child: LayoutBuilder(
            builder: (context, c) {
              final distribution = _distribution(totals);
              final trend = _trend(visible);
              if (c.maxWidth >= 820) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: distribution),
                    const SizedBox(width: AppSpace.xxl),
                    Expanded(child: trend),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  distribution,
                  const SizedBox(height: AppSpace.xl),
                  trend,
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // --- Summary --------------------------------------------------------------

  Widget _overviewPanel(
    ThemeData theme,
    double pad,
    List<SubjectStats> visible,
    DashboardTotals totals,
    List<SemesterGroup> groups,
    int failed,
  ) {
    final terms = {for (final s in visible) s.offering.termCode}.length;
    final tiles = MetricGrid(
      children: [
        MetricTile(
          label: 'Overall attendance',
          value: totals.overall == null
              ? '—'
              : '${totals.overall!.toStringAsFixed(1)}%',
          tone: percentColor(totals.overall),
          icon: Icons.insights_outlined,
          caption: totals.overall == null
              ? 'Nothing published yet'
              : 'across assessed classes',
        ),
        MetricTile(
          label: 'Subjects',
          value: '${totals.loaded}',
          icon: Icons.menu_book_outlined,
          caption: '${totals.students} students',
        ),
        MetricTile(
          label: 'Students below $attendanceThreshold%',
          value: '${totals.atRiskStudents}',
          tone: totals.atRiskStudents == 0 ? AppTone.success : AppTone.danger,
          icon: Icons.warning_amber_outlined,
          caption: totals.atRiskStudents == 0
              ? 'All on track'
              : 'in ${totals.subjectsWithRisk} subject${totals.subjectsWithRisk == 1 ? '' : 's'}',
        ),
        MetricTile(
          label: 'Sessions held',
          value: '${totals.classes}',
          icon: Icons.event_available_outlined,
          caption: terms <= 1 ? 'this term' : 'across $terms terms',
        ),
      ],
    );
    return Panel(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Overview', style: theme.textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Refresh overview',
                onPressed: _loading ? null : () => ApiClient.freshReads(_load),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: AppSpace.sm),
            const LinearProgressIndicator(semanticsLabel: 'Refreshing attendance'),
          ],
          Text(
            'Across '
            '${visible.length} subject${visible.length == 1 ? '' : 's'}'
            '${_group == null ? '' : ' · ${groups.firstWhere((g) => g.key == _group).label}'}.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.md),
            _Notice(
              '${_error!.message} Showing the last loaded figures.',
              onRetry: _load,
            ),
          ],
          if (_hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Totals cover only the subjects loaded.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (groups.length > 1) ...[
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                ChoiceChip(
                  label: const Text('All semesters'),
                  selected: _group == null,
                  onSelected: (_) => setState(() => _group = null),
                ),
                for (final g in groups)
                  ChoiceChip(
                    label: Text(g.label),
                    selected: _group == g.key,
                    onSelected: (_) => setState(() => _group = g.key),
                  ),
              ],
            ),
          ],
          if (failed > 0) ...[
            const SizedBox(height: AppSpace.md),
            _Notice(
              '$failed subject${failed == 1 ? '' : 's'} could not be loaded and '
              '${failed == 1 ? 'is' : 'are'} left out of the totals.',
              onRetry: _load,
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth < 640) return tiles;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  PercentRing(
                    value: totals.overall,
                    caption: totals.overall == null ? 'No data yet' : 'overall',
                  ),
                  const SizedBox(width: AppSpace.xl),
                  Expanded(child: tiles),
                ],
              );
            },
          ),
          if (groups.length > 1 && _group == null) ...[
            const SizedBox(height: AppSpace.xl),
            Text('Semester-wise', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.sm),
            for (final g in groups) _semesterRow(g),
          ],
        ],
      ),
    );
  }

  Widget _semesterRow(SemesterGroup g) {
    final t = DashboardTotals(g.subjects);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => setState(() => _group = g.key),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    g.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Flexible(
                  child: Text(
                    '${t.overall == null ? '—' : '${t.overall!.toStringAsFixed(1)}%'} · '
                    '${g.subjects.length} subject${g.subjects.length == 1 ? '' : 's'}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TrackBar(
              value: (t.overall ?? 0) / 100,
              color: percentColor(t.overall),
              height: 12,
            ),
          ],
        ),
      ),
    );
  }

  // --- Students needing attention -------------------------------------------

  Widget _attentionPanel(ThemeData theme, double pad) {
    // Scoped by the semester chips and the subject search, so looking up one
    // subject also narrows who is listed.
    final scoped = DashboardTotals(
      filterSubjects(_subjects, group: _group, query: _search.text),
    );
    final records = scoped.lowest;
    final limit = _showAllAttention ? _attentionCap : _attentionPreview;
    final shown = records.take(limit).toList();
    final searching = _search.text.trim().isNotEmpty;
    return Panel(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Needs attention', style: theme.textTheme.titleMedium),
              if (records.isNotEmpty)
                TonePill(
                  '${scoped.atRiskStudents} student${scoped.atRiskStudents == 1 ? '' : 's'}',
                  tone: AppTone.danger,
                  icon: Icons.warning_amber_outlined,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            searching
                ? 'Students below $attendanceThreshold% in the subjects matching your search, lowest first'
                : 'Students below $attendanceThreshold% in a subject, lowest first',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.sm),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: AppTone.success,
                    size: 20,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  const Expanded(
                    child: Text('No student is below the threshold.'),
                  ),
                ],
              ),
            )
          else
            for (final r in shown) _attentionRow(theme, r),
          if (records.length > _attentionPreview)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showAllAttention = !_showAllAttention),
                icon: Icon(
                  _showAllAttention ? Icons.expand_less : Icons.expand_more,
                ),
                label: Text(
                  _showAllAttention
                      ? 'Show fewer'
                      : 'Show all ${records.length}',
                ),
              ),
            ),
          if (_showAllAttention && records.length > _attentionCap)
            Text(
              'Showing the lowest $_attentionCap of ${records.length}. Export the report for the full list.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _attentionRow(ThemeData theme, StudentRecord r) {
    final p = r.exactPercentage;
    final tone = attendanceTone(r.data);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => context.push('/classes/${r.subject.offering.id}?tab=overview'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${r.number} · ${r.subject.offering.courseCode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    'Attended ${r.attended} of ${r.assessed} assessed',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            TonePill(
              p == null ? '—' : '${p.toStringAsFixed(1)}%',
              tone: tone,
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  // --- Subjects: filter bar and list -----------------------------------------

  Widget _subjectsPanel(ThemeData theme, double pad, List<SubjectStats> visible) {
    final filtered = sortSubjects(
      filterSubjects(
        _subjects,
        group: _group,
        query: _search.text,
        belowOnly: _attentionOnly,
      ),
      _sort,
    );
    return Panel(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Subject-wise statistics', style: theme.textTheme.titleMedium),
              OutlinedButton.icon(
                onPressed: visible.every((s) => s.students.isEmpty)
                    ? null
                    : _export,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Export report'),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search subject, code or section',
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: Text('Below $attendanceThreshold% only'),
                selected: _attentionOnly,
                onSelected: (v) => setState(() => _attentionOnly = v),
              ),
              Text(
                'Sort',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final (value, label) in const [
                (SubjectSort.lowest, 'Lowest %'),
                (SubjectSort.highest, 'Highest %'),
                (SubjectSort.name, 'Name'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _sort == value,
                  onSelected: (_) => setState(() => _sort = value),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Showing ${filtered.length} of ${visible.length} subject${visible.length == 1 ? '' : 's'}',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_filtersActive)
                TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear filters'),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (filtered.isEmpty)
            const EmptyState(
              icon: Icons.search_off_outlined,
              title: 'No subjects match this filter.',
              message: 'Try a different search or clear the filters.',
              compact: true,
            )
          else
            for (final s in filtered) ...[
              _subjectCard(theme, s),
              const SizedBox(height: AppSpace.sm),
            ],
        ],
      ),
    );
  }

  Widget _subjectCard(ThemeData theme, SubjectStats s) {
    final o = s.offering;
    final p = s.percentage;
    final tone = percentColor(p);
    final trend = subjectTrend(s);
    final onVariant = theme.colorScheme.onSurfaceVariant;
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => context.push('/classes/${o.id}?tab=overview'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      o.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (s.error == null) ...[
                    const SizedBox(width: AppSpace.sm),
                    TonePill(
                      p == null ? 'No data' : '${p.toStringAsFixed(1)}%',
                      tone: tone,
                    ),
                  ],
                  Icon(Icons.chevron_right, size: 20, color: onVariant),
                ],
              ),
              Text(
                o.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: onVariant, fontSize: 13),
              ),
              const SizedBox(height: AppSpace.sm),
              if (s.error != null)
                Text(s.error!.message, style: const TextStyle(color: AppTone.danger))
              else ...[
                ThresholdBar(value: p, color: tone),
                const SizedBox(height: AppSpace.sm),
                Text(
                  '${s.students.length} students · ${s.conducted} sessions held',
                  style: TextStyle(color: onVariant, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (s.below > 0)
                      TonePill(
                        '${s.below} below $attendanceThreshold%',
                        tone: AppTone.danger,
                        icon: Icons.warning_amber_outlined,
                      )
                    else if (s.students.isNotEmpty && p != null)
                      const TonePill(
                        'All on track',
                        tone: AppTone.success,
                        icon: Icons.check_circle_outline,
                      ),
                    if (trend?.delta case final delta?)
                      TonePill(
                        delta.abs() < .05
                            ? 'Steady vs ${monthLabel(trend!.previousMonth!)}'
                            : '${delta > 0 ? '+' : '−'}${delta.abs().toStringAsFixed(1)} pts vs ${monthLabel(trend!.previousMonth!)}',
                        tone: delta.abs() < .05
                            ? AppTone.neutral
                            : delta > 0
                            ? AppTone.success
                            : AppTone.danger,
                        icon: delta.abs() < .05
                            ? Icons.trending_flat
                            : delta > 0
                            ? Icons.trending_up
                            : Icons.trending_down,
                      ),
                    if (trend != null)
                      Text(
                        'Last published ${monthLabel(trend.month)}',
                        style: TextStyle(color: onVariant, fontSize: 12),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --- Distribution and trend ------------------------------------------------

  Widget _trend(List<SubjectStats> subjects) {
    final months = attendanceTrend(subjects);
    final page = _trendPage.clamp(
      0,
      months.isEmpty ? 0 : (months.length - 1) ~/ 6,
    );
    final end = months.length - page * 6;
    final start = (end - 6).clamp(0, months.length);
    final visibleMonths = months.sublist(start, end);
    final selected = months.where((m) => m.month == _selectedMonth).firstOrNull;
    final onVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Attendance trend',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Published attendance by month · weighted by assessed marks',
          style: TextStyle(color: onVariant),
        ),
        const SizedBox(height: AppSpace.md),
        if (months.isEmpty)
          Text(
            'Monthly trend will appear after attendance is published.',
            style: TextStyle(color: onVariant),
          )
        else ...[
          for (final month in visibleMonths)
            InkWell(
              onTap: () => setState(() => _selectedMonth = month.month),
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            monthLabel(month.month),
                            style: TextStyle(
                              fontWeight: _selectedMonth == month.month
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        Text(
                          month.percentage == null
                              ? '—'
                              : '${month.percentage!.toStringAsFixed(1)}%',
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TrackBar(
                      value: (month.percentage ?? 0) / 100,
                      color: percentColor(month.percentage),
                      height: 12,
                    ),
                  ],
                ),
              ),
            ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${monthLabel(selected.month)}: ${selected.attended} attended out of ${selected.assessed} assessed marks',
                style: TextStyle(color: onVariant),
              ),
            ),
          if (months.length > 6)
            Wrap(
              spacing: AppSpace.sm,
              children: [
                TextButton.icon(
                  onPressed: end <= 6
                      ? null
                      : () => setState(() => _trendPage = page + 1),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Earlier'),
                ),
                TextButton.icon(
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _trendPage = page - 1),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Later'),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _distribution(DashboardTotals t) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Attendance distribution',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 4),
      Text(
        'Student records by percentage band',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: AppSpace.md),
      if (t.percentages.isEmpty)
        const Text('Publish attendance to see the distribution.')
      else
        BarDistribution(
          bars: [
            BarDatum('90–100%', t.bucket(90, 101), AppTone.success),
            BarDatum('75–89%', t.bucket(75, 90), _lightGreen),
            BarDatum('50–74%', t.bucket(50, 75), AppTone.warning),
            BarDatum('Below 50%', t.bucket(0, 50), AppTone.danger),
          ],
        ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, {required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.md),
    decoration: BoxDecoration(
      color: AppTone.tint(AppTone.warning, .08),
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppTone.tint(AppTone.warning, .35)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: AppTone.warning, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

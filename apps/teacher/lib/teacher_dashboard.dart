import 'dart:convert';
import 'dart:math' as math;

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Attendance below this percentage (of assessed classes) needs attention.
const attendanceThreshold = 75;

const _green = Color(0xff176451);
const _lightGreen = Color(0xff3f9e6b);
const _amber = Color(0xff9a6a00);
const _red = Color(0xffa22f2f);

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
  static bool _isBelow(Json s) =>
      s['percentage'] is num && (s['percentage'] as num) < attendanceThreshold;
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
      error: e is AppFailure ? e : const AppFailure('Could not load this subject.'),
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
      for (final d in s.students) {
        final r = StudentRecord(s, d);
        everyone.add(r.id);
        final p = r.percentage;
        if (p == null) continue;
        percentages.add(p);
        if (p < attendanceThreshold) {
          atRisk.add(r.id);
          lowest.add(r);
        }
      }
    }
    students = everyone.length;
    atRiskStudents = atRisk.length;
    lowest.sort((a, b) => a.percentage!.compareTo(b.percentage!));
  }
  int loaded = 0, classes = 0, attended = 0, assessed = 0;
  int students = 0, atRiskStudents = 0;
  final List<num> percentages = [];
  final List<StudentRecord> lowest = [];

  /// Weighted across every assessed class, not an average of averages.
  double? get overall => assessed == 0 ? null : 100 * attended / assessed;
  int bucket(num lo, num hi) =>
      percentages.where((p) => p >= lo && p < hi).length;
}

/// A semester group: subjects of the same semester (and term).
class SemesterGroup {
  SemesterGroup(this.key, this.label, this.subjects);
  final String key, label;
  final List<SubjectStats> subjects;
}

List<SemesterGroup> groupBySemester(List<SubjectStats> all) {
  final terms = {for (final s in all) s.offering.termCode};
  final map = <String, List<SubjectStats>>{};
  for (final s in all) {
    map.putIfAbsent('${s.offering.termCode}|${s.offering.semester}', () => []).add(s);
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

/// The faculty's attendance dashboard: overall figures, semester-wise and
/// subject-wise statistics, a distribution chart and an attention list. It is
/// computed on the client from each subject's published attendance summary, so
/// it only ever reflects faculty-published results.
class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({super.key, required this.api, required this.institute, this.refreshTick = 0});
  final ApiClient api;
  final String institute;
  final int refreshTick;
  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

enum _Sort { lowest, name, semester }

class _TeacherDashboardState extends State<TeacherDashboard> {
  static const _concurrency = 4, _maxPages = 10;
  List<SubjectStats> _subjects = [];
  AppFailure? _error;
  bool _loading = true;
  int _done = 0, _total = 0;
  String? _group; // null = all semesters
  _Sort _sort = _Sort.lowest;
  bool _attentionOnly = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TeacherDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) ApiClient.freshReads(_load);
  }
  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _done = 0;
      _total = 0;
    });
    try {
      final offerings = <Offering>[];
      String? cursor;
      var pages = 0;
      do {
        final page = await widget.api.offerings(widget.institute, cursor: cursor);
        offerings.addAll(page.items);
        cursor = page.nextCursor;
      } while (cursor != null && ++pages < _maxPages);
      if (!mounted || generation != _generation) return;
      final results = List<SubjectStats?>.filled(offerings.length, null);
      setState(() => _total = offerings.length);
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= offerings.length || generation != _generation) return;
          results[i] = await fetchSubjectStats(widget.api, widget.institute, offerings[i]);
          if (mounted && generation == _generation) setState(() => _done++);
        }
      }

      await Future.wait([
        for (var w = 0; w < math.min(_concurrency, offerings.length); w++) worker(),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _subjects = [for (final r in results) ?r];
        if (_group != null && !_subjects.any((s) => _key(s) == _group)) _group = null;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e is AppFailure
            ? e
            : const AppFailure('Could not load the dashboard. Retry.'));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  static String _key(SubjectStats s) => '${s.offering.termCode}|${s.offering.semester}';

  List<SubjectStats> get _visible => _group == null
      ? _subjects
      : _subjects.where((s) => _key(s) == _group).toList();

  List<SubjectStats> _sorted(List<SubjectStats> list) {
    final l = [...list];
    l.sort((a, b) {
      switch (_sort) {
        case _Sort.lowest:
          final x = a.percentage, y = b.percentage;
          if (x == null && y == null) return a.offering.title.compareTo(b.offering.title);
          if (x == null) return 1;
          if (y == null) return -1;
          return x.compareTo(y);
        case _Sort.name:
          return a.offering.title.compareTo(b.offering.title);
        case _Sort.semester:
          final c = a.offering.semester.compareTo(b.offering.semester);
          return c != 0 ? c : a.offering.title.compareTo(b.offering.title);
      }
    });
    return l;
  }

  Future<void> _export() async {
    String esc(Object? v) {
      final s = '${v ?? ''}';
      return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final lines = <String>[
      'Semester,Branch,Section,Subject code,Subject,Enrolment,Name,Classes conducted,Present,Absent,Percentage',
    ];
    for (final s in _sorted(_visible)) {
      if (s.error != null) continue;
      final o = s.offering;
      for (final d in s.students) {
        lines.add([
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
        ].join(','));
      }
    }
    final label = _group == null
        ? 'all-semesters'
        : _groups.firstWhere((g) => g.key == _group).label.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    await FilePicker.saveFile(
      fileName: 'attendance-$label.csv',
      bytes: utf8.encode('${lines.join('\n')}\n'),
      mimeType: 'text/csv',
      dialogTitle: 'Save semester attendance report',
    );
  }

  List<SemesterGroup> get _groups => groupBySemester(_subjects);

  @override
  Widget build(BuildContext context) {
    if (_loading && _subjects.isEmpty) {
      return Panel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(_total == 0
                  ? 'Loading your attendance overview…'
                  : 'Loading subject $_done of $_total…'),
            ],
          ),
        ),
      );
    }
    if (_error != null && _subjects.isEmpty) {
      return Panel(child: ErrorView(_error!, retry: _load));
    }
    if (_subjects.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final visible = _visible;
    final totals = DashboardTotals(visible);
    final shown = _sorted(visible).where((s) {
      if (!_attentionOnly) return true;
      final p = s.percentage;
      return s.error != null || (p != null && p < attendanceThreshold);
    }).toList();
    final failed = visible.where((s) => s.error != null).length;
    final groups = _groups;

    return Panel(
      accent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Attendance overview', style: theme.textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Refresh overview',
                onPressed: _loading ? null : () => ApiClient.freshReads(_load),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Text(
            'Faculty-published attendance across '
            '${visible.length} subject${visible.length == 1 ? '' : 's'}'
            '${_group == null ? '' : ' · ${groups.firstWhere((g) => g.key == _group).label}'}.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (groups.length > 1) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
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
            const SizedBox(height: 12),
            _Notice(
              '$failed subject${failed == 1 ? '' : 's'} could not be loaded and '
              '${failed == 1 ? 'is' : 'are'} left out of the totals.',
              onRetry: _load,
            ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 20,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PercentRing(
                value: totals.overall,
                caption: totals.overall == null ? 'No data yet' : 'overall',
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 280, maxWidth: 760),
                child: StatGrid(
                  minTileWidth: 150,
                  children: [
                    StatTile(
                      label: 'Overall attendance',
                      value: totals.overall ?? 0,
                      decimals: 1,
                      suffix: '%',
                      accent: percentColor(totals.overall),
                      icon: Icons.insights_outlined,
                      caption: totals.overall == null ? 'Nothing published yet' : 'across assessed classes',
                    ),
                    StatTile(
                      label: 'Subjects',
                      value: totals.loaded,
                      icon: Icons.menu_book_outlined,
                    ),
                    StatTile(
                      label: 'Classes held',
                      value: totals.classes,
                      icon: Icons.event_available_outlined,
                    ),
                    StatTile(
                      label: 'Students below $attendanceThreshold%',
                      value: totals.atRiskStudents,
                      accent: totals.atRiskStudents == 0 ? _green : _red,
                      icon: Icons.warning_amber_outlined,
                      caption: totals.atRiskStudents == 0
                          ? 'All on track'
                          : 'of ${totals.students} students',
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (groups.length > 1 && _group == null) ...[
            const SizedBox(height: 24),
            Text('Semester-wise', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final g in groups) _semesterRow(g),
          ],
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, c) {
              final distribution = _distribution(totals);
              final attention = _attention(totals);
              if (c.maxWidth >= 820) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: distribution),
                    const SizedBox(width: 32),
                    Expanded(child: attention),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [distribution, const SizedBox(height: 24), attention],
              );
            },
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Subject-wise statistics', style: theme.textTheme.titleMedium),
              OutlinedButton.icon(
                onPressed: visible.every((s) => s.students.isEmpty) ? null : _export,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Export report'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<_Sort>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Sort.lowest, label: Text('Lowest first')),
                  ButtonSegment(value: _Sort.name, label: Text('Subject')),
                  ButtonSegment(value: _Sort.semester, label: Text('Semester')),
                ],
                selected: {_sort},
                onSelectionChanged: (v) => setState(() => _sort = v.first),
              ),
              FilterChip(
                label: Text('Below $attendanceThreshold% only'),
                selected: _attentionOnly,
                onSelected: (v) => setState(() => _attentionOnly = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No subjects match this filter.'),
            )
          else
            for (final s in shown) _subjectRow(s),
        ],
      ),
    );
  }

  Widget _semesterRow(SemesterGroup g) {
    final t = DashboardTotals(g.subjects);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _group = g.key),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(g.label, style: const TextStyle(fontWeight: FontWeight.w700)),
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

  Widget _distribution(DashboardTotals t) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Attendance distribution', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Student records by percentage band',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 10),
      if (t.percentages.isEmpty)
        const Text('Publish attendance to see the distribution.')
      else
        BarDistribution(
          bars: [
            BarDatum('90–100%', t.bucket(90, 101), _green),
            BarDatum('75–89%', t.bucket(75, 90), _lightGreen),
            BarDatum('50–74%', t.bucket(50, 75), _amber),
            BarDatum('Below 50%', t.bucket(0, 50), _red),
          ],
        ),
    ],
  );

  Widget _attention(DashboardTotals t) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Needs attention', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Lowest attendance, below $attendanceThreshold%',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 6),
      if (t.lowest.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text('No student is below the threshold.'),
        )
      else
        for (final r in t.lowest.take(6))
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            onTap: () => context.push('/classes/${r.subject.offering.id}'),
            title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${r.number} · ${r.subject.offering.courseCode}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              '${r.percentage!.toStringAsFixed(1)}%',
              style: TextStyle(fontWeight: FontWeight.w800, color: percentColor(r.percentage)),
            ),
          ),
      if (t.lowest.length > 6)
        Text(
          '+ ${t.lowest.length - 6} more records. Export the report for the full list.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
    ],
  );

  Widget _subjectRow(SubjectStats s) {
    final o = s.offering;
    final theme = Theme.of(context);
    final p = s.percentage;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/classes/${o.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    o.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                if (s.error == null)
                  Text(
                    p == null ? '—' : '${p.toStringAsFixed(1)}%',
                    style: TextStyle(fontWeight: FontWeight.w800, color: percentColor(p)),
                  ),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
            Text(
              o.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (s.error != null)
              Text(s.error!.message, style: const TextStyle(color: _red))
            else ...[
              TrackBar(value: (p ?? 0) / 100, color: percentColor(p), height: 8),
              const SizedBox(height: 6),
              Text(
                '${s.students.length} students · ${s.conducted} classes held · '
                '${s.below} below $attendanceThreshold%',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, {required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _amber.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _amber.withValues(alpha: .35)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: _amber, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

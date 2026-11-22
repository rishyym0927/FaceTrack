import 'dart:convert';
import 'dart:math' as math;

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'teacher_dashboard.dart'
    show
        MetricGrid,
        MetricTile,
        ThresholdBar,
        attendanceThreshold,
        attendanceTone,
        belowAttendanceThreshold;

/// Narrows the loaded roster by a free-text query (name or enrolment) and the
/// below-threshold toggle. Pure, so it is testable without a widget.
List<Json> filterStudents(
  List<Json> all, {
  String query = '',
  bool belowOnly = false,
}) {
  final q = query.trim().toLowerCase();
  return all.where((s) {
    if (belowOnly && !belowAttendanceThreshold(s)) return false;
    if (q.isEmpty) return true;
    return '${s['official_name']} ${s['enrollment_number']}'
        .toLowerCase()
        .contains(q);
  }).toList();
}

/// Sort columns: 0 name, 1 enrolment, 2 present, 3 percentage. Students with
/// no assessed marks yet (no percentage) always sort last on the percentage
/// column, whichever direction is chosen. Returns a sorted copy.
List<Json> sortStudents(List<Json> list, int column, bool ascending) {
  int cmp(Json a, Json b) {
    if (column == 3) {
      final x = a['percentage'] as num?, y = b['percentage'] as num?;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      final c = x.compareTo(y);
      return ascending ? c : -c;
    }
    final r = switch (column) {
      0 => '${a['official_name']}'.compareTo('${b['official_name']}'),
      2 => ((a['attended'] as num?) ?? 0).compareTo((b['attended'] as num?) ?? 0),
      _ => '${a['enrollment_number']}'.compareTo('${b['enrollment_number']}'),
    };
    return ascending ? r : -r;
  }

  return [...list]..sort(cmp);
}

/// Mark totals across a roster. A legacy `late` mark counts as attended; it
/// is reported separately only so nothing is hidden when it is present.
class MarkTotals {
  MarkTotals(List<Json> students) {
    for (final s in students) {
      present += (s['present'] as num?)?.toInt() ?? 0;
      late += (s['late'] as num?)?.toInt() ?? 0;
      absent += (s['absent'] as num?)?.toInt() ?? 0;
      unassessed += unassessedCount(s).toInt();
    }
  }
  int present = 0, late = 0, absent = 0, unassessed = 0;
  int get total => present + late + absent + unassessed;
}

/// Cumulative semester attendance for one class: a summary with mark and
/// percentage distributions, then per-student totals with search, a
/// below-threshold filter, sorting and CSV export. Read-only -- it reflects
/// the published sessions and refreshes after each finalize.
class AttendanceOverview extends StatefulWidget {
  const AttendanceOverview({
    super.key,
    required this.api,
    required this.institute,
    required this.offering,
    this.version = 0,
    this.onAccessLost,
  });
  final ApiClient api;
  final String institute, offering;
  final int version;
  final ValueChanged<Object>? onAccessLost;

  @override
  State<AttendanceOverview> createState() => _AttendanceOverviewState();
}

/// Fixed widths for the numeric columns (before text scaling); name and
/// enrolment share the rest, so the table fills a wide desktop page and
/// scrolls sideways when it does not fit.
const _numW = 90.0, _pctW = 120.0, _tableMin = 640.0;

class _AttendanceOverviewState extends State<AttendanceOverview> {
  final _search = TextEditingController();
  Json? _data;
  AppFailure? _error;
  bool _loading = true, _belowOnly = false;
  int _sortCol = 1; // default by enrolment
  bool _asc = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AttendanceOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version != widget.version) _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ApiClient.freshReads(
        () => widget.api.send(
          'GET',
          '/v1/offerings/${widget.offering}/attendance-summary',
          institute: widget.institute,
        ),
      );
      if (mounted && generation == _generation) setState(() => _data = result);
    } catch (e) {
      if (mounted && generation == _generation) {
        if (e is AppFailure && const {401, 403, 404}.contains(e.status)) {
          widget.onAccessLost?.call(e);
        }
        setState(() {
          if (e is AppFailure && const {401, 403, 404}.contains(e.status)) {
            _data = null;
          }
          _error = e is AppFailure
              ? e
              : const AppFailure(
                  'Could not load the attendance overview. Retry.',
                );
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  List<Json> get _all => (_data?['students'] as List?)?.cast<Json>() ?? const [];

  List<Json> get _students => sortStudents(
    filterStudents(_all, query: _search.text, belowOnly: _belowOnly),
    _sortCol,
    _asc,
  );

  void _sort(int col) => setState(() {
    if (_sortCol == col) {
      _asc = !_asc;
    } else {
      _sortCol = col;
      _asc = true;
    }
  });

  void _sortTo(int col, bool asc) => setState(() {
    _sortCol = col;
    _asc = asc;
  });

  Future<void> _exportCsv() async {
    String esc(Object? v) {
      final s = '$v';
      return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final lines = <String>[
      'Name,Enrolment,Classes conducted,Present,Absent,Percentage',
    ];
    for (final s in _students) {
      lines.add(
        [
          esc(s['official_name']),
          esc(s['enrollment_number']),
          esc(s['conducted']),
          esc(s['attended']),
          esc(s['absent']),
          esc(s['percentage'] == null ? '' : '${s['percentage']}'),
        ].join(','),
      );
    }
    final bytes = utf8.encode('${lines.join('\n')}\n');
    await FilePicker.saveFile(
      fileName: 'semester-attendance.csv',
      bytes: bytes,
      mimeType: 'text/csv',
      dialogTitle: 'Save semester attendance',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkeletonStatGrid(count: 4),
          SizedBox(height: AppSpace.md),
          SkeletonPanel(rows: 3),
        ],
      );
    }
    if (_error != null && _data == null) {
      return ErrorView(_error!, retry: _load);
    }
    final theme = Theme.of(context);
    final conducted = _data?['sessions_conducted'] ?? 0;
    final all = _all;
    final students = _students;
    final pcts = <num>[
      for (final s in all)
        if ((s['assessed'] as num?) != null && (s['assessed'] as num) > 0)
          100 * (s['attended'] as num) / (s['assessed'] as num),
    ];
    final avg = pcts.isEmpty
        ? null
        : pcts.reduce((a, b) => a + b) / pcts.length;
    final below = all.where(belowAttendanceThreshold).length;
    final above = all
        .where((s) => s['percentage'] is num && !belowAttendanceThreshold(s))
        .length;
    final pad = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 24.0;
    return Panel(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            children: [
              Text('Semester attendance', style: theme.textTheme.titleLarge),
              OutlinedButton.icon(
                onPressed: _loading ? null : () => ApiClient.freshReads(_load),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: AppSpace.sm),
            const LinearProgressIndicator(
              semanticsLabel: 'Refreshing attendance',
            ),
          ],
          const SizedBox(height: AppSpace.xs),
          Text(
            '$conducted classes conducted · ${all.length} students',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.md),
            _InlineError(
              message: '${_error!.message} Showing the last loaded figures.',
              onRetry: () => ApiClient.freshReads(_load),
            ),
          ],
          if (all.isEmpty) ...[
            const SizedBox(height: AppSpace.md),
            EmptyState(
              icon: Icons.insights_outlined,
              title: 'No published sessions yet',
              message:
                  'Publish attendance for a session and the semester overview builds up here.',
              compact: true,
            ),
          ] else ...[
            const SizedBox(height: AppSpace.lg),
            Reveal(
              child: MetricGrid(
                children: [
                  MetricTile(
                    label: 'Average attendance',
                    value: avg == null ? '—' : '${avg.toStringAsFixed(1)}%',
                    tone: percentColor(avg),
                    icon: Icons.insights_outlined,
                    caption: avg == null ? 'No data yet' : 'across assessed',
                  ),
                  MetricTile(
                    label: 'At or above $attendanceThreshold%',
                    value: '$above',
                    tone: AppTone.success,
                    icon: Icons.trending_up,
                  ),
                  MetricTile(
                    label: 'Below $attendanceThreshold%',
                    value: '$below',
                    tone: below == 0 ? AppTone.success : AppTone.danger,
                    icon: Icons.trending_down,
                    caption: below == 0 ? 'All on track' : 'Need attention',
                  ),
                  MetricTile(
                    label: 'Classes held',
                    value: conducted is num ? '${conducted.toInt()}' : '0',
                    icon: Icons.event_available_outlined,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            LayoutBuilder(
              builder: (context, box) {
                final marks = _marks(theme, MarkTotals(all));
                final bands = _bands(theme, pcts);
                if (box.maxWidth >= 720 && pcts.isNotEmpty) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: marks),
                      const SizedBox(width: AppSpace.xxl),
                      Expanded(child: bands),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    marks,
                    if (pcts.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.xl),
                      bands,
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpace.xl),
            Text('Students', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.md),
            _controls(theme, students.length, all.length),
            const SizedBox(height: AppSpace.md),
            if (students.isEmpty)
              EmptyState(
                icon: Icons.search_off_outlined,
                title: 'No students match',
                message:
                    'Try a different name or clear the Below $attendanceThreshold% filter.',
                compact: true,
              )
            else
              LayoutBuilder(builder: (context, box) => _list(box, students)),
          ],
        ],
      ),
    );
  }

  // --- Mark and percentage distributions -------------------------------------

  Widget _marks(ThemeData theme, MarkTotals t) {
    final items = <(String, int, Color)>[
      ('Present', t.present, AppTone.success),
      if (t.late > 0) ('Late', t.late, const Color(0xff3f9e6b)),
      ('Absent', t.absent, AppTone.danger),
      if (t.unassessed > 0) ('Unassessed', t.unassessed, AppTone.neutral),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Attendance marks', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        Text(
          'Every mark recorded across published sessions',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpace.md),
        if (t.total == 0)
          const Text('No marks have been published yet.')
        else ...[
          Semantics(
            label: [
              for (final (label, n, _) in items) '$label $n',
            ].join(', '),
            child: ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: SizedBox(
                  height: 14,
                  child: Row(
                    children: [
                      for (final (_, n, color) in items)
                        if (n > 0)
                          Expanded(
                            flex: n,
                            child: ColoredBox(color: color),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.sm,
            children: [
              for (final (label, n, color) in items)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '$label $n (${(100 * n / t.total).toStringAsFixed(0)}%)',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _bands(ThemeData theme, List<num> pcts) {
    if (pcts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Attendance distribution', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpace.xs),
        Text(
          'Students by percentage band',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpace.sm),
        Reveal(
          child: BarDistribution(
            bars: [
              BarDatum(
                '90–100%',
                pcts.where((p) => p >= 90).length,
                AppTone.success,
              ),
              BarDatum(
                '75–89%',
                pcts.where((p) => p >= 75 && p < 90).length,
                const Color(0xff3f9e6b),
              ),
              BarDatum(
                '50–74%',
                pcts.where((p) => p >= 50 && p < 75).length,
                AppTone.warning,
              ),
              BarDatum(
                'Below 50%',
                pcts.where((p) => p < 50).length,
                AppTone.danger,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Search, filter, sort -----------------------------------------------------

  Widget _controls(ThemeData theme, int shown, int total) {
    final onVariant = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, box) => SizedBox(
            width: math.min(box.maxWidth, 360),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: 'Search name or enrolment',
              ),
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
              label: Text('Below $attendanceThreshold%'),
              selected: _belowOnly,
              onSelected: (v) => setState(() => _belowOnly = v),
            ),
            Text(
              'Sort',
              style: TextStyle(fontWeight: FontWeight.w600, color: onVariant),
            ),
            for (final (label, col, asc) in const [
              ('Name', 0, true),
              ('Enrolment', 1, true),
              ('Lowest %', 3, true),
              ('Highest %', 3, false),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _sortCol == col && _asc == asc,
                onSelected: (_) => _sortTo(col, asc),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Showing $shown of $total', style: TextStyle(color: onVariant)),
            OutlinedButton.icon(
              onPressed: shown == 0 ? null : _exportCsv,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Export CSV'),
            ),
          ],
        ),
      ],
    );
  }

  // --- Student list ----------------------------------------------------------------

  Widget _list(BoxConstraints box, List<Json> students) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    if (box.maxWidth < 560 * math.min(scale, 1.4)) {
      return Column(
        children: [
          for (final s in students) ...[
            _studentCard(context, s),
            const SizedBox(height: AppSpace.sm),
          ],
        ],
      );
    }
    final tableMin = _tableMin * scale;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: box.maxWidth < tableMin ? tableMin : box.maxWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _headerRow(scale),
            const Divider(height: 1),
            for (final s in students) ...[
              _studentRow(context, s, scale),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _cell(double? width, int flex, Widget child) => width == null
      ? Expanded(flex: flex, child: child)
      : SizedBox(width: width, child: child);

  Widget _headerRow(double scale) {
    Widget h(
      String label,
      int? col,
      double? w, {
      int flex = 1,
      bool right = false,
    }) => _cell(
      w,
      flex,
      Semantics(
        button: col != null,
        label: col == null
            ? label
            : '$label, ${_sortCol == col ? (_asc ? 'sorted ascending' : 'sorted descending') : 'activate to sort'}',
        child: InkWell(
          onTap: col == null ? null : () => _sort(col),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                mainAxisAlignment: right
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (col != null && _sortCol == col)
                    Icon(
                      _asc ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 14,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Row(
      children: [
        h('Student', 0, null, flex: 3),
        h('Enrolment', 1, null, flex: 2),
        h('Present', 2, _numW * scale, right: true),
        h('Absent', null, _numW * scale, right: true),
        h('%', 3, _pctW * scale, right: true),
      ],
    );
  }

  Widget _studentRow(BuildContext context, Json s, double scale) {
    Widget cell(double? w, String text, {int flex = 1, bool right = false}) =>
        _cell(
          w,
          flex,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Align(
              alignment: right ? Alignment.centerRight : Alignment.centerLeft,
              child: Text(text),
            ),
          ),
        );
    return Row(
      children: [
        cell(null, '${s['official_name']}', flex: 3),
        cell(null, '${s['enrollment_number']}', flex: 2),
        cell(_numW * scale, '${s['attended']}', right: true),
        cell(_numW * scale, '${s['absent']}', right: true),
        SizedBox(
          width: _pctW * scale,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _pctPill(s),
                if (s['percentage'] is num) ...[
                  const SizedBox(height: 6),
                  TrackBar(
                    value: (s['percentage'] as num) / 100,
                    color: attendanceTone(s),
                    height: 5,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The percentage as a colour-coded pill; the warning icon marks students
  /// below the threshold so colour is never the only cue.
  Widget _pctPill(Json s) {
    final pct = s['percentage'];
    if (pct is! num) {
      return const TonePill('No data');
    }
    return TonePill(
      '${pct.toStringAsFixed(1)}%',
      tone: attendanceTone(s),
      icon: belowAttendanceThreshold(s) ? Icons.warning_amber_outlined : null,
    );
  }

  Widget _studentCard(BuildContext context, Json s) {
    final theme = Theme.of(context);
    final onVariant = theme.colorScheme.onSurfaceVariant;
    final unassessed = unassessedCount(s).toInt();
    final assessed = (s['assessed'] as num?)?.toInt() ?? 0;
    final pct = s['percentage'];
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${s['official_name']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${s['enrollment_number']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: onVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              _pctPill(s),
            ],
          ),
          if (pct is num) ...[
            const SizedBox(height: AppSpace.sm),
            ThresholdBar(value: pct.toDouble(), color: attendanceTone(s), height: 6),
          ],
          const SizedBox(height: AppSpace.sm),
          Text(
            'Present ${s['attended'] ?? 0} · Absent ${s['absent'] ?? 0} · $assessed assessed'
            '${unassessed > 0 ? ' · $unassessed unassessed' : ''}',
            style: TextStyle(fontSize: 12, color: onVariant),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.error.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

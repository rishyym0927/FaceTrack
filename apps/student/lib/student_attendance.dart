import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'student_notifications.dart' show attendanceThreshold;

const _present = Color(0xff176451), _absent = Color(0xffa22f2f);

/// Present / Absent / Unassessed counts over published records, with the
/// session-v1 percentage (unassessed never counts).
class AttendanceStats {
  AttendanceStats(Iterable<Json> rows) {
    for (final r in rows) {
      switch (finalStatus(r['status'] as String?)) {
        case 'present':
          present++;
        case 'absent':
          absent++;
        default:
          unassessed++;
      }
    }
  }
  int present = 0, absent = 0, unassessed = 0;
  int get assessed => present + absent;
  int get total => assessed + unassessed;
  double? get percentage => assessed == 0 ? null : 100 * present / assessed;

  /// Classes in a row to attend to reach [attendanceThreshold]%.
  int get toReachThreshold {
    final t = attendanceThreshold / 100;
    if (assessed == 0 || present / assessed >= t) return 0;
    return ((t * assessed - present) / (1 - t)).ceil();
  }

  /// Classes that can be missed while staying at or above the threshold.
  int get canMiss {
    final t = attendanceThreshold / 100;
    if (assessed == 0) return 0;
    final n = (present / t - assessed).floor();
    return n < 0 ? 0 : n;
  }
}

String attendanceAdvice(AttendanceStats s) {
  final pct = s.percentage;
  if (pct == null) return 'No assessed classes in this view yet.';
  if (pct < attendanceThreshold) {
    return 'Below $attendanceThreshold%. Attend the next ${s.toReachThreshold} '
        'class${s.toReachThreshold == 1 ? '' : 'es'} to get back to $attendanceThreshold%.';
  }
  if (s.canMiss == 0) {
    return 'On track, but missing the next class would take you below $attendanceThreshold%.';
  }
  return 'On track. You can miss ${s.canMiss} class${s.canMiss == 1 ? '' : 'es'} '
      'and stay at or above $attendanceThreshold%.';
}

enum AttendanceRange { all, month, quarter }

/// The rows left after the subject, range and status filters.
List<Json> filterRecords(
  List<Json> rows, {
  String? subject,
  String? status,
  AttendanceRange range = AttendanceRange.all,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final from = switch (range) {
    AttendanceRange.all => null,
    AttendanceRange.month => DateTime(today.year, today.month),
    AttendanceRange.quarter => DateTime(today.year, today.month - 2),
  };
  return [
    for (final r in rows)
      if ((subject == null || r['offering_id'] == subject) &&
          (status == null || finalStatus(r['status'] as String?) == status) &&
          (from == null ||
              !DateTime.parse(r['starts_at'] as String)
                  .toLocal()
                  .isBefore(from)))
        r,
  ];
}

class StudentAttendance extends ConsumerStatefulWidget {
  const StudentAttendance({super.key});
  @override
  ConsumerState<StudentAttendance> createState() => _StudentAttendanceState();
}

class _StudentAttendanceState extends ConsumerState<StudentAttendance>
    with ResumeRefresh<StudentAttendance> {
  late final ApiClient api;
  late final String institute;
  bool loading = true;
  Object? error;
  List<Json> records = [];
  bool hasOlderRecords = false;
  List<Json> disputes = [];
  final titles = <String, Offering>{};
  final failed = <String>[];
  String? subject, status;
  AttendanceRange range = AttendanceRange.all;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    load();
    watchLifecycle();
  }

  @override
  void refreshOnResume() => load();

  @override
  void dispose() {
    unwatchLifecycle();
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++_generation;
    setState(() {
      loading = true;
      error = null;
    });
    final missing = <String>[];
    final names = <String, Offering>{};
    var queries = <Json>[];
    Future<void> subjects() async {
      try {
        String? cursor;
        var pages = 0;
        do {
          final page = await api.enrollments(institute, cursor: cursor);
          for (final e in page.items) {
            if (e.offering != null) names[e.offeringId] = e.offering!;
          }
          cursor = page.nextCursor;
        } while (cursor != null && ++pages < 5);
      } catch (_) {
        missing.add('subject names');
      }
    }

    Future<void> disputeRows() async {
      try {
        queries = await fetchAllPages(
          api,
          '/v1/me/attendance-disputes',
          institute,
        );
      } catch (_) {
        missing.add('attendance queries');
      }
    }

    Future<(List<Json>, bool)> attendanceRows() async {
      final rows = <Json>[];
      String? cursor;
      for (var pageNumber = 0; pageNumber < 5; pageNumber++) {
        final page = await api.send(
          'GET',
          '/v1/me/attendance',
          institute: institute,
          query: {'limit': 200, 'cursor': ?cursor},
        );
        rows.addAll((page['items'] as List).cast<Json>());
        cursor = page['next_cursor'] as String?;
        if (cursor == null || !mounted || generation != _generation) break;
      }
      return (rows, cursor != null);
    }

    try {
      final results = await Future.wait([
        attendanceRows(),
        subjects(),
        disputeRows(),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        final (loadedRecords, hasMore) = results[0] as (List<Json>, bool);
        records = loadedRecords;
        hasOlderRecords = hasMore;
        disputes = queries;
        titles
          ..clear()
          ..addAll(names);
        failed
          ..clear()
          ..addAll(missing);
        if (subject != null &&
            !records.any((r) => r['offering_id'] == subject)) {
          subject = null;
        }
        loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        error = e;
        if (e is AppFailure && [401, 403, 404].contains(e.status)) {
          records = [];
          hasOlderRecords = false;
          disputes = [];
          titles.clear();
          failed.clear();
          subject = null;
          status = null;
          range = AttendanceRange.all;
        }
        loading = false;
      });
    }
  }

  String title(String offering) => titles[offering]?.title ?? 'Subject';

  Json? queryFor(Json r) {
    for (final d in disputes) {
      if (d['session_id'] == r['session_id']) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final header = PageHeader(
      title: 'Your attendance',
      action: OutlinedButton.icon(
        onPressed: loading ? null : load,
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh'),
      ),
    );
    if (loading && records.isEmpty) {
      return ContentPage(
        onRefresh: load,
        children: [header, const SkeletonList()],
      );
    }
    if (error != null && records.isEmpty) {
      return ContentPage(
        onRefresh: load,
        children: [
          header,
          ErrorView(error!, retry: load),
        ],
      );
    }
    if (records.isEmpty) {
      return ContentPage(
        onRefresh: load,
        children: [
          header,
          const MessageView(
            title: 'No published attendance yet',
            message: 'Your faculty must review and publish a class before it appears here.',
          ),
        ],
      );
    }
    final marked = records
        .where(
          (row) =>
              finalStatuses.contains(finalStatus(row['status'] as String?)),
        )
        .toList();
    final scoped = filterRecords(marked, subject: subject, range: range);
    final listed = filterRecords(scoped, status: status);
    return ContentPage(
      onRefresh: load,
      children: [
        header,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ErrorView(error!, retry: load),
          ),
        if (failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Could not load ${failed.join(' and ')}; the rest is shown.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (hasOlderRecords)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Records, filters and trends cover the latest ${records.length} published records. Open a subject to see its older records.',
            ),
          ),
        _filters(context),
        const SizedBox(height: 16),
        _records(context, listed),
        ExpansionTile(
          title: const Text('Attendance trends'),
          children: [
            _overview(context, AttendanceStats(scoped)),
            if (subject == null) _bySubject(context, scoped),
            _trend(context, scoped),
          ],
        ),
      ],
    );
  }

  Widget _filters(BuildContext context) {
    final subjects = {for (final r in records) r['offering_id'] as String};
    return Panel(
      padding: 14,
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
            child: DropdownButtonFormField<String?>(
              key: ValueKey('subject:$subject'),
              initialValue: subject,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Subject',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('All subjects'),
                ),
                for (final o in subjects)
                  DropdownMenuItem(
                    value: o,
                    child: Text(title(o), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => subject = v),
            ),
          ),
          SegmentedButton<AttendanceRange>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: AttendanceRange.month,
                label: Text('This month'),
              ),
              ButtonSegment(
                value: AttendanceRange.quarter,
                label: Text('3 months'),
              ),
              ButtonSegment(value: AttendanceRange.all, label: Text('All')),
            ],
            selected: {range},
            onSelectionChanged: (v) => setState(() => range = v.first),
          ),
        ],
      ),
    );
  }

  Widget _overview(BuildContext context, AttendanceStats s) {
    final scheme = Theme.of(context).colorScheme;
    final pct = s.percentage;
    final advice = attendanceAdvice(s);
    final ring = PercentRing(value: pct, size: 128, caption: 'attendance');
    final tiles = StatGrid(
      minTileWidth: 120,
      children: [
        StatTile(
          label: 'Present',
          value: s.present,
          accent: _present,
          icon: Icons.check_circle_outline,
        ),
        StatTile(
          label: 'Absent',
          value: s.absent,
          accent: _absent,
          icon: Icons.cancel_outlined,
        ),
      ],
    );
    return Panel(
      accent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Overview', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, box) => box.maxWidth >= 480
                ? Row(
                    children: [
                      ring,
                      const SizedBox(width: 20),
                      Expanded(child: tiles),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: ring),
                      const SizedBox(height: 16),
                      tiles,
                    ],
                  ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                pct == null
                    ? Icons.remove_circle_outline
                    : pct < attendanceThreshold
                    ? Icons.trending_down
                    : Icons.trending_up,
                color: pct == null
                    ? scheme.onSurfaceVariant
                    : pct < attendanceThreshold
                    ? _absent
                    : _present,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(advice)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bySubject(BuildContext context, List<Json> rows) {
    final scheme = Theme.of(context).colorScheme;
    final groups = <String, List<Json>>{};
    for (final r in rows) {
      groups.putIfAbsent(r['offering_id'] as String, () => []).add(r);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => title(a.key).compareTo(title(b.key)));
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('By subject', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Text(
              'No classes in this period.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          for (final e in entries)
            Builder(
              builder: (context) {
                final s = AttendanceStats(e.value), pct = s.percentage;
                final low = pct != null && pct < attendanceThreshold;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/classes/${e.key}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title(e.key),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (titles[e.key] != null)
                                    Text(
                                      titles[e.key]!.subtitle,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (low)
                              const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: Icon(
                                  Icons.warning_amber_rounded,
                                  color: _absent,
                                  size: 20,
                                ),
                              ),
                            Text(
                              pct == null ? '—' : '${pct.toStringAsFixed(1)}%',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: percentColor(pct),
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TrackBar(
                          value: (pct ?? 0) / 100,
                          color: percentColor(pct),
                          height: 10,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Present ${s.present} · Absent ${s.absent}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _trend(BuildContext context, List<Json> rows) {
    final now = DateTime.now();
    final months = [
      for (var i = 5; i >= 0; i--) DateTime(now.year, now.month - i),
    ];
    final byMonth = {for (final m in months) m: <Json>[]};
    for (final r in rows) {
      final d = DateTime.parse(r['starts_at'] as String).toLocal();
      byMonth[DateTime(d.year, d.month)]?.add(r);
    }
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Last 6 months', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          MonthlyBars(
            months: [
              for (final m in months)
                MonthBar(
                  label: _monthName(m.month),
                  stats: AttendanceStats(byMonth[m]!),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Wrap(
            spacing: 16,
            children: [
              _Legend(_present, 'Present'),
              _Legend(_absent, 'Absent'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _records(BuildContext context, List<Json> rows) {
    final scheme = Theme.of(context).colorScheme;
    final l = MaterialLocalizations.of(context);
    final sorted = [...rows]
      ..sort(
        (a, b) =>
            (b['starts_at'] as String).compareTo(a['starts_at'] as String),
      );
    final children = <Widget>[];
    DateTime? month;
    for (final r in sorted) {
      final d = DateTime.parse(r['starts_at'] as String).toLocal();
      final m = DateTime(d.year, d.month);
      if (m != month) {
        month = m;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(
              '${_monthName(m.month)} ${m.year}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      final query = queryFor(r);
      children.add(
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            onTap: () => context.push('/classes/${r['offering_id']}'),
            title: Text(
              title(r['offering_id'] as String),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l.formatMediumDate(d)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}',
                ),
                if (r['reason'] is String && (r['reason'] as String).isNotEmpty)
                  Text('Faculty note: ${r['reason']}'),
                if (query != null)
                  Text(
                    'Query: ${switch (query['status']) {
                      'open' => 'waiting for faculty',
                      'accepted' => 'accepted',
                      'rejected' => 'declined',
                      _ => 'withdrawn',
                    }}',
                  ),
              ],
            ),
            trailing: StatusBadge(finalStatus(r['status'] as String?)),
          ),
        ),
      );
    }
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Records', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, label) in const [
                (null, 'All'),
                ('present', 'Present'),
                ('absent', 'Absent'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: status == value,
                  onSelected: (_) => setState(() => status = value),
                ),
            ],
          ),
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'No classes match these filters.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

String _monthName(int month) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];

class MonthBar {
  const MonthBar({required this.label, required this.stats});
  final String label;
  final AttendanceStats stats;
}

/// Stacked vertical bars, one per month, sharing one scale.
class MonthlyBars extends StatelessWidget {
  const MonthlyBars({super.key, required this.months, this.height = 140});
  final List<MonthBar> months;
  final double height;
  @override
  Widget build(BuildContext context) {
    final most = months.fold<int>(
      1,
      (m, b) => b.stats.assessed > m ? b.stats.assessed : m,
    );
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final b in months)
          Expanded(
            child: Semantics(
              label:
                  '${b.label}: ${b.stats.present} present, ${b.stats.absent} absent',
              child: Column(
                children: [
                  Text(
                    '${b.stats.assessed}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: height,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        widthFactor: .5,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (final (n, c) in [
                              (b.stats.absent, _absent),
                              (b.stats.present, _present),
                            ])
                              if (n > 0)
                                Container(height: height * n / most, color: c),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(b.label, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}

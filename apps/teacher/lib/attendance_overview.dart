import 'dart:convert';

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Cumulative semester attendance for one class: per-student totals and %,
/// with search, a below-threshold filter, sort and CSV export. Read-only --
/// it reflects the published sessions and refreshes after each finalize.
class AttendanceOverview extends StatefulWidget {
  const AttendanceOverview({
    super.key,
    required this.api,
    required this.institute,
    required this.offering,
  });
  final ApiClient api;
  final String institute, offering;

  @override
  State<AttendanceOverview> createState() => _AttendanceOverviewState();
}

const _nameW = 200.0, _enrolW = 120.0, _numW = 90.0, _pctW = 90.0;

class _AttendanceOverviewState extends State<AttendanceOverview> {
  final _search = TextEditingController();
  Json? _data;
  AppFailure? _error;
  bool _loading = true, _belowOnly = false;
  int _sortCol = 1; // default by enrolment
  bool _asc = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.api.send(
        'GET',
        '/v1/offerings/${widget.offering}/attendance-summary',
        institute: widget.institute,
      );
      if (mounted) setState(() => _data = result);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is AppFailure
            ? e
            : const AppFailure('Could not load the attendance overview. Retry.'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Json> get _students {
    final all = (_data?['students'] as List?)?.cast<Json>() ?? const [];
    final q = _search.text.trim().toLowerCase();
    final list = all.where((s) {
      if (_belowOnly) {
        final p = s['percentage'];
        if (p == null || (p as num) >= 75) return false;
      }
      if (q.isEmpty) return true;
      return '${s['official_name']} ${s['enrollment_number']}'
          .toLowerCase()
          .contains(q);
    }).toList();
    int cmp(Json a, Json b) {
      final r = switch (_sortCol) {
        0 => '${a['official_name']}'.compareTo('${b['official_name']}'),
        2 => (a['attended'] as num).compareTo(b['attended'] as num),
        3 => ((a['percentage'] as num?) ?? -1).compareTo((b['percentage'] as num?) ?? -1),
        _ => '${a['enrollment_number']}'.compareTo('${b['enrollment_number']}'),
      };
      return _asc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  void _sort(int col) => setState(() {
    if (_sortCol == col) {
      _asc = !_asc;
    } else {
      _sortCol = col;
      _asc = true;
    }
  });

  Future<void> _exportCsv() async {
    String esc(Object? v) {
      final s = '$v';
      return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final lines = <String>[
      'Name,Enrolment,Classes conducted,Present,Absent,Unassessed,Percentage',
    ];
    for (final s in _students) {
      lines.add([
        esc(s['official_name']),
        esc(s['enrollment_number']),
        esc(s['conducted']),
        esc(s['attended']),
        esc(s['absent']),
        esc(unassessedCount(s)),
        esc(s['percentage'] == null ? '' : '${s['percentage']}'),
      ].join(','));
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
      return const Panel(child: Center(child: Padding(
        padding: EdgeInsets.all(24), child: CircularProgressIndicator())));
    }
    if (_error != null && _data == null) {
      return Panel(child: ErrorView(_error!, retry: _load));
    }
    final conducted = _data?['sessions_conducted'] ?? 0;
    final students = _students;
    final all = (_data?['students'] as List?)?.cast<Json>() ?? const [];
    final pcts = <num>[
      for (final s in all)
        if (s['percentage'] is num) s['percentage'] as num,
    ];
    final avg = pcts.isEmpty ? null : pcts.reduce((a, b) => a + b) / pcts.length;
    final below = pcts.where((p) => p < 75).length;
    final above = pcts.where((p) => p >= 75).length;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Semester attendance',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$conducted classes conducted · ${all.length} students',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (all.isNotEmpty) ...[
            const SizedBox(height: 16),
            Reveal(
              child: StatGrid(
                children: [
                  StatTile(
                    label: 'Average attendance',
                    value: avg ?? 0,
                    decimals: 1,
                    suffix: '%',
                    accent: percentColor(avg),
                    icon: Icons.insights_outlined,
                    caption: avg == null ? 'No data yet' : 'across assessed',
                  ),
                  StatTile(
                    label: 'At or above 75%',
                    value: above,
                    accent: const Color(0xff176451),
                    icon: Icons.trending_up,
                  ),
                  StatTile(
                    label: 'Below 75%',
                    value: below,
                    accent: const Color(0xffa22f2f),
                    icon: Icons.trending_down,
                    caption: below == 0 ? 'All on track' : 'Need attention',
                  ),
                  StatTile(
                    label: 'Classes held',
                    value: conducted is num ? conducted : 0,
                    icon: Icons.event_available_outlined,
                  ),
                ],
              ),
            ),
            if (pcts.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text(
                'Attendance distribution',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Reveal(
                child: BarDistribution(
                  bars: [
                    BarDatum('90–100%',
                        pcts.where((p) => p >= 90).length,
                        const Color(0xff176451)),
                    BarDatum('75–89%',
                        pcts.where((p) => p >= 75 && p < 90).length,
                        const Color(0xff3f9e6b)),
                    BarDatum('50–74%',
                        pcts.where((p) => p >= 50 && p < 75).length,
                        const Color(0xff9a6a00)),
                    BarDatum('Below 50%',
                        pcts.where((p) => p < 50).length,
                        const Color(0xffa22f2f)),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
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
              FilterChip(
                label: const Text('Below 75%'),
                selected: _belowOnly,
                onSelected: (v) => setState(() => _belowOnly = v),
              ),
              OutlinedButton.icon(
                onPressed: students.isEmpty ? null : _exportCsv,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Export CSV'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (students.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                conducted == 0
                    ? 'No published sessions yet. Publish attendance to build the overview.'
                    : 'No students match the current search or filter.',
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _nameW + _enrolW + _numW * 3 + _pctW,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _headerRow(),
                    const Divider(height: 1),
                    for (final s in students) ...[
                      _studentRow(context, s),
                      const Divider(height: 1),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerRow() {
    Widget h(String label, int? col, double w, {bool right = false}) => SizedBox(
      width: w,
      child: InkWell(
        onTap: col == null ? null : () => _sort(col),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            mainAxisAlignment:
                right ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (col != null && _sortCol == col)
                Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        h('Student', 0, _nameW),
        h('Enrolment', 1, _enrolW),
        h('Present', 2, _numW, right: true),
        h('Absent', null, _numW, right: true),
        h('Unassessed', null, _numW, right: true),
        h('%', 3, _pctW, right: true),
      ],
    );
  }

  Widget _studentRow(BuildContext context, Json s) {
    Widget cell(double w, String text, {bool right = false}) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(text),
        ),
      ),
    );
    final pct = s['percentage'];
    return Row(
      children: [
        cell(_nameW, '${s['official_name']}'),
        cell(_enrolW, '${s['enrollment_number']}'),
        cell(_numW, '${s['attended']}', right: true),
        cell(_numW, '${s['absent']}', right: true),
        cell(_numW, '${unassessedCount(s)}', right: true),
        SizedBox(
          width: _pctW,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pct == null ? '—' : '${(pct as num).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: pct == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : percentColor(pct),
                  ),
                ),
                if (pct is num) ...[
                  const SizedBox(height: 6),
                  TrackBar(
                    value: pct / 100,
                    color: percentColor(pct),
                    height: 6,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

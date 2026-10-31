import 'dart:convert';

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Interactive attendance review table: AI status, per-row approve/disapprove,
/// one-click "Approve all matched", search, sort, filter and CSV export.
/// It never changes attendance by itself -- it only edits the parent's pending
/// decisions, which the teacher still saves/publishes behind the existing gate.
///
/// Built from fixed-width columns inside a horizontal scroll (not Material
/// DataTable) so it stays usable at phone width and 200% text without overflow.
class AttendanceReviewTable extends StatefulWidget {
  const AttendanceReviewTable({
    super.key,
    required this.rows,
    required this.decisions,
    required this.editable,
    required this.finalised,
    required this.busy,
    required this.sessionLabel,
    required this.onChanged,
    required this.onApproveAllMatched,
    required this.onCorrect,
  });

  final List<Json> rows;
  final Map<String, String> decisions;
  final bool editable;
  final bool finalised;
  final bool busy;
  final String sessionLabel;
  final void Function(String studentId, String status) onChanged;
  final VoidCallback onApproveAllMatched;
  final void Function(Json row) onCorrect;

  @override
  State<AttendanceReviewTable> createState() => _AttendanceReviewTableState();
}

const _overrideStatuses = finalStatuses;
const _nameW = 200.0, _enrolW = 120.0, _aiW = 150.0, _decW = 280.0;

String aiStatusLabel(Json row) => switch (row['status']) {
  'proposed_present' => 'Matched',
  'proposed_absent' => 'Not recognized',
  'unassessed' => 'Unassessed',
  _ => 'Confirmed',
};

/// Draft decisions a review starts with: every student the recognizer did not
/// find in a usable capture ("Not recognized") starts as Absent, so a class
/// with real absentees needs no per-row changes. Matched and Unassessed rows
/// are left for the teacher. Nothing is recorded until the teacher saves or
/// publishes, and the AI column still shows "Not recognized".
Map<String, String> draftAbsentDecisions(List<Json> rows) => {
  for (final row in rows)
    if (row['status'] == 'proposed_absent') row['student_id'] as String: 'absent',
};

String _statusText(String status) => status.startsWith('proposed_')
    ? status[0].toUpperCase() + status.substring(1)
    : attendanceLabel(status);

class _AttendanceReviewTableState extends State<AttendanceReviewTable> {
  final _search = TextEditingController();
  String _filter = 'all';
  int _sortCol = 0;
  bool _asc = true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _current(Json row) =>
      widget.decisions[row['student_id']] ?? row['status'] as String;

  bool _matchesFilter(Json row) => switch (_filter) {
    'matched' => row['status'] == 'proposed_present',
    'not_recognized' => row['status'] == 'proposed_absent',
    'unassessed' => row['status'] == 'unassessed',
    _ => true,
  };

  List<Json> get _visible {
    final q = _search.text.trim().toLowerCase();
    final list = widget.rows.where((row) {
      if (!_matchesFilter(row)) return false;
      if (q.isEmpty) return true;
      return '${row['official_name']} ${row['enrollment_number']}'
          .toLowerCase()
          .contains(q);
    }).toList();
    int cmp(Json a, Json b) {
      final r = switch (_sortCol) {
        1 => '${a['enrollment_number']}'.compareTo('${b['enrollment_number']}'),
        2 => aiStatusLabel(a).compareTo(aiStatusLabel(b)),
        _ => '${a['official_name']}'.compareTo('${b['official_name']}'),
      };
      return _asc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  int get _unconfirmedMatched => widget.rows
      .where((r) =>
          (widget.decisions[r['student_id']] ?? r['status']) == 'proposed_present')
      .length;

  Future<void> _exportCsv() async {
    String esc(Object? v) {
      final s = '$v';
      return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final lines = <String>['Name,Enrolment,AI status,Decision'];
    for (final row in _visible) {
      lines.add([
        esc(row['official_name']),
        esc(row['enrollment_number']),
        esc(aiStatusLabel(row)),
        esc(_statusText(_current(row))),
      ].join(','));
    }
    final bytes = utf8.encode('${lines.join('\n')}\n');
    await FilePicker.saveFile(
      fileName: 'attendance-review.csv',
      bytes: bytes,
      mimeType: 'text/csv',
      dialogTitle: 'Save attendance table',
    );
  }

  void _sort(int col) => setState(() {
    if (_sortCol == col) {
      _asc = !_asc;
    } else {
      _sortCol = col;
      _asc = true;
    }
  });

  @override
  Widget build(BuildContext context) {
    final matched = widget.rows.where((r) => r['status'] == 'proposed_present').length;
    final notRec = widget.rows.where((r) => r['status'] == 'proposed_absent').length;
    final unassessed = widget.rows.where((r) => r['status'] == 'unassessed').length;
    final visible = _visible;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Attendance review', style: Theme.of(context).textTheme.titleLarge),
          if (widget.rows.isNotEmpty) ...[
            const SizedBox(height: 16),
            Reveal(
              child: StatGrid(
                minTileWidth: 150,
                children: [
                  StatTile(
                    label: 'Students',
                    value: widget.rows.length,
                    icon: Icons.groups_outlined,
                  ),
                  StatTile(
                    label: 'Matched',
                    value: matched,
                    accent: const Color(0xff176451),
                    icon: Icons.verified_outlined,
                  ),
                  StatTile(
                    label: 'Not recognized',
                    value: notRec,
                    accent: const Color(0xff805500),
                    icon: Icons.help_outline,
                  ),
                  StatTile(
                    label: 'Unassessed',
                    value: unassessed,
                    accent: const Color(0xff465650),
                    icon: Icons.remove_circle_outline,
                  ),
                ],
              ),
            ),
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
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search name or enrolment',
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() => _search.clear()),
                          ),
                  ),
                ),
              ),
              for (final f in const [
                ('all', 'All'),
                ('matched', 'Matched'),
                ('not_recognized', 'Not recognized'),
                ('unassessed', 'Unassessed'),
              ])
                FilterChip(
                  label: Text(f.$2),
                  selected: _filter == f.$1,
                  onSelected: (_) => setState(() => _filter = f.$1),
                ),
              OutlinedButton.icon(
                onPressed: visible.isEmpty ? null : _exportCsv,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Export CSV'),
              ),
            ],
          ),
          if (widget.editable) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: widget.busy || _unconfirmedMatched == 0
                  ? null
                  : widget.onApproveAllMatched,
              icon: const Icon(Icons.done_all),
              label: Text(
                _unconfirmedMatched == 0
                    ? 'All matched approved'
                    : 'Approve all matched ($_unconfirmedMatched)',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Approves only AI-matched students. Not-recognized and unassessed stay for you to decide.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No students match the current search or filter.'),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _nameW + _enrolW + _aiW + _decW,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _headerRow(context),
                    const Divider(height: 1),
                    for (final row in visible) ...[
                      _dataRow(context, row),
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

  Widget _headerRow(BuildContext context) {
    Widget head(String label, int? col, double w) => SizedBox(
      width: w,
      child: InkWell(
        onTap: col == null ? null : () => _sort(col),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
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
        head('Student', 0, _nameW),
        head('Enrolment', 1, _enrolW),
        head('AI status', 2, _aiW),
        head(widget.finalised ? 'Published' : 'Decision', null, _decW),
      ],
    );
  }

  Widget _dataRow(BuildContext context, Json row) {
    final id = row['student_id'] as String;
    final current = _current(row);
    Widget cell(double w, Widget child) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: child,
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        cell(_nameW, Text(row['official_name'])),
        cell(_enrolW, Text('${row['enrollment_number']}')),
        cell(
          _aiW,
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(message: _evidence(row), child: _aiChip(row)),
          ),
        ),
        cell(
          _decW,
          widget.finalised
              ? Row(
                  children: [
                    Flexible(
                      child: Text(_statusText(current),
                          overflow: TextOverflow.ellipsis),
                    ),
                    TextButton(
                      onPressed: widget.busy ? null : () => widget.onCorrect(row),
                      child: const Text('Correct'),
                    ),
                  ],
                )
              : widget.editable
              ? _decisionControls(id, current)
              : Text(_statusText(current)),
        ),
      ],
    );
  }

  Widget _decisionControls(String id, String current) {
    final isPresent = finalStatus(current) == 'present' || current == 'proposed_present';
    final isAbsent = current == 'absent';
    // The ✓/✗ highlight shows the teacher's choice; show a small label only for
    // Unassessed (including legacy excused) so the row stays compact.
    final otherLabel = finalStatus(current) == 'unassessed' &&
            !current.startsWith('proposed_')
        ? _statusText(current)
        : null;
    IconButton icon(String tip, bool on, IconData onIcon, IconData offIcon,
            Color onColor, String status) =>
        IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: EdgeInsets.zero,
          isSelected: on,
          color: on ? onColor : null,
          icon: Icon(on ? onIcon : offIcon),
          onPressed: widget.busy ? null : () => widget.onChanged(id, status),
        );
    return Row(
      children: [
        icon('Approve (present)', isPresent, Icons.check_circle,
            Icons.check_circle_outline, const Color(0xff176451), 'present'),
        icon('Disapprove (absent)', isAbsent, Icons.cancel, Icons.cancel_outlined,
            const Color(0xffa22f2f), 'absent'),
        PopupMenuButton<String>(
          tooltip: 'More options',
          enabled: !widget.busy,
          icon: const Icon(Icons.more_vert, size: 20),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onSelected: (v) => widget.onChanged(id, v),
          itemBuilder: (_) => [
            for (final s in _overrideStatuses)
              PopupMenuItem(value: s, child: Text(_statusText(s))),
          ],
        ),
        if (otherLabel != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(otherLabel, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    );
  }

  Widget _aiChip(Json row) {
    final (label, color) = switch (row['status']) {
      'proposed_present' => ('Matched', const Color(0xff176451)),
      'proposed_absent' => ('Not recognized', const Color(0xff805500)),
      'unassessed' => ('Unassessed', const Color(0xff465650)),
      _ => ('Confirmed', const Color(0xff176451)),
    };
    return _chip(label, color);
  }

  Widget _chip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.09),
      borderRadius: BorderRadius.circular(100),
      border: Border.all(color: color.withValues(alpha: 0.16)),
    ),
    child: Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontWeight: FontWeight.w700),
    ),
  );

  String _evidence(Json row) => switch (row['assessment_code']) {
    'recognized' => 'Recognized in separate video frames.',
    'not_recognized' =>
      'No corroborated match in a usable capture. Verify before marking Absent.',
    'template_ineligible' =>
      'No approved face enrolment yet, so the model cannot check this student; assess manually.',
    'limited_capture' =>
      'Too few clear frames of this student; record again closer or assess manually.',
    'processing_failed' => 'Processing failed; assess manually.',
    _ => aiStatusLabel(row),
  };
}

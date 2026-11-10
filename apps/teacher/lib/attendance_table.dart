import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';

/// Prefill marks after a recording has produced a recognition result.
Map<String, String> draftScanDecisions(List<Json> rows) {
  final processed = rows.any(
    (row) =>
        row['status'] == 'proposed_present' ||
        row['status'] == 'proposed_absent' ||
        const {
          'recognized',
          'not_recognized',
          'limited_capture',
        }.contains(row['assessment_code']),
  );
  if (!processed) return {};
  return {
    for (final row in rows)
      if (!finalStatuses.contains(row['status']))
        row['student_id'] as String: row['status'] == 'proposed_present'
            ? 'present'
            : 'absent',
  };
}

class AttendanceReviewTable extends StatefulWidget {
  const AttendanceReviewTable({
    super.key,
    required this.rows,
    required this.decisions,
    required this.editable,
    required this.finalised,
    required this.busy,
    required this.onChanged,
    required this.onApproveAllMatched,
    required this.onCorrect,
  });

  final List<Json> rows;
  final Map<String, String> decisions;
  final bool editable, finalised, busy;
  final void Function(String studentId, String status) onChanged;
  final VoidCallback onApproveAllMatched;
  final void Function(Json row) onCorrect;

  @override
  State<AttendanceReviewTable> createState() => _AttendanceReviewTableState();
}

class _AttendanceReviewTableState extends State<AttendanceReviewTable> {
  String _search = '';
  bool _remainingOnly = false;

  String? _mark(Json row) {
    final status = finalStatus(
      widget.decisions[row['student_id']] ?? row['status'] as String?,
    );
    return finalStatuses.contains(status) ? status : null;
  }

  @override
  Widget build(BuildContext context) {
    final rows =
        widget.rows.where((row) {
          final name = '${row['official_name']} ${row['enrollment_number']}';
          return (!_remainingOnly || _mark(row) == null) &&
              name.toLowerCase().contains(_search);
        }).toList()..sort(
          (a, b) => '${a['official_name']}'.compareTo('${b['official_name']}'),
        );
    final matched = widget.rows
        .where(
          (row) => row['status'] == 'proposed_present' && _mark(row) == null,
        )
        .length;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.finalised ? 'Published attendance' : 'Review attendance',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (widget.editable)
            const Text(
              'Choose Present or Absent for each student. Check the suggested marks before publishing.',
            ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (text) =>
                setState(() => _search = text.trim().toLowerCase()),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search name or enrolment',
            ),
          ),
          if (widget.editable)
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: const Text('Still to review'),
                  selected: _remainingOnly,
                  onSelected: (value) => setState(() => _remainingOnly = value),
                ),
                if (matched > 0)
                  TextButton.icon(
                    onPressed: widget.busy ? null : widget.onApproveAllMatched,
                    icon: const Icon(Icons.done_all),
                    label: Text('Confirm suggested Present ($matched)'),
                  ),
              ],
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No students match.'),
            ),
          for (final row in rows) ...[
            const Divider(),
            _studentRow(context, row),
          ],
        ],
      ),
    );
  }

  Widget _studentRow(BuildContext context, Json row) {
    final mark = _mark(row);
    final id = row['student_id'] as String;
    final name = row['official_name'] as String? ?? 'Student';
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: Theme.of(context).textTheme.titleSmall),
        if (row['enrollment_number'] case final String number) Text(number),
        if (widget.editable &&
            mark == null &&
            row['status'] == 'proposed_present')
          const Text('Suggested Present'),
      ],
    );
    final controls = widget.editable
        ? Wrap(
            spacing: 8,
            children: [
              for (final status in finalStatuses)
                ChoiceChip(
                  label: Text(attendanceLabel(status)),
                  selected: mark == status,
                  onSelected: widget.busy
                      ? null
                      : (_) => widget.onChanged(id, status),
                ),
            ],
          )
        : Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (mark != null) StatusBadge(mark),
              if (widget.finalised)
                TextButton(
                  onPressed: widget.busy ? null : () => widget.onCorrect(row),
                  child: const Text('Correct'),
                ),
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, box) =>
            box.maxWidth < 520 * MediaQuery.textScalerOf(context).scale(1)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [details, controls],
              )
            : Row(
                children: [
                  Expanded(child: details),
                  controls,
                ],
              ),
      ),
    );
  }
}

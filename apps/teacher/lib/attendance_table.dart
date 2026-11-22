import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Plain-language reason a student was not matched, from the worker's diagnostics.
/// Null when there is nothing useful to say (recognised, or an older result).
String? recognitionNote(Json row) {
  if (row['assessment_code'] == 'template_ineligible') {
    return 'No approved face enrolment, so mark this student by hand.';
  }
  final summary = row['evidence_summary'];
  final reason = summary is Map ? summary['reason'] : null;
  return switch (reason) {
    'not_seen' =>
      'Not seen clearly enough. Record this student closer, facing the camera.',
    'seen_too_briefly' =>
      'Seen only briefly. Pause on this student for about 3 seconds.',
    'weak_match' =>
      'A face was seen but did not match well. Check lighting and angle.',
    'look_alike' =>
      'Looks similar to another student, so it was left for you to confirm.',
    _ => null,
  };
}

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

/// The views of the review table. "Suggested" means the mark the recognition
/// result starts from (see [draftScanDecisions]); "edited" means the teacher
/// changed a mark away from where it started.
enum ReviewFilter { all, suggestedPresent, suggestedAbsent, unmarked, edited }

extension ReviewFilterLabel on ReviewFilter {
  String get label => switch (this) {
    ReviewFilter.all => 'All',
    ReviewFilter.suggestedPresent => 'Suggested present',
    ReviewFilter.suggestedAbsent => 'Suggested absent',
    ReviewFilter.unmarked => 'Still to review',
    ReviewFilter.edited => 'Edited',
  };
}

/// The Present/Absent mark a row currently has, or null while unmarked.
/// A pending decision wins over the stored status.
String? reviewMark(Json row, Map<String, String> decisions) {
  final status = finalStatus(
    decisions[row['student_id']] ?? row['status'] as String?,
  );
  return finalStatuses.contains(status) ? status : null;
}

/// The mark a row starts from: the scan prefill if there is one, otherwise a
/// mark already stored by an earlier save.
String? reviewBaseline(Json row, Map<String, String> prefill) {
  final prefilled = prefill[row['student_id']];
  if (prefilled != null) return prefilled;
  final stored = row['status'];
  return finalStatuses.contains(stored) ? stored as String : null;
}

/// A pending decision that differs from where the row started. A prefilled
/// scan result alone is not an edit.
bool reviewEdited(
  Json row,
  Map<String, String> decisions,
  Map<String, String> prefill,
) {
  final decided = decisions[row['student_id']];
  if (decided == null) return false;
  return finalStatus(decided) != reviewBaseline(row, prefill);
}

/// Whether [row] belongs under [filter].
bool matchesReviewFilter(
  ReviewFilter filter,
  Json row,
  Map<String, String> decisions,
  Map<String, String> prefill,
) => switch (filter) {
  ReviewFilter.all => true,
  ReviewFilter.suggestedPresent => prefill[row['student_id']] == 'present',
  ReviewFilter.suggestedAbsent => prefill[row['student_id']] == 'absent',
  ReviewFilter.unmarked => reviewMark(row, decisions) == null,
  ReviewFilter.edited => reviewEdited(row, decisions, prefill),
};

/// Row counts for every filter plus the mark totals.
class ReviewCounts {
  ReviewCounts(
    List<Json> rows,
    Map<String, String> decisions,
    Map<String, String> prefill,
  ) {
    total = rows.length;
    for (final row in rows) {
      for (final f in ReviewFilter.values) {
        if (matchesReviewFilter(f, row, decisions, prefill)) {
          byFilter[f] = (byFilter[f] ?? 0) + 1;
        }
      }
      switch (reviewMark(row, decisions)) {
        case 'present':
          present++;
        case 'absent':
          absent++;
      }
    }
  }
  late final int total;
  final Map<ReviewFilter, int> byFilter = {};
  int present = 0, absent = 0;
  int of(ReviewFilter f) => byFilter[f] ?? 0;
  int get marked => present + absent;
  int get remaining => total - marked;
  bool get ready => total > 0 && marked == total;
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
  ReviewFilter _filter = ReviewFilter.all;

  String? _mark(Json row) => reviewMark(row, widget.decisions);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefill = draftScanDecisions(widget.rows);
    final counts = ReviewCounts(widget.rows, widget.decisions, prefill);
    final filter = widget.editable ? _filter : ReviewFilter.all;
    final rows =
        widget.rows.where((row) {
          final name = '${row['official_name']} ${row['enrollment_number']}';
          return matchesReviewFilter(filter, row, widget.decisions, prefill) &&
              name.toLowerCase().contains(_search);
        }).toList()..sort(
          (a, b) => '${a['official_name']}'.compareTo('${b['official_name']}'),
        );
    final matched = widget.rows
        .where(
          (row) => row['status'] == 'proposed_present' && _mark(row) == null,
        )
        .length;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpace.md),
        TextField(
          onChanged: (text) =>
              setState(() => _search = text.trim().toLowerCase()),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'Search name or enrolment',
          ),
        ),
        if (widget.editable) ...[
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final f in ReviewFilter.values)
                FilterChip(
                  key: ValueKey('filter-${f.name}'),
                  showCheckmark: false,
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(f.label)),
                      const SizedBox(width: 6),
                      Text(
                        '${counts.of(f)}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (matched > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.busy ? null : widget.onApproveAllMatched,
                icon: const Icon(Icons.done_all),
                label: Text('Confirm suggested Present ($matched)'),
              ),
            ),
        ],
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: EmptyState(
              icon: Icons.search_off_outlined,
              title: 'No students match.',
              message: 'Try a different search or choose another filter.',
              compact: true,
            ),
          ),
        for (final row in rows) ...[
          const Divider(),
          _studentRow(context, row, prefill),
        ],
      ],
    );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.finalised ? 'Published attendance' : 'Review attendance',
          style: theme.textTheme.titleLarge,
        ),
        if (widget.editable) ...[
          const SizedBox(height: 4),
          Text(
            'Choose Present or Absent for each student. Check the suggested marks before publishing.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ] else if (counts.marked > 0) ...[
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              TonePill('Present ${counts.present}', tone: AppTone.success),
              TonePill('Absent ${counts.absent}', tone: AppTone.danger),
            ],
          ),
        ],
      ],
    );
    return Panel(
      padding: compact ? 16 : 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          if (widget.editable)
            _StickySection(
              position: Scrollable.maybeOf(context)?.position,
              header: _ReviewProgress(counts: counts),
              body: body,
            )
          else
            body,
        ],
      ),
    );
  }

  /// A short, plain statement of what the recognition result says about this
  /// student, from the data the API returns. Null when it says nothing.
  String? _hint(Json row) {
    if (row['status'] == 'proposed_present') {
      return 'Recognised in the recording.';
    }
    final note = recognitionNote(row);
    if (note != null) return note;
    return switch (row['assessment_code']) {
      'limited_capture' => 'The recording was too poor to assess this student.',
      'not_recognized' => 'Not matched in the recording.',
      _ => null,
    };
  }

  Widget _studentRow(
    BuildContext context,
    Json row,
    Map<String, String> prefill,
  ) {
    final theme = Theme.of(context);
    final mark = _mark(row);
    final id = row['student_id'] as String;
    final name = row['official_name'] as String? ?? 'Student';
    final edited =
        widget.editable && reviewEdited(row, widget.decisions, prefill);
    final hint = widget.editable ? _hint(row) : null;
    final stripe = switch (mark) {
      'present' => AppTone.success,
      'absent' => AppTone.danger,
      _ => theme.colorScheme.outlineVariant,
    };
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: theme.textTheme.titleSmall),
        if (row['enrollment_number'] case final String number) Text(number),
        if (widget.editable)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                if (row['status'] == 'proposed_present')
                  const TonePill(
                    'Suggested Present',
                    tone: AppTone.success,
                    icon: Icons.check_circle_outline,
                  )
                else if (row['status'] == 'proposed_absent')
                  const TonePill(
                    'Suggested Absent',
                    tone: AppTone.danger,
                    icon: Icons.remove_circle_outline,
                  ),
                if (row['assessment_code'] == 'template_ineligible')
                  const TonePill(
                    'No face enrolment',
                    tone: AppTone.warning,
                    icon: Icons.face_retouching_off,
                  ),
                if (mark == null)
                  const TonePill(
                    'Not marked yet',
                    icon: Icons.radio_button_unchecked,
                  ),
                if (edited)
                  const TonePill(
                    'Edited',
                    tone: AppTone.info,
                    icon: Icons.edit_outlined,
                  ),
              ],
            ),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hint,
              key: row['status'] == 'proposed_present'
                  ? ValueKey('hint-$id')
                  : ValueKey('why-$id'),
              style: theme.textTheme.bodySmall,
            ),
          ),
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.only(left: AppSpace.md, top: 6, bottom: 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: stripe, width: 4)),
      ),
      child: LayoutBuilder(
        builder: (context, box) =>
            box.maxWidth < 520 * MediaQuery.textScalerOf(context).scale(1)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  details,
                  const SizedBox(height: AppSpace.sm),
                  controls,
                ],
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

/// How much of the roster has a Present or Absent mark so far, and whether it
/// can be published. The decision bar below the page pins the same counts;
/// this header stays at the top of the table while its rows are scrolled.
class _ReviewProgress extends StatelessWidget {
  const _ReviewProgress({required this.counts});
  final ReviewCounts counts;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = counts.ready;
    final marked = counts.marked, total = counts.total;
    return Container(
      padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Semantics(
        label: '$marked of $total students marked',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                done
                    ? 'All $total students marked. Ready to publish.'
                    : '$marked of $total students marked',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              TrackBar(
                value: total == 0 ? 0 : marked / total,
                color: done ? AppTone.success : null,
                height: 8,
              ),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  TonePill('Present ${counts.present}', tone: AppTone.success),
                  TonePill('Absent ${counts.absent}', tone: AppTone.danger),
                  if (!done && total > 0)
                    TonePill(
                      '${counts.remaining} left to mark',
                      tone: AppTone.warning,
                      icon: Icons.pending_outlined,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Sticky header ---------------------------------------------------------------

enum _Slot { header, body }

/// Lays out [header] above [body] and keeps the header at the top of the
/// enclosing vertical scroll view while the body scrolls beneath it, stopping
/// at the bottom of the section. Layout, semantics order and tab order are
/// unchanged; only the header's paint and hit-test position follow the scroll.
/// Without a scroll view it simply lays out normally.
class _StickySection
    extends SlottedMultiChildRenderObjectWidget<_Slot, RenderBox> {
  const _StickySection({
    required this.header,
    required this.body,
    required this.position,
  });
  final Widget header, body;
  final ScrollPosition? position;

  @override
  Iterable<_Slot> get slots => _Slot.values;

  @override
  Widget? childForSlot(_Slot slot) => switch (slot) {
    _Slot.header => header,
    _Slot.body => body,
  };

  @override
  SlottedContainerRenderObjectMixin<_Slot, RenderBox> createRenderObject(
    BuildContext context,
  ) => _RenderStickySection(position);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderStickySection renderObject,
  ) => renderObject.position = position;
}

class _RenderStickySection extends RenderBox
    with SlottedContainerRenderObjectMixin<_Slot, RenderBox> {
  _RenderStickySection(this._position);

  ScrollPosition? _position;
  set position(ScrollPosition? value) {
    if (identical(value, _position)) return;
    if (attached) _position?.removeListener(_onScroll);
    _position = value;
    if (attached) _position?.addListener(_onScroll);
    markNeedsPaint();
  }

  void _onScroll() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position?.addListener(_onScroll);
  }

  @override
  void detach() {
    _position?.removeListener(_onScroll);
    super.detach();
  }

  RenderBox get _header => childForSlot(_Slot.header)!;
  RenderBox get _body => childForSlot(_Slot.body)!;

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _header.getMinIntrinsicWidth(height),
    _body.getMinIntrinsicWidth(height),
  );
  @override
  double computeMaxIntrinsicWidth(double height) => math.max(
    _header.getMaxIntrinsicWidth(height),
    _body.getMaxIntrinsicWidth(height),
  );
  @override
  double computeMinIntrinsicHeight(double width) =>
      _header.getMinIntrinsicHeight(width) + _body.getMinIntrinsicHeight(width);
  @override
  double computeMaxIntrinsicHeight(double width) =>
      _header.getMaxIntrinsicHeight(width) + _body.getMaxIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = BoxConstraints(
      minWidth: constraints.maxWidth,
      maxWidth: constraints.maxWidth,
    );
    return constraints.constrain(
      Size(
        constraints.maxWidth,
        _header.getDryLayout(c).height + _body.getDryLayout(c).height,
      ),
    );
  }

  @override
  void performLayout() {
    final c = BoxConstraints(
      minWidth: constraints.maxWidth,
      maxWidth: constraints.maxWidth,
    );
    _header.layout(c, parentUsesSize: true);
    _body.layout(c, parentUsesSize: true);
    (_header.parentData! as BoxParentData).offset = Offset.zero;
    (_body.parentData! as BoxParentData).offset = Offset(0, _header.size.height);
    size = constraints.constrain(
      Size(constraints.maxWidth, _header.size.height + _body.size.height),
    );
  }

  /// How far the header is pushed down from its natural top so that it sits
  /// at the top of the scroll viewport.
  double get _stickyOffset {
    final position = _position;
    if (position == null || !hasSize || position.axis != Axis.vertical) {
      return 0;
    }
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport == null) return 0;
    final top = localToGlobal(Offset.zero, ancestor: viewport as RenderObject).dy;
    final room = math.max(0.0, size.height - _header.size.height);
    return (-top).clamp(0.0, room);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final bodyOffset = (_body.parentData! as BoxParentData).offset;
    context.paintChild(_body, offset + bodyOffset);
    context.paintChild(_header, offset + Offset(0, _stickyOffset));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final dy = _stickyOffset;
    final onHeader = result.addWithPaintOffset(
      offset: Offset(0, dy),
      position: position,
      hitTest: (result, transformed) =>
          _header.hitTest(result, position: transformed),
    );
    if (onHeader) return true;
    return result.addWithPaintOffset(
      offset: (_body.parentData! as BoxParentData).offset,
      position: position,
      hitTest: (result, transformed) =>
          _body.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final dy = identical(child, _header)
        ? _stickyOffset
        : (child.parentData! as BoxParentData).offset.dy;
    transform.translateByDouble(0, dy, 0, 1);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_header);
    visitor(_body);
  }
}

import 'package:facetrack_models/facetrack_models.dart';
import 'package:flutter/material.dart';

import 'attendance_table.dart';
import 'processing_progress.dart';

/// How far the server's recognition has got for one student.
///
/// Green exists only for a student the server recognised and corroborated across separate
/// moments. Detecting a face on the phone never produces any of these states.
enum RecognitionState {
  recognized,
  checking,
  uncertain,
  notMatched,
  waiting,
  noEnrolment,
}

class RecognitionSnapshot {
  const RecognitionSnapshot(
    this.rows, {
    this.processing = false,
    this.info = const ProcessingInfo(),
  });
  final List<Json> rows;

  /// Where recognition is up to: stage, segment counts, and whether a worker is running.
  final ProcessingInfo info;

  /// A segment is uploading or being processed, so current results may still change.
  final bool processing;
}

class BoardEntry {
  const BoardEntry({
    required this.id,
    required this.name,
    required this.state,
    this.number,
    this.note,
  });
  final String id, name;
  final String? number, note;
  final RecognitionState state;
}

const _unsure = {'seen_too_briefly', 'weak_match', 'look_alike'};

RecognitionState recognitionStateOf(Json row, {required bool processing}) {
  if (row['assessment_code'] == 'template_ineligible') {
    return RecognitionState.noEnrolment;
  }
  if (row['assessment_code'] == 'recognized' &&
      const {'proposed_present', 'present'}.contains(row['status'])) {
    return RecognitionState.recognized;
  }
  // Anything not yet recognised may still change while a segment is in flight.
  if (processing) return RecognitionState.checking;
  final summary = row['evidence_summary'];
  if (summary is Map && _unsure.contains(summary['reason'])) {
    return RecognitionState.uncertain;
  }
  if (row['assessment_code'] == 'not_recognized') {
    return RecognitionState.notMatched;
  }
  return RecognitionState.waiting;
}

String? boardNote(Json row, RecognitionState state) => switch (state) {
  RecognitionState.recognized => null,
  RecognitionState.checking => 'Checking the latest recording…',
  RecognitionState.waiting =>
    row['assessment_code'] == 'limited_capture'
        ? 'The recording was too poor to assess this student.'
        : 'Not covered by a processed recording yet.',
  _ => recognitionNote(row),
};

/// Roster order is kept; the widget sorts for display.
List<BoardEntry> boardEntries(List<Json> rows, {required bool processing}) => [
  for (final row in rows)
    BoardEntry(
      id: row['student_id'] as String,
      name: row['official_name'] as String? ?? 'Student',
      number: row['enrollment_number'] as String?,
      state: recognitionStateOf(row, processing: processing),
      note: boardNote(row, recognitionStateOf(row, processing: processing)),
    ),
];

extension RecognitionStyle on RecognitionState {
  /// Readable on a light background (the finish screen); [color] is for the dark camera view.
  Color get colorOnLight => switch (this) {
    RecognitionState.recognized => Colors.green.shade700,
    RecognitionState.checking || RecognitionState.uncertain => Colors.amber.shade900,
    RecognitionState.notMatched => Colors.red.shade700,
    RecognitionState.waiting ||
    RecognitionState.noEnrolment => Colors.grey.shade600,
  };
  Color get color => switch (this) {
    RecognitionState.recognized => Colors.greenAccent,
    RecognitionState.checking || RecognitionState.uncertain => Colors.amber,
    RecognitionState.notMatched => Colors.redAccent,
    RecognitionState.waiting ||
    RecognitionState.noEnrolment => const Color(0xFFB4BBC6),
  };
  IconData get icon => switch (this) {
    RecognitionState.recognized => Icons.check_circle,
    RecognitionState.checking => Icons.hourglass_top,
    RecognitionState.uncertain => Icons.help,
    RecognitionState.notMatched => Icons.cancel,
    RecognitionState.waiting => Icons.radio_button_unchecked,
    RecognitionState.noEnrolment => Icons.person_off_outlined,
  };
  String get label => switch (this) {
    RecognitionState.recognized => 'Recognised',
    RecognitionState.checking => 'Checking',
    RecognitionState.uncertain => 'Not sure',
    RecognitionState.notMatched => 'Not matched',
    RecognitionState.waiting => 'Not covered yet',
    RecognitionState.noEnrolment => 'No face enrolment',
  };
  // Problems first, so the teacher sees who still needs another pass.
  int get order => switch (this) {
    RecognitionState.notMatched => 0,
    RecognitionState.uncertain => 1,
    RecognitionState.checking => 2,
    RecognitionState.waiting => 3,
    RecognitionState.noEnrolment => 4,
    RecognitionState.recognized => 5,
  };
}

/// Live recognition results for the whole roster, on a dark camera background.
class RecognitionBoard extends StatelessWidget {
  const RecognitionBoard({
    super.key,
    required this.entries,
    this.maxHeight = 200,
    this.onDark = true,
    this.query = '',
    this.attentionOnly = false,
  });
  final List<BoardEntry> entries;
  final double maxHeight;
  final bool onDark;

  /// Narrows the list (not the summary above it) to names or numbers containing this text.
  final String query;

  /// Hides recognised students, leaving the ones who still need another pass.
  final bool attentionOnly;

  Color _tone(RecognitionState s) => onDark ? s.color : s.colorOnLight;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final counts = {for (final s in RecognitionState.values) s: 0};
    for (final e in entries) {
      counts[e.state] = counts[e.state]! + 1;
    }
    final recognised = counts[RecognitionState.recognized]!;
    final needle = query.trim().toLowerCase();
    final sorted = [
      for (final e in entries)
        if ((!attentionOnly || e.state != RecognitionState.recognized) &&
            (needle.isEmpty || '${e.name} ${e.number ?? ''}'.toLowerCase().contains(needle)))
          e,
    ]..sort((a, b) {
        final byState = a.state.order.compareTo(b.state.order);
        return byState != 0 ? byState : a.name.compareTo(b.name);
      });
    return Column(
      key: const ValueKey('recognition-board'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$recognised of ${entries.length} recognised',
          key: const ValueKey('board-summary'),
          style: TextStyle(
            color: onDark ? Colors.white : Colors.black87,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            key: const ValueKey('board-bar'),
            value: recognised / entries.length,
            minHeight: 6,
            color: _tone(RecognitionState.recognized),
            backgroundColor: onDark ? Colors.white24 : Colors.black12,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final s in RecognitionState.values)
              if (counts[s]! > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(s.icon, size: 14, color: _tone(s)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                      '${counts[s]} ${s.label.toLowerCase()}',
                      style: TextStyle(
                        color: onDark ? Colors.white70 : Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                    ),
                  ],
                ),
          ],
        ),
        const SizedBox(height: 6),
        if (sorted.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No students match.',
              key: const ValueKey('board-empty'),
              style: TextStyle(color: onDark ? Colors.white70 : Colors.black54),
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: sorted.length,
            itemBuilder: (context, i) {
              final e = sorted[i];
              return Semantics(
                label: '${e.name}, ${e.state.label}',
                child: Padding(
                  key: ValueKey('board-${e.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(e.state.icon, size: 18, color: _tone(e.state)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.number == null ? e.name : '${e.name} · ${e.number}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: e.state == RecognitionState.recognized
                                    ? _tone(e.state)
                                    : (onDark ? Colors.white : Colors.black87),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (e.note != null)
                              Text(
                                e.note!,
                                style: TextStyle(
                                  color: onDark ? Colors.white60 : Colors.black54,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

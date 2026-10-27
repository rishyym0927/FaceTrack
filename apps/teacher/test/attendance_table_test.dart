import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/attendance_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json student(String id, String name, String enrol, String status) => {
  'student_id': id,
  'official_name': name,
  'enrollment_number': enrol,
  'status': status,
  'recognition_eligible': true,
};

/// Host that mimics the parent: holds pending decisions and applies the same
/// approve-all-matched rule the real screen uses.
class _Host extends StatefulWidget {
  const _Host(this.rows, {this.editable = true});
  final List<Json> rows;
  final bool editable;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final decisions = <String, String>{};
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AttendanceReviewTable(
          rows: widget.rows,
          decisions: decisions,
          editable: widget.editable,
          finalised: false,
          busy: false,
          sessionLabel: 'Ready for review',
          onChanged: (id, status) => setState(() => decisions[id] = status),
          onApproveAllMatched: () => setState(() {
            for (final r in widget.rows) {
              final v = decisions[r['student_id']] ?? r['status'];
              if (v == 'proposed_present') decisions[r['student_id']] = 'present';
            }
          }),
          onCorrect: (_) {},
        ),
      ),
    ),
  );
}

final _rows = [
  student('a', 'Alice', 'EN001', 'proposed_present'),
  student('b', 'Bob', 'EN002', 'proposed_absent'),
  student('c', 'Cara', 'EN003', 'unassessed'),
];

void main() {
  setUp(() {
    // Generous surface so the whole table is laid out without scrolling.
  });

  testWidgets('Shows AI status per row and the matched count', (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows));
    await tester.pumpAndSettle();
    // Labels appear as the row AI chip, the filter chip, and (for unassessed)
    // the decision label too — assert presence, and the precise matched count.
    expect(find.text('Matched'), findsWidgets);
    expect(find.text('Not recognized'), findsWidgets);
    expect(find.text('Unassessed'), findsWidgets);
    expect(find.textContaining('Approve all matched (1)'), findsOneWidget);
  });

  testWidgets('Approve-all confirms only matched, never not-recognized/unassessed',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Approve all matched'));
    await tester.pumpAndSettle();
    // Exactly one student (Alice, matched) is now approved present.
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    // The other two keep an unselected approve control (not auto-approved).
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(2));
    expect(find.textContaining('All matched approved'), findsOneWidget);
  });

  testWidgets('Individual disapprove marks one student absent', (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cancel), findsNothing);
    await tester.tap(find.byTooltip('Disapprove (absent)').first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cancel), findsOneWidget);
  });

  testWidgets('Filter shows only the chosen AI status', (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Not recognized'));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    expect(find.text('Cara'), findsNothing);
  });

  testWidgets('Search filters by enrolment number', (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'EN003');
    await tester.pumpAndSettle();
    expect(find.text('Cara'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    expect(find.text('Bob'), findsNothing);
  });

  testWidgets('Non-editable view shows no approve/disapprove controls',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows, editable: false));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Approve (present)'), findsNothing);
    expect(find.textContaining('Approve all matched'), findsNothing);
  });

  test('Review starts with only not-recognized students as Absent', () {
    final rows = [
      ..._rows,
      student('d', 'Dev', 'EN004', 'proposed_absent'),
      student('e', 'Esha', 'EN005', 'present'),
    ];
    expect(draftAbsentDecisions(rows), {'b': 'absent', 'd': 'absent'});
    expect(draftAbsentDecisions(const []), isEmpty);
  });
}

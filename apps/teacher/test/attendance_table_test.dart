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
          onChanged: (id, status) => setState(() => decisions[id] = status),
          onApproveAllMatched: () => setState(() {
            for (final r in widget.rows) {
              final v = decisions[r['student_id']] ?? r['status'];
              if (v == 'proposed_present') {
                decisions[r['student_id']] = 'present';
              }
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

  testWidgets('Offers only binary marks and confirms suggested Present', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(_rows));
    expect(find.text('Not recognized'), findsNothing);
    expect(find.text('Unassessed'), findsNothing);
    expect(find.text('Present'), findsNWidgets(3));
    expect(find.text('Absent'), findsNWidgets(3));
    await tester.tap(find.text('Confirm suggested Present (1)'));
    await tester.pumpAndSettle();
    final present = tester.widgetList<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Present'),
    );
    expect(present.map((chip) => chip.selected), [true, false, false]);
  });

  testWidgets('Still to review hides marked students', (tester) async {
    await tester.pumpWidget(_Host(_rows));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Absent').at(1));
    await tester.tap(find.widgetWithText(FilterChip, 'Still to review'));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Cara'), findsOneWidget);
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

  testWidgets('Non-editable view shows no approve/disapprove controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_Host(_rows, editable: false));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Present'), findsNothing);
    expect(find.textContaining('Confirm suggested Present'), findsNothing);
  });

  test('Processed scan defaults matched students to Present and all others to Absent', () {
    final rows = [
      ..._rows,
      student('d', 'Dev', 'EN004', 'proposed_absent'),
      student('e', 'Esha', 'EN005', 'present'),
    ];
    expect(draftScanDecisions(rows), {
      'a': 'present',
      'b': 'absent',
      'c': 'absent',
      'd': 'absent',
    });
    expect(draftScanDecisions(const []), isEmpty);
  });
}

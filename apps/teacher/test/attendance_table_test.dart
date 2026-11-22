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
  const _Host(this.rows, {this.editable = true, this.scale = 1});
  final List<Json> rows;
  final bool editable;
  final double scale;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final decisions = <String, String>{};
  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(widget.scale)),
      child: child!,
    ),
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

  testWidgets('Review shows how many students are marked so far', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(_rows));
    expect(find.text('0 of 3 students marked'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Present').first);
    await tester.pump();
    expect(find.text('1 of 3 students marked'), findsOneWidget);
    await tester.pumpWidget(_Host(_rows, editable: false));
    expect(find.textContaining('students marked'), findsNothing);
  });

  group('review filters', () {
    Json row(String id, String name, String status, [Map<String, dynamic>? extra]) =>
        {...student(id, name, 'EN-$id', status), ...?extra};
    final rows = [
      row('a', 'Alice', 'proposed_present', {'assessment_code': 'recognized'}),
      row('b', 'Bob', 'proposed_absent', {
        'assessment_code': 'not_recognized',
        'evidence_summary': {'reason': 'weak_match'},
      }),
      row('c', 'Cara', 'unassessed', {'assessment_code': 'template_ineligible'}),
      row('d', 'Dev', 'present'), // already saved as Present
    ];

    test('the prefill is the baseline, so only real changes count as edits', () {
      final prefill = draftScanDecisions(rows);
      expect(prefill, {'a': 'present', 'b': 'absent', 'c': 'absent'});
      // An untouched prefill is not an edit.
      expect(reviewEdited(rows[0], {...prefill}, prefill), isFalse);
      expect(reviewEdited(rows[0], {...prefill, 'a': 'absent'}, prefill), isTrue);
      // A stored mark is its own baseline; changing it is an edit.
      expect(reviewEdited(rows[3], {'d': 'present'}, prefill), isFalse);
      expect(reviewEdited(rows[3], {'d': 'absent'}, prefill), isTrue);
      expect(reviewEdited(rows[1], const {}, prefill), isFalse);
    });

    test('counts per filter and mark totals', () {
      final prefill = draftScanDecisions(rows);
      var c = ReviewCounts(rows, const {}, prefill);
      expect(c.of(ReviewFilter.all), 4);
      expect(c.of(ReviewFilter.suggestedPresent), 1);
      expect(c.of(ReviewFilter.suggestedAbsent), 2);
      expect(c.of(ReviewFilter.unmarked), 3); // only Dev has a mark
      expect(c.of(ReviewFilter.edited), 0);
      expect((c.present, c.absent, c.marked, c.remaining), (1, 0, 1, 3));
      expect(c.ready, isFalse);
      c = ReviewCounts(rows, {...prefill, 'a': 'absent'}, prefill);
      expect(c.of(ReviewFilter.unmarked), 0);
      expect(c.of(ReviewFilter.edited), 1);
      expect((c.present, c.absent), (1, 3));
      expect(c.ready, isTrue);
    });

    test('a legacy late mark reads as Present', () {
      expect(reviewMark(row('x', 'X', 'late'), const {}), 'present');
      expect(reviewMark(row('x', 'X', 'excused'), const {}), isNull);
      expect(reviewMark(row('x', 'X', 'proposed_present'), const {}), isNull);
    });

    testWidgets('Chips show counts and each one narrows the list', (tester) async {
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_Host(rows));
      await tester.pumpAndSettle();
      Finder chip(ReviewFilter f) => find.byKey(ValueKey('filter-${f.name}'));
      expect(find.descendant(of: chip(ReviewFilter.suggestedAbsent), matching: find.text('2')), findsOneWidget);
      await tester.tap(chip(ReviewFilter.suggestedAbsent));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Cara'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
      await tester.tap(chip(ReviewFilter.suggestedPresent));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsNothing);
      // Edit Alice (suggested Present) to Absent: she is now "Edited".
      await tester.tap(find.widgetWithText(ChoiceChip, 'Absent'));
      await tester.pumpAndSettle();
      await tester.tap(chip(ReviewFilter.edited));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Dev'), findsNothing);
      expect(find.text('Edited'), findsWidgets);
      await tester.tap(chip(ReviewFilter.all));
      await tester.pumpAndSettle();
      expect(find.text('Dev'), findsOneWidget);
    });

    testWidgets('Rows explain the recognition result in plain words', (tester) async {
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_Host(rows));
      await tester.pumpAndSettle();
      expect(find.text('Recognised in the recording.'), findsOneWidget);
      expect(find.byKey(const ValueKey('why-b')), findsOneWidget);
      expect(find.textContaining('did not match well'), findsOneWidget);
      expect(find.textContaining('No approved face enrolment'), findsOneWidget);
      expect(find.text('Suggested Present'), findsOneWidget);
      expect(find.text('Suggested Absent'), findsOneWidget);
      expect(find.text('Not marked yet'), findsNWidgets(3));
    });

    testWidgets('Progress shows readiness: left to mark, then ready to publish', (tester) async {
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_Host(rows.take(2).toList()));
      await tester.pumpAndSettle();
      expect(find.text('0 of 2 students marked'), findsOneWidget);
      expect(find.text('2 left to mark'), findsOneWidget);
      await tester.tap(find.text('Confirm suggested Present (1)'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Absent').last);
      await tester.pumpAndSettle();
      expect(find.text('All 2 students marked. Ready to publish.'), findsOneWidget);
      expect(find.textContaining('left to mark'), findsNothing);
      expect(find.text('Present 1'), findsOneWidget);
      expect(find.text('Absent 1'), findsOneWidget);
    });

    for (final (size, scale) in [
      (const Size(320, 700), 1.0),
      (const Size(320, 700), 2.0),
      (const Size(390, 844), 2.0),
      (const Size(844, 390), 1.0),
      (const Size(1440, 900), 2.0),
    ]) {
      testWidgets('Table fits at ${size.width}x${size.height}, text x$scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_Host(rows, scale: scale));
        await tester.pumpAndSettle();
        expect(find.text('Review attendance'), findsOneWidget);
        expect(find.byKey(const ValueKey('filter-edited')), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Published view shows mark totals, no filters or progress', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_Host([
        row('a', 'Alice', 'present'),
        row('b', 'Bob', 'absent'),
      ], editable: false));
      await tester.pumpAndSettle();
      expect(find.text('Present 1'), findsOneWidget);
      expect(find.text('Absent 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('filter-all')), findsNothing);
      expect(find.textContaining('students marked'), findsNothing);
    });

    testWidgets('The progress header stays at the top of the viewport while rows scroll', (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final many = [
        for (var i = 0; i < 40; i++)
          row('s$i', 'Student ${i.toString().padLeft(2, '0')}', 'unassessed'),
      ];
      await tester.pumpWidget(_Host(many));
      await tester.pumpAndSettle();
      final header = find.text('0 of 40 students marked');
      final before = tester.getTopLeft(header).dy;
      expect(before, greaterThan(40));
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      // The first rows have scrolled out, yet the progress is still visible.
      expect(tester.getTopLeft(find.text('Student 00')).dy, lessThan(0));
      final after = tester.getTopLeft(header).dy;
      expect(after, lessThan(30));
      expect(after, greaterThanOrEqualTo(0));
      // Back at the top it returns to its natural place.
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 3000));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header).dy, closeTo(before, .5));
    });
  });
}

import 'package:facetrack_teacher/recognition_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(
  String id, {
  String status = 'unassessed',
  String? code,
  Map<String, dynamic>? evidence,
  String? name,
}) => {
  'student_id': id,
  'official_name': name ?? 'Student $id',
  'enrollment_number': 'E$id',
  'status': status,
  'assessment_code': code,
  'evidence_summary': evidence ?? <String, dynamic>{},
};

RecognitionState stateOf(Map<String, dynamic> r, {bool processing = false}) =>
    recognitionStateOf(r, processing: processing);

void main() {
  group('colour rules', () {
    test('only a corroborated server match is recognised (green)', () {
      expect(
        stateOf(row('1', status: 'proposed_present', code: 'recognized')),
        RecognitionState.recognized,
      );
      expect(RecognitionState.recognized.color, Colors.greenAccent);
    });
    test('nothing else can be green, whatever the row says', () {
      final others = <Map<String, dynamic>>[
        row('a'),
        row('b', code: 'not_recognized', status: 'proposed_absent'),
        row('c', code: 'limited_capture'),
        row('d', code: 'template_ineligible'),
        // Present by a hand mark but never recognised by the server.
        row('e', status: 'present'),
        // The server saw a face but was unsure.
        row('f',
            code: 'not_recognized',
            status: 'proposed_absent',
            evidence: {'reason': 'weak_match'}),
      ];
      for (final r in others) {
        for (final processing in [false, true]) {
          final s = stateOf(r, processing: processing);
          expect(s, isNot(RecognitionState.recognized), reason: '$r');
          expect(s.color, isNot(Colors.greenAccent));
        }
      }
    });
    test('a recognised student stays green while another segment is processing', () {
      expect(
        stateOf(row('1', status: 'proposed_present', code: 'recognized'),
            processing: true),
        RecognitionState.recognized,
      );
    });
    test('unmatched students are yellow while processing and red once settled', () {
      final r = row('2', code: 'not_recognized', status: 'proposed_absent');
      expect(stateOf(r, processing: true), RecognitionState.checking);
      expect(stateOf(r), RecognitionState.notMatched);
      expect(RecognitionState.checking.color, Colors.amber);
      expect(RecognitionState.notMatched.color, Colors.redAccent);
    });
    test('uncertain reasons are yellow, not red', () {
      for (final reason in ['seen_too_briefly', 'weak_match', 'look_alike']) {
        final r = row('3',
            code: 'not_recognized',
            status: 'proposed_absent',
            evidence: {'reason': reason});
        expect(stateOf(r), RecognitionState.uncertain, reason: reason);
      }
      expect(RecognitionState.uncertain.color, Colors.amber);
    });
    test('not seen, with no processing, is red; an older result without a reason too', () {
      expect(
        stateOf(row('4',
            code: 'not_recognized',
            status: 'proposed_absent',
            evidence: {'reason': 'not_seen'})),
        RecognitionState.notMatched,
      );
      expect(
        stateOf(row('5', code: 'not_recognized', status: 'proposed_absent')),
        RecognitionState.notMatched,
      );
    });
    test('students not yet covered, or without enrolment, are grey', () {
      expect(stateOf(row('6')), RecognitionState.waiting);
      expect(stateOf(row('7', code: 'limited_capture')), RecognitionState.waiting);
      expect(stateOf(row('8', code: 'template_ineligible')),
          RecognitionState.noEnrolment);
      // Enrolment problems do not become "checking" just because a clip is in flight.
      expect(stateOf(row('8', code: 'template_ineligible'), processing: true),
          RecognitionState.noEnrolment);
    });
  });

  group('board widget', () {
    Future<void> show(WidgetTester tester, List<BoardEntry> entries) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: SingleChildScrollView(child: RecognitionBoard(entries: entries)),
            ),
          ),
        );

    testWidgets('shows the count, the name and a reason per student', (tester) async {
      final rows = [
        row('1', status: 'proposed_present', code: 'recognized', name: 'Asha Rao'),
        row('2',
            code: 'not_recognized',
            status: 'proposed_absent',
            evidence: {'reason': 'not_seen'},
            name: 'Ben Cole'),
        row('3', name: 'Chitra Das'),
      ];
      await show(tester, boardEntries(rows, processing: false));
      expect(find.text('1 of 3 recognised'), findsOneWidget);
      expect(find.textContaining('Asha Rao'), findsOneWidget);
      expect(find.textContaining('closer'), findsOneWidget); // Ben's reason
      expect(find.textContaining('Not covered'), findsOneWidget); // Chitra
    });

    testWidgets('only the recognised student gets the green icon', (tester) async {
      final rows = [
        row('1', status: 'proposed_present', code: 'recognized'),
        row('2', code: 'not_recognized', status: 'proposed_absent'),
        row('3'),
        row('4', code: 'template_ineligible'),
      ];
      await show(tester, boardEntries(rows, processing: false));
      final greens = tester
          .widgetList<Icon>(find.byType(Icon))
          .where((i) => i.color == Colors.greenAccent)
          .toList();
      // One list icon plus one legend icon, both for the single recognised student.
      expect(greens.length, 2);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const ValueKey('board-2')),
                matching: find.byType(Icon),
              ),
            )
            .color,
        Colors.redAccent,
      );
    });

    testWidgets('problems are listed first so the teacher sees who needs another pass', (tester) async {
      final rows = [
        row('1', status: 'proposed_present', code: 'recognized', name: 'Aaa'),
        row('2', code: 'not_recognized', status: 'proposed_absent', name: 'Zzz'),
      ];
      await show(tester, boardEntries(rows, processing: false));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('board-2'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('board-1'))).dy),
      );
    });

    testWidgets('a class of 100 stays scrollable inside a bounded height', (tester) async {
      final rows = [for (var i = 0; i < 100; i++) row('$i')];
      await show(tester, boardEntries(rows, processing: true));
      expect(find.text('0 of 100 recognised'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(ListView)).height, lessThanOrEqualTo(200));
    });

    testWidgets('an empty roster draws nothing', (tester) async {
      await show(tester, const []);
      expect(find.byKey(const ValueKey('recognition-board')), findsNothing);
    });
  });
}

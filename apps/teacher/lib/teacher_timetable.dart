import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const timetableColumns =
    'entry_key,term_code,course_code,branch,semester,section,teacher_email,room_code,weekday,start_time,end_time,effective_from,effective_until,timezone\n';

DateTime? nextTimetableDate(List rows, {DateTime? referenceDate}) {
  const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  final now = referenceDate ?? DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime? first;
  for (final item in rows) {
    final row = item as Map;
    final weekday = weekdays.indexOf(row['weekday'] as String);
    final from = DateTime.parse(row['effective_from'] as String);
    final until = DateTime.parse(row['effective_until'] as String);
    if (weekday < 0) continue;
    final start = from.isAfter(today) ? from : today;
    final offset = (weekday + 1 - start.weekday + 7) % 7;
    final candidate = start.add(Duration(days: offset));
    if (!candidate.isAfter(until) &&
        (first == null || candidate.isBefore(first))) {
      first = candidate;
    }
  }
  return first;
}

class TeacherTimetable extends StatefulWidget {
  const TeacherTimetable({
    super.key,
    required this.api,
    required this.institute,
    required this.offering,
    required this.publishableKey,
    required this.changed,
  });
  final ApiClient api;
  final String institute, offering, publishableKey;
  final VoidCallback changed;
  @override
  State<TeacherTimetable> createState() => _TeacherTimetableState();
}

class _TeacherTimetableState extends State<TeacherTimetable> {
  String? termId, importId;
  int? revision;
  Json? preview;
  String? error;
  bool busy = false;
  DateTime date = DateTime.now();
  final reserveKey = Mutation(), importKey = Mutation(), commitKey = Mutation();
  Uint8List? selected;
  String? filename;
  String? resumeUrl;
  int pollGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(prepare());
  }

  @override
  void dispose() {
    pollGeneration++;
    super.dispose();
  }

  Future<void> prepare() async {
    try {
      final offering = await widget.api.send(
        'GET',
        '/v1/offerings/${widget.offering}',
        institute: widget.institute,
      );
      final id = offering['term_id'] as String;
      final term = await widget.api.send(
        'GET',
        '/v1/terms/$id/schedule',
        institute: widget.institute,
      );
      if (!mounted) return;
      setState(() {
        termId = id;
        revision = term['schedule_revision'] as int;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> choose() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (file == null) return;
      final length = await file.length();
      if (length == null || length < 1 || length > 1048576) {
        throw const AppFailure('Choose a CSV smaller than 1 MiB.');
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        selected = bytes;
        filename = file.name;
        importId = null;
        preview = null;
        error = null;
        reserveKey.reset();
        importKey.reset();
        commitKey.reset();
        resumeUrl = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> saveTemplate() async {
    try {
      await FilePicker.saveFile(
        fileName: 'facetrack-timetable-template.csv',
        bytes: Uint8List.fromList(utf8.encode(timetableColumns)),
        mimeType: 'text/csv',
        dialogTitle: 'Save timetable template',
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> createRoom() async {
    final code = TextEditingController();
    final name = TextEditingController();
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => ActionDialog(
          title: 'Add classroom',
          button: 'Save room',
          child: Column(
            children: [
              const Text('The room code must match the CSV room_code exactly.'),
              TextField(
                controller: code,
                maxLength: 32,
                decoration: const InputDecoration(labelText: 'Room code'),
              ),
              TextField(
                controller: name,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Room name'),
              ),
            ],
          ),
          submit: (mutation) async {
            if (code.text.trim().isEmpty || name.text.trim().isEmpty) {
              throw const AppFailure('Enter both a room code and name.');
            }
            await widget.api.send(
              'POST',
              '/v1/rooms',
              institute: widget.institute,
              mutation: mutation,
              body: {'code': code.text.trim(), 'name': name.text.trim()},
            );
          },
        ),
      );
      if (saved == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Room saved. Choose the CSV again if an earlier preview was rejected.',
            ),
          ),
        );
      }
    } finally {
      code.dispose();
      name.dispose();
    }
  }

  Future<void> upload() async {
    if (selected == null || termId == null || revision == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (importId != null) {
        await poll();
        return;
      }
      final bytes = selected!;
      final asset = await widget.api.send(
        'POST',
        '/v1/media-reservations',
        institute: widget.institute,
        mutation: reserveKey,
        body: {
          'purpose': 'timetable',
          'mime_type': 'text/csv',
          'expected_bytes': bytes.length,
        },
      );
      final grant = await widget.api.send(
        'POST',
        '/v1/media-reservations/${asset['id']}/upload-grant',
        institute: widget.institute,
      );
      await ResumableUpload().upload(
        XFile.fromData(
          bytes,
          name: filename ?? 'timetable.csv',
          mimeType: 'text/csv',
        ),
        grant,
        widget.publishableKey,
        resumeUrl: resumeUrl,
        progress: (_) {},
        checkpoint: (url) async {
          resumeUrl = url;
        },
      );
      final result = await widget.api.send(
        'POST',
        '/v1/timetable-imports',
        institute: widget.institute,
        mutation: importKey,
        body: {
          'asset_id': asset['id'],
          'term_id': termId,
          'base_revision': revision,
          'byte_size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      );
      importId = result['resource_id'] as String;
      await poll();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> poll() async {
    if (importId == null) return;
    final current = ++pollGeneration;
    for (var n = 0; n < 25; n++) {
      if (!mounted || current != pollGeneration) return;
      final response = await widget.api.send(
        'GET',
        '/v1/timetable-imports/$importId',
        institute: widget.institute,
      );
      if (!mounted || current != pollGeneration) return;
      setState(() {
        preview = response;
        if (response['status'] == 'ready') {
          final rows = (response['preview_json']?['rows'] as List?) ?? const [];
          date = nextTimetableDate(rows) ?? date;
        }
      });
      if ([
        'ready',
        'rejected',
        'committed',
        'failed',
      ].contains(response['status'])) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> confirm() async {
    if (preview?['status'] != 'ready' || revision == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.send(
        'POST',
        '/v1/timetable-imports/$importId/commit',
        institute: widget.institute,
        mutation: commitKey,
        body: {
          'preview_hash': preview!['preview_hash'],
          'expected_revision': revision,
          'materialize_date': date.toIso8601String().substring(0, 10),
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Timetable confirmed. ${result['sessions_materialized']} scheduled session(s) created or updated for the selected date.',
          ),
        ),
      );
      setState(() {
        selected = null;
        importId = null;
        preview = null;
        resumeUrl = null;
        revision = revision! + 1;
      });
      widget.changed();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = (preview?['preview_json']?['rows'] as List?) ?? const [];
    final errors = (preview?['preview_json']?['errors'] as List?) ?? const [];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Timetable CSV', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: saveTemplate,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Download CSV template'),
              ),
              FilledButton.icon(
                onPressed: busy ? null : choose,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Choose CSV'),
              ),
              TextButton.icon(
                onPressed: createRoom,
                icon: const Icon(Icons.meeting_room_outlined),
                label: const Text('Add room'),
              ),
            ],
          ),
          const ExpansionTile(
            title: Text('CSV format and import help'),
            childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              Text(
                'Add the rooms used by your CSV before importing. Check the validated entries before confirming. Sessions open manually.',
              ),
              SizedBox(height: 8),
              Text(
                'Use one row per weekly period. Match the approved semester term, subject code, faculty email and room code. Leave the section column blank for a class group created without a section. Weekday is MON, TUE, WED, THU, FRI, SAT or SUN; times use HH:MM, dates use YYYY-MM-DD, timezone is Asia/Kolkata. Entry key is a stable label such as BCS201-CSE1-Mon-09.',
              ),
            ],
          ),
          if (filename != null && selected != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Selected file: $filename'),
            ),
          if (selected != null)
            FilledButton(
              onPressed: busy || termId == null ? null : upload,
              child: Text(
                busy ? 'Checking timetable…' : 'Upload for validation',
              ),
            ),
          if (preview?['status'] == 'queued')
            const Text('Waiting for validation…'),
          if (errors.isNotEmpty) ...[
            const Text(
              'Check the room code, approved subject code, section, assigned faculty and semester dates. Fix any issue, then choose and upload the CSV again:',
            ),
            for (final e in errors.take(8)) Text('• ${e['message']}'),
          ],
          if (preview?['status'] == 'ready') ...[
            const SizedBox(height: 12),
            Text(
              '${rows.length} valid timetable ${rows.length == 1 ? 'entry' : 'entries'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final row in rows.take(12))
              Text(
                '${row['course_code']} · ${row['branch']}${row['section'] == '' || row['section'] == 'ALL' ? '' : ' ${row['section']}'} · ${row['weekday']} ${row['start_time']}–${row['end_time']} · ${row['room_code']}',
              ),
            if (rows.length > 12) Text('… and ${rows.length - 12} more'),
            TextButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: date,
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  lastDate: DateTime.now().add(const Duration(days: 180)),
                );
                if (picked != null && mounted) setState(() => date = picked);
              },
              child: Text(
                'Session date: ${MaterialLocalizations.of(context).formatMediumDate(date)} · change',
              ),
            ),
            const Text(
              'This creates sessions for the selected date only. Choose a day that matches at least one CSV weekday and falls within its effective dates.',
            ),
            FilledButton(
              onPressed: busy ? null : confirm,
              child: const Text('Confirm timetable'),
            ),
          ],
          if (error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'console_api.dart';
import 'spike_capture.dart';

const _green = Color(0xff176451);

class ModelTestConsoleApp extends StatelessWidget {
  const ModelTestConsoleApp({super.key, this.backend, this.session});
  final ConsoleBackend? backend;
  final CaptureSession? session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FaceTrack · Model test',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: _green),
      scaffoldBackgroundColor: const Color(0xfff4f6f3),
    ),
    home: ModelTestConsole(backend: backend, session: session),
  );
}

class ModelTestConsole extends StatefulWidget {
  const ModelTestConsole({super.key, this.backend, this.session});
  final ConsoleBackend? backend;
  final CaptureSession? session;
  @override
  State<ModelTestConsole> createState() => _ModelTestConsoleState();
}

class _ModelTestConsoleState extends State<ModelTestConsole> {
  late final ConsoleBackend backend = widget.backend ?? HttpConsoleBackend();
  late final CaptureSession session =
      widget.session ?? CaptureSession(PluginCameraGateway());
  final name = TextEditingController();
  Map<String, dynamic>? status;
  Map<String, dynamic>? summary;
  List<Map<String, dynamic>> scenarios = [];
  String? loadError;
  String? busyMessage;
  String? notice;
  bool noticeIsError = false;
  bool supervised = false;
  String? activeScenario;
  final Set<String> visible = {};
  Map<String, dynamic>? lastResult;

  bool get busy => busyMessage != null;
  List<Map<String, dynamic>> get people =>
      [for (final p in (status?['volunteers'] as List? ?? [])) Map<String, dynamic>.from(p as Map)];

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  @override
  void dispose() {
    name.dispose();
    if (widget.session == null) session.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final results = await Future.wait([
        backend.status(),
        backend.scenarios(),
        backend.summary(),
      ]);
      if (!mounted) return;
      setState(() {
        status = results[0] as Map<String, dynamic>;
        scenarios = results[1] as List<Map<String, dynamic>>;
        summary = results[2] as Map<String, dynamic>;
        loadError = null;
        visible.removeWhere((id) => !people.any((p) => p['id'] == id));
      });
    } on ConsoleException catch (error) {
      if (mounted) setState(() => loadError = error.message);
    }
  }

  void say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      notice = text;
      noticeIsError = error;
    });
    // The banner sits at the top of a long page; a snack bar is visible wherever you have scrolled.
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: Duration(seconds: error ? 12 : 4),
          showCloseIcon: true,
          backgroundColor: error ? Colors.red.shade800 : null,
        ),
      );
  }

  Future<T?> guarded<T>(String message, Future<T> Function() action) async {
    setState(() {
      busyMessage = message;
      notice = null;
    });
    try {
      return await action();
    } on ConsoleException catch (error) {
      say(error.message, error: true);
    } catch (_) {
      say('Something went wrong. Please try again.', error: true);
    } finally {
      if (mounted) setState(() => busyMessage = null);
    }
    return null;
  }

  Future<({Uint8List bytes, String extension})?> takeClip() async {
    final clip = session.clip;
    if (clip == null) {
      say('Record a clip first.', error: true);
      return null;
    }
    final extension = await videoExtension(clip);
    final bytes = await clip.readAsBytes();
    return (bytes: bytes, extension: extension);
  }

  Future<void> enrol() async {
    final label = name.text.trim();
    if (label.isEmpty) {
      say('Enter the volunteer’s name or nickname first.', error: true);
      return;
    }
    final clip = await takeClip();
    if (clip == null) return;
    final done = await guarded('Checking the recording and saving this volunteer…', () async {
      return backend.enrol(
        label: label,
        video: clip.bytes,
        extension: clip.extension,
      );
    });
    if (done != null) {
      session.clearClip();
      name.clear();
      setState(() => supervised = false);
      session.setConsent(false);
      say('${done['label']} is enrolled.');
      await refresh();
    }
  }

  Future<void> runScenario(Map<String, dynamic> scenario) async {
    final clip = await takeClip();
    if (clip == null) return;
    final result = await guarded('Running the model three times on your recording…', () async {
      return backend.run(
        scenario: scenario['id'] as String,
        present: visible.toList()..sort(),
        stranger: scenario['unknown_person'] as bool,
        video: clip.bytes,
        extension: clip.extension,
      );
    });
    if (result != null) {
      session.clearClip();
      session.setConsent(false);
      setState(() {
        lastResult = result;
        activeScenario = null;
        visible.clear();
      });
      await refresh();
    }
  }

  Future<void> remove(Map<String, dynamic> person) async {
    final ok = await confirm(
      'Remove ${person['label']}?',
      'Their saved face data is deleted. Results already recorded stay in the summary.',
      'Remove',
    );
    if (ok != true) return;
    await guarded('Removing…', () => backend.removePerson(person['id'] as String));
    await refresh();
  }

  Future<void> exportSummary() async {
    final data = await guarded('Preparing file…', backend.exportData);
    if (data == null) return;
    await XFile.fromData(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
      mimeType: 'application/json',
    ).saveTo('facetrack-model-test.json');
    final report = data['report_text'];
    if (report is String) {
      await XFile.fromData(
        utf8.encode(report),
        mimeType: 'text/plain',
      ).saveTo('facetrack-model-test-report.txt');
    }
    say('Saved two files: a readable report (.txt) and the data file (.json). Send both. They have counts only: no names, faces or videos.');
  }

  Future<void> wipeAll() async {
    final ok = await confirm(
      'Delete all test data?',
      'This removes every volunteer’s saved face data and all recorded results from this computer. '
          'Export the summary first if you need it.',
      'Delete everything',
    );
    if (ok != true) return;
    await guarded('Deleting…', backend.wipe);
    setState(() => lastResult = null);
    say('All test data was deleted from this computer.');
    await refresh();
  }

  Future<bool?> confirm(String title, String body, String action) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final integrity = status?['integrity'] as Map<String, dynamic>?;
    final ready = integrity?['ok'] == true;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'FACETRACK / MODEL TEST',
                  style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.bold, color: _green),
                ),
                const SizedBox(height: 8),
                Text('Check the face model yourself', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                const Text(
                  'Enrol a few consenting volunteers, record six short clips, and see whether the '
                  'model’s suggestions match what really happened. Videos are deleted straight '
                  'after checking, and nothing leaves this computer.',
                ),
                const SizedBox(height: 16),
                if (busy)
                  Card(
                    color: Colors.amber.shade50,
                    child: ListTile(
                      leading: const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      title: Text(busyMessage!),
                      subtitle: const Text('This can take up to a minute. Please keep this page open.'),
                    ),
                  ),
                if (notice != null)
                  Card(
                    color: noticeIsError ? Colors.red.shade50 : Colors.green.shade50,
                    child: ListTile(
                      leading: Icon(
                        noticeIsError ? Icons.error_outline : Icons.check_circle_outline,
                        color: noticeIsError ? Colors.red.shade800 : _green,
                      ),
                      title: Text(notice!),
                      trailing: IconButton(
                        tooltip: 'Dismiss',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => notice = null),
                      ),
                    ),
                  ),
                if (loadError != null)
                  Card(
                    color: Colors.red.shade50,
                    child: ListTile(
                      leading: const Icon(Icons.power_off_outlined),
                      title: Text(loadError!),
                      trailing: TextButton(onPressed: refresh, child: const Text('Try again')),
                    ),
                  ),
                section(
                  '1. System check',
                  integrity == null
                      ? const Text('Checking…')
                      : Row(
                          children: [
                            Icon(
                              ready ? Icons.verified_outlined : Icons.report_gmailerrorred_outlined,
                              color: ready ? _green : Colors.red.shade800,
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text('${integrity['message']}')),
                          ],
                        ),
                ),
                if (ready) ...[
                  section('2. Volunteers', volunteers()),
                  section('3. The six test recordings', scenarioList()),
                  if (lastResult != null) resultCard(lastResult!),
                  section('4. Results', results()),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget section(String title, Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );

  Widget volunteers() {
    final count = people.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          count < 2
              ? 'Enrol at least 2 volunteers (3 or more is better) before the recordings.'
              : '$count enrolled. Anyone not listed here counts as a “stranger”.',
        ),
        const SizedBox(height: 8),
        for (final person in people)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text('${person['label']}'),
            trailing: IconButton(
              tooltip: 'Remove ${person['label']}',
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : () => remove(person),
            ),
          ),
        const Divider(),
        Text('Add a volunteer', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: name,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Name or nickname (stays on this computer)',
          ),
        ),
        ListenableBuilder(
          listenable: session,
          builder: (context, _) => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('This person has agreed to be recorded for this test.'),
            value: session.consent,
            onChanged: busy || session.recording ? null : session.setConsent,
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('I will watch the recording: one person only, and they follow the prompts.'),
          value: supervised,
          onChanged: busy ? null : (value) => setState(() => supervised = value ?? false),
        ),
        RecorderPanel(
          session: session,
          mode: 'enrollment',
          hint: '15 seconds. Only this person in view. They look at the camera, then follow the '
              'on-screen prompts to turn their head.',
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: Listenable.merge([session, name]),
          builder: (context, _) {
            final hasClip = session.clip != null && session.clipMode == 'enrollment';
            final missing = <String>[
              if (name.text.trim().isEmpty) 'type a name',
              if (!session.consent) 'tick “agreed to be recorded”',
              if (!supervised) 'tick “I will watch the recording”',
              if (!hasClip) 'press Start recording and wait about 15 seconds until it stops',
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: busy || missing.isNotEmpty ? null : enrol,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Save this volunteer'),
                ),
                if (missing.isNotEmpty && !busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'To save: ${missing.join('; ')}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget scenarioList() {
    final byId = {
      for (final s in (summary?['scenarios'] as List? ?? []))
        (s as Map)['id'] as String: Map<String, dynamic>.from(s),
    };
    final ready = people.length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Do them in any order. The first scored attempt counts as the official result; '
          'you can repeat a recording, but it will not replace the first.',
        ),
        const SizedBox(height: 8),
        for (final scenario in scenarios)
          scenarioTile(scenario, byId[scenario['id']] ?? const {}, ready),
      ],
    );
  }

  Widget scenarioTile(Map<String, dynamic> scenario, Map<String, dynamic> state, bool ready) {
    final id = scenario['id'] as String;
    final open = activeScenario == id;
    final stateName = state['status'] as String? ?? 'not_done';
    final chip = switch (stateName) {
      'pass' => const Chip(label: Text('Matched'), avatar: Icon(Icons.check, size: 18)),
      'fail' => Chip(
        label: const Text('Did not match'),
        avatar: Icon(Icons.close, size: 18, color: Colors.red.shade800),
      ),
      _ => const Chip(label: Text('Not done')),
    };
    final minimum = scenario['min_present'] as int;
    final maximum = scenario['max_present'] as int?;
    final canRun = ready && !busy;
    return Card(
      color: open ? Colors.green.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${scenario['title']}', style: Theme.of(context).textTheme.titleMedium),
                ),
                chip,
              ],
            ),
            Text('${scenario['how']}'),
            const SizedBox(height: 8),
            if (!open)
              OutlinedButton(
                onPressed: canRun
                    ? () => setState(() {
                        activeScenario = id;
                        visible.clear();
                        session.clearClip();
                        session.setConsent(false);
                      })
                    : null,
                child: Text(stateName == 'not_done' ? 'Start this recording' : 'Record again (extra try)'),
              ),
            if (open) ...[
              const Divider(),
              Text(
                maximum == 0
                    ? 'Nobody enrolled may be visible in this one.'
                    : 'Tick every enrolled volunteer who is visible in the recording'
                          '${minimum > 0 ? ' (at least $minimum)' : ''}:',
              ),
              if (maximum != 0)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final person in people)
                      FilterChip(
                        label: Text('${person['label']}'),
                        selected: visible.contains(person['id']),
                        onSelected: busy
                            ? null
                            : (value) => setState(() {
                                value ? visible.add(person['id'] as String) : visible.remove(person['id']);
                              }),
                      ),
                  ],
                ),
              if (scenario['unknown_person'] == true)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Include one person who is NOT enrolled.'),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Do not include anyone who is not enrolled.'),
                ),
              ListenableBuilder(
                listenable: session,
                builder: (context, _) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Everyone in view has agreed to be recorded for this test.'),
                  value: session.consent,
                  onChanged: busy || session.recording ? null : session.setConsent,
                ),
              ),
              RecorderPanel(
                session: session,
                mode: 'classroom',
                hint: '10 seconds. Everyone looks forward and moves slowly. Keep the camera still.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  ListenableBuilder(
                    listenable: session,
                    builder: (context, _) => FilledButton.icon(
                      onPressed:
                          busy || session.clip == null || session.clipMode != 'classroom' || !session.consent
                          ? null
                          : () => runScenario(scenario),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Check this recording'),
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => setState(() => activeScenario = null),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget resultCard(Map<String, dynamic> row) {
    final correct = row['correct'] == true;
    String names(String key) => ((row['${key}_names'] as List?) ?? const []).join(', ');
    final suggested = names('suggested');
    return Card(
      color: correct ? Colors.green.shade50 : Colors.red.shade50,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              correct ? 'Matched what you expected' : 'Did NOT match what you expected',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('You said was in view: ${names('expected').isEmpty ? 'nobody enrolled' : names('expected')}'),
            Text('Model suggested present: ${suggested.isEmpty ? 'nobody' : suggested}'),
            if ((row['false_presence'] as List).isNotEmpty)
              Text(
                'Wrongly suggested (was not there): ${names('false_presence')}',
                style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.bold),
              ),
            if ((row['missed'] as List).isNotEmpty)
              Text('Not recognised (was there): ${names('missed')}'),
            Text(
              row['stable_across_repeats'] == true
                  ? 'Three separate runs gave the same answer.'
                  : 'The three separate runs gave DIFFERENT answers: treat this as unreliable.',
            ),
            const SizedBox(height: 4),
            Text(
              'Faces found: ${row['detections']} · poor-quality faces skipped: ${row['quality_rejects']} · '
              'stranger faces ignored: ${row['unknown_observations']}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget results() {
    final data = summary;
    if (data == null) return const Text('Loading…');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${data['verdict']}', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '${data['done']} of ${data['total']} recordings done · ${data['passed']} matched · '
          '${data['false_presence_total']} wrongly suggested · ${data['missed_total']} not recognised',
        ),
        if (data['all_stable'] == false)
          Text(
            'Some repeats disagreed with each other.',
            style: TextStyle(color: Colors.red.shade800),
          ),
        if (data['slowest_clip_processing_ms'] != null)
          Text(
            'Slowest clip took ${((data['slowest_clip_processing_ms'] as num) / 1000).toStringAsFixed(1)} s '
            'to analyse on this computer.',
          ),
        const SizedBox(height: 8),
        Text('${data['disclaimer']}', style: Theme.of(context).textTheme.bodySmall),
        Text('${data['rule']}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : exportSummary,
              icon: const Icon(Icons.download),
              label: const Text('Download report + summary'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : wipeAll,
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete all test data'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Camera preview and recording controls; shares one [CaptureSession] across the page.
class RecorderPanel extends StatelessWidget {
  const RecorderPanel({super.key, required this.session, required this.mode, required this.hint});
  final CaptureSession session;
  final String mode;
  final String hint;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final mine = session.mode == mode;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint),
          const SizedBox(height: 8),
          if (session.ready && mine)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    session.gateway.preview(),
                    if (session.recording)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          margin: const EdgeInsets.all(12),
                          padding: const EdgeInsets.all(10),
                          color: Colors.black87,
                          child: Text(
                            '${session.prompt} · ${session.elapsed}s',
                            style: const TextStyle(color: Colors.white, fontSize: 20),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (session.error != null && mine)
            Text(session.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (session.clip != null && session.clipMode == mode && !session.recording)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('Recording ready. Record again to replace it.'),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: session.busy
                    ? null
                    : () async {
                        if (!mine) {
                          await session.close();
                          session.changeMode(mode);
                        }
                        if (!session.ready) {
                          await session.initialize();
                        } else if (session.recording) {
                          await session.stop();
                        } else if (session.consent) {
                          await session.start();
                        }
                      },
                icon: Icon(session.recording && mine ? Icons.stop : Icons.videocam_outlined),
                label: Text(
                  session.busy
                      ? 'Please wait…'
                      : session.recording && mine
                      ? 'Stop recording'
                      : session.ready && mine
                      ? (session.consent ? 'Start recording' : 'Tick consent to record')
                      : 'Turn on camera',
                ),
              ),
              if (session.ready && mine && !session.recording)
                TextButton(onPressed: () => session.close(), child: const Text('Turn camera off')),
            ],
          ),
        ],
      );
    },
  );
}

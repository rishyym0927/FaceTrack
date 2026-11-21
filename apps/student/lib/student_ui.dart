import 'package:flutter/material.dart';
import 'package:facetrack_models/facetrack_models.dart';

/// Colours shared by the Student screens (the product palette).
const studentGreen = Color(0xff176451);
const studentRed = Color(0xffa22f2f);
const studentAmber = Color(0xff9a6a00);
const studentBlue = Color(0xff1f5fa8);

/// The four visible stages of face registration, in order.
const registrationSteps = ['Consent', 'Record', 'Upload', 'Review'];

/// Where the student is in face registration.
///
/// [step] is the index of the stage the student is on (0 to 3), and
/// [complete] is true once the face enrolment is active, when every stage is
/// done. A stage is only shown as done after it has really finished, so
/// "Review" stays pending while faculty have not approved the recording.
class RegistrationProgress {
  const RegistrationProgress({required this.step, required this.complete});

  final int step;
  final bool complete;

  /// Derived only from the existing enrolment state. [hasClip] says that a
  /// recording is saved privately on this device and waiting to be uploaded.
  factory RegistrationProgress.of(BiometricState state, {bool hasClip = false}) {
    final a = state.attempt;
    if (state.active && (a == null || !a.unfinished)) {
      return const RegistrationProgress(step: 3, complete: true);
    }
    if (state.consentId == null) {
      return const RegistrationProgress(step: 0, complete: false);
    }
    return switch (a?.status) {
      'awaiting_upload' => RegistrationProgress(
        step: hasClip ? 2 : 1,
        complete: false,
      ),
      'queued' ||
      'processing' ||
      'review_required' => const RegistrationProgress(
        step: 3,
        complete: false,
      ),
      _ => const RegistrationProgress(step: 1, complete: false),
    };
  }

  /// One short line saying what to do next, in plain language.
  String get next => complete
      ? 'You are registered. Nothing more to do.'
      : switch (step) {
          0 => 'Read and accept the privacy notice to begin.',
          1 => 'Record a short guided video of your face.',
          2 => 'Upload your video so it can be checked.',
          _ => 'Your video is being checked. No action needed.',
        };
}

/// Horizontal step indicator for [registrationSteps]. Wraps its labels, so it
/// stays readable at 200% text size and on narrow phones.
class StepProgress extends StatelessWidget {
  const StepProgress(this.progress, {super.key});
  final RegistrationProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: progress.complete
          ? 'Registration complete'
          : 'Step ${progress.step + 1} of ${registrationSteps.length}: '
                '${registrationSteps[progress.step]}',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < registrationSteps.length; i++) ...[
              Expanded(
                child: _Step(
                  label: registrationSteps[i],
                  done: progress.complete || i < progress.step,
                  current: !progress.complete && i == progress.step,
                  first: i == 0,
                  last: i == registrationSteps.length - 1,
                  scheme: scheme,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.done,
    required this.current,
    required this.first,
    required this.last,
    required this.scheme,
  });
  final String label;
  final bool done, current, first, last;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final color = done
        ? studentGreen
        : current
        ? scheme.primary
        : scheme.outline;
    Widget line(bool visible, bool lit) => Expanded(
      child: Container(
        height: 2,
        color: !visible
            ? Colors.transparent
            : lit
            ? studentGreen
            : scheme.outline,
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            line(!first, done || current),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? studentGreen : Colors.white,
                border: Border.all(color: color, width: current ? 2.5 : 1.5),
              ),
              child: done
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : current
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                      ),
                    )
                  : null,
            ),
            line(!last, done),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: current ? FontWeight.w800 : FontWeight.w600,
            color: done || current ? null : scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A rounded icon tile used at the start of rows and panels.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color, this.size = 44});
  final IconData icon;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Icon(icon, color: c, size: size * .5),
    );
  }
}

/// A short tip with a leading icon, for guidance lists.
class TipRow extends StatelessWidget {
  const TipRow(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// An inline, non-blocking message with a retry, for sections that fail on
/// their own while the rest of the page still works.
class InlineNotice extends StatelessWidget {
  const InlineNotice(
    this.message, {
    super.key,
    this.onRetry,
    this.icon = Icons.info_outline,
    this.tone,
  });
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;
  final Color? tone;
  @override
  Widget build(BuildContext context) {
    final color = tone ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// A coloured percentage pill, e.g. "82%" on a subject row.
class PercentPill extends StatelessWidget {
  const PercentPill(this.percent, {super.key, required this.color});
  final double? percent;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(100),
    ),
    child: Text(
      percent == null ? 'No classes yet' : '${percent!.round()}% attended',
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
    ),
  );
}

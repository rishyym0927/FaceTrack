import 'package:flutter/material.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'api.dart';

ThemeData appTheme() {
  const primary = Color(0xff176451),
      ink = Color(0xff17322a),
      muted = Color(0xff587067),
      border = Color(0xffdce7e1),
      canvas = Color(0xfff2f6f4);
  return ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: primary,
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: ink,
          onSurfaceVariant: muted,
          outline: border,
          surfaceContainerLowest: canvas,
        ),
    scaffoldBackgroundColor: canvas,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1),
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w800,
        letterSpacing: -.6,
      ),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -.2),
      titleMedium: TextStyle(fontWeight: FontWeight.w700),
      labelLarge: TextStyle(fontWeight: FontWeight.w700),
      bodyLarge: TextStyle(height: 1.45),
      bodyMedium: TextStyle(height: 1.4),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: border)),
    ),
    cardTheme: CardThemeData(
      elevation: 1,
      shadowColor: const Color(0xff133d35).withValues(alpha: .08),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.all(16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        side: const BorderSide(color: border),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: Colors.white,
      elevation: 0,
      indicatorColor: const Color(0xffdcefe5),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Color(0xffdcefe5),
      elevation: 0,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white,
      selectedColor: const Color(0xffdcefe5),
      side: const BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    dividerTheme: const DividerThemeData(color: border, space: 28),
    tabBarTheme: TabBarThemeData(
      dividerColor: border,
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: BoxDecoration(
        color: const Color(0xffdcefe5),
        borderRadius: BorderRadius.circular(12),
      ),
      labelColor: ink,
      unselectedLabelColor: muted,
      labelStyle: const TextStyle(fontWeight: FontWeight.w700),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: Color(0xffdce7e1),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    visualDensity: VisualDensity.standard,
  );
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = 24,
    this.accent = false,
  });
  final Widget child;
  final double padding;
  final bool accent;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (accent)
            Container(
              height: 5,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xff146653), Color(0xffa9d78c)],
                ),
              ),
            ),
          Padding(padding: EdgeInsets.all(padding), child: child),
        ],
      ),
    ),
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
    this.eyebrow,
    this.icon = Icons.auto_awesome_outlined,
    this.compact = false,
  });
  final String title, subtitle;
  final Widget? action;
  final String? eyebrow;
  final IconData icon;
  final bool compact;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: LayoutBuilder(
        builder: (context, c) {
          final stacked =
              c.maxWidth < 900 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: const Color(0xffb9e9af), size: 17),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      (eyebrow ?? 'FACETRACK').toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xffc8e9dd),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style:
                    (compact || stacked
                            ? Theme.of(context).textTheme.headlineMedium
                            : Theme.of(context).textTheme.headlineLarge)
                        ?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.1,
                          color: Colors.white,
                        ),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: const Color(0xffd5e9e2), height: 1.5),
              ),
            ],
          );
          final actionSurface = action == null
              ? null
              : Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: action,
                );
          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xff102f32),
                        Color(0xff145d54),
                        Color(0xff218772),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -38,
                top: -105,
                child: Container(
                  width: 290,
                  height: 290,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                ),
              ),
              Positioned(
                right: 40,
                top: -28,
                child: Container(
                  width: 175,
                  height: 175,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white12, width: 1),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(compact || stacked ? 20 : 34),
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          text,
                          if (actionSurface != null) ...[
                            const SizedBox(height: 22),
                            actionSurface,
                          ],
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: text),
                          if (actionSurface != null) ...[
                            const SizedBox(width: 24),
                            actionSurface,
                          ],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'active' || 'ready' || 'present' => const Color(0xff176451),
      'requested' ||
      'queued' ||
      'processing' ||
      'late' => const Color(0xff805500),
      'rejected' || 'failed' || 'absent' => const Color(0xffa22f2f),
      _ => const Color(0xff465650),
    };
    final label = switch (status) {
      'ready' => 'Ready to download',
      'queued' => 'Queued',
      'processing' => 'Processing',
      'failed' => 'Needs attention',
      'present' => 'Present',
      'late' => 'Late',
      'absent' => 'Absent',
      'excused' => 'Excused',
      'unassessed' => 'Unassessed',
      _ => statusLabel(status),
    };
    return Semantics(
      label: 'Status: $label',
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: color.withValues(alpha: 0.16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.title,
    required this.message,
    this.action,
    this.icon = Icons.info_outline,
  });
  final String title, message;
  final Widget? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            icon,
            size: 30,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    ),
  );
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    final failure = error is AppFailure ? error as AppFailure : null;
    final development = failure?.code == 'development_api_unreachable';
    final title = development
        ? 'Mac connection unavailable'
        : switch (failure?.status) {
            401 => 'Session expired',
            403 => 'Access unavailable',
            404 => 'Item unavailable',
            429 => 'Please wait before retrying',
            503 => 'Service temporarily unavailable',
            _ => 'Could not load this page',
          };
    final icon = development
        ? Icons.usb_off_outlined
        : switch (failure?.status) {
            401 => Icons.lock_clock_outlined,
            403 => Icons.lock_outline,
            404 => Icons.search_off_outlined,
            429 => Icons.hourglass_top_outlined,
            503 => Icons.cloud_off_outlined,
            _ => Icons.sync_problem_outlined,
          };
    return MessageView(
      title: title,
      message:
          failure?.message ??
          'Please retry. If this continues, contact your institute.',
      action: OutlinedButton.icon(
        onPressed: retry,
        icon: const Icon(Icons.refresh),
        label: const Text('Retry'),
      ),
      icon: icon,
    );
  }
}

class PagedController<T> extends ChangeNotifier {
  PagedController(this.fetch);
  final Future<PageData<T>> Function(String?) fetch;
  List<T> items = [];
  String? cursor;
  Object? error;
  bool loading = false, _disposed = false;
  int _generation = 0;
  bool _retryReset = true;
  Future<void> retry() => load(reset: _retryReset);
  Future<void> load({bool reset = true}) async {
    if (loading && !reset) return;
    _retryReset = reset;
    final generation = ++_generation;
    if (reset) {
      cursor = null;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final data = await fetch(cursor);
      if (_disposed || generation != _generation) return;
      items = reset ? data.items : [...items, ...data.items];
      cursor = data.nextCursor;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e;
      if (e is AppFailure && [401, 403, 404].contains(e.status)) items = [];
    }
    if (_disposed || generation != _generation) return;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}

class PagedList<T> extends StatelessWidget {
  const PagedList({
    super.key,
    required this.controller,
    required this.item,
    required this.emptyTitle,
    required this.emptyMessage,
  });
  final PagedController<T> controller;
  final Widget Function(T) item;
  final String emptyTitle, emptyMessage;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      late final Widget content;
      if (controller.loading && controller.items.isEmpty) {
        content = const Padding(
          key: ValueKey('loading'),
          padding: EdgeInsets.only(top: 4),
          child: SkeletonList(),
        );
      } else if (controller.error != null && controller.items.isEmpty) {
        content = KeyedSubtree(
          key: const ValueKey('error'),
          child: ErrorView(controller.error!, retry: () => controller.load()),
        );
      } else if (controller.items.isEmpty) {
        content = MessageView(
          key: const ValueKey('empty'),
          title: emptyTitle,
          message: emptyMessage,
          icon: Icons.groups_outlined,
        );
      } else {
        content = Column(
          key: const ValueKey('items'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.loading) const LinearProgressIndicator(),
            for (final value in controller.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: item(value),
              ),
            if (controller.error != null)
              ErrorView(controller.error!, retry: () => controller.retry()),
            if (controller.cursor != null)
              Align(
                alignment: Alignment.center,
                child: OutlinedButton(
                  onPressed: controller.loading
                      ? null
                      : () => controller.load(reset: false),
                  child: const Text('Load more'),
                ),
              ),
          ],
        );
      }
      return AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: content,
      );
    },
  );
}

class ActionDialog extends StatefulWidget {
  const ActionDialog({
    super.key,
    required this.title,
    required this.child,
    required this.submit,
    this.button = 'Confirm',
  });
  final String title, button;
  final Widget child;
  final Future<void> Function(Mutation) submit;
  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  final form = GlobalKey<FormState>();
  final mutation = Mutation();
  bool busy = false;
  String? error;
  Future<void> save() async {
    if (busy) return;
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.submit(mutation);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      if (e is AppFailure && e.status == 409) {
        Navigator.of(context).pop(false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      } else {
        setState(
          () => error = e is AppFailure
              ? e.message
              : 'Could not save. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.child,
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'Saving…' : widget.button),
        ),
      ],
    ),
  );
}

String? requiredText(String? value) =>
    (value == null || value.trim().isEmpty) ? 'This field is required.' : null;
void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

// --- Analytics primitives ----------------------------------------------------

/// Threshold colouring shared by every attendance percentage in both apps.
Color percentColor(num? p) => p == null
    ? const Color(0xff587067)
    : p >= 75
    ? const Color(0xff176451)
    : p >= 50
    ? const Color(0xff9a6a00)
    : const Color(0xffa22f2f);

/// Tweens a number up to [value] on build; honours reduced-motion.
class AnimatedCount extends StatelessWidget {
  const AnimatedCount(
    this.value, {
    super.key,
    this.decimals = 0,
    this.suffix = '',
    this.style,
  });
  final num value;
  final int decimals;
  final String suffix;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) {
    final target = value.toDouble();
    final instant = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: instant ? target : 0, end: target),
      duration: instant
          ? Duration.zero
          : const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        v.toStringAsFixed(decimals) + suffix,
        style: style,
      ),
    );
  }
}

/// Circular attendance ring with the percentage in the centre.
class PercentRing extends StatelessWidget {
  const PercentRing({
    super.key,
    required this.value,
    this.size = 116,
    this.stroke = 12,
    this.caption,
  });

  /// 0–100, or null when there is nothing assessed yet.
  final double? value;
  final double size, stroke;
  final String? caption;
  @override
  Widget build(BuildContext context) {
    final color = percentColor(value);
    final target = (value ?? 0).clamp(0, 100).toDouble();
    final instant = MediaQuery.disableAnimationsOf(context);
    final track = Theme.of(context).colorScheme.surfaceContainerLowest;
    return Semantics(
      label: value == null
          ? 'No percentage yet'
          : 'Attendance ${value!.toStringAsFixed(1)} percent',
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: instant ? target : 0, end: target),
          duration: instant ? Duration.zero : const Duration(milliseconds: 750),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => CustomPaint(
            painter: _RingPainter(
              v / 100,
              stroke,
              value == null ? track : color,
              track,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value == null ? '—' : '${v.round()}%',
                    style: TextStyle(
                      fontSize: size * .26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.5,
                      color: value == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : color,
                    ),
                  ),
                  if (caption != null)
                    Text(
                      caption!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.stroke, this.color, this.track);
  final double fraction, stroke;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final bg = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(center, radius, bg);
    if (fraction <= 0) return;
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.5708,
      6.28319 * fraction.clamp(0, 1),
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color;
}

/// Thin rounded proportion bar (0–1), animated.
class TrackBar extends StatelessWidget {
  const TrackBar({super.key, required this.value, this.color, this.height = 8});
  final double value;
  final Color? color;
  final double height;
  @override
  Widget build(BuildContext context) {
    final instant = MediaQuery.disableAnimationsOf(context);
    final c = color ?? Theme.of(context).colorScheme.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: Theme.of(context).colorScheme.surfaceContainerLowest),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: instant ? value : 0, end: value.clamp(0, 1)),
              duration:
                  instant ? Duration.zero : const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => FractionallySizedBox(
                widthFactor: v.clamp(0, 1),
                alignment: Alignment.centerLeft,
                child: Container(color: c),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single metric: big (animated) value, label, optional icon and caption.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.accent,
    this.caption,
    this.decimals = 0,
    this.suffix = '',
  });
  final String label;
  final num value;
  final IconData? icon;
  final Color? accent;
  final String? caption;
  final int decimals;
  final String suffix;
  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedCount(
            value,
            decimals: decimals,
            suffix: suffix,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -.8,
              color: color,
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lays stat tiles into equal columns that reflow by width (2-up on phones).
class StatGrid extends StatelessWidget {
  const StatGrid({
    super.key,
    required this.children,
    this.minTileWidth = 158,
    this.spacing = 12,
  });
  final List<Widget> children;
  final double minTileWidth, spacing;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final maxCols = ((c.maxWidth + spacing) / (minTileWidth + spacing))
          .floor()
          .clamp(1, children.length == 0 ? 1 : children.length);
      final width = (c.maxWidth - spacing * (maxCols - 1)) / maxCols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final child in children)
            SizedBox(width: width.floorToDouble(), child: child),
        ],
      );
    },
  );
}

/// One-shot fade-and-rise entrance; instant when reduced-motion is on.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.child, this.delayMs = 0});
  final Widget child;
  final int delayMs;
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curve),
        child: widget.child,
      ),
    );
  }
}

// --- Loading skeletons -------------------------------------------------------
// Deliberately static (no ticker / ShaderMask): these render as transient
// AnimatedSwitcher children during dialog-pop + reload transitions, where a
// ticking child can trip an InheritedElement teardown assertion.

/// A single placeholder block with a soft baked gradient so it reads as
/// designed rather than flat.
class SkelBox extends StatelessWidget {
  const SkelBox({super.key, this.width, this.height = 14, this.radius = 8});
  final double? width, height, radius;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xffeaf0ed), Color(0xffdfe8e3)],
      ),
      borderRadius: BorderRadius.circular(radius ?? 8),
    ),
  );
}

/// A card-shaped placeholder matching the list cards' rhythm.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Row(
          children: [
            SkelBox(width: 44, height: 44, radius: 14),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkelBox(width: 180, height: 16),
                  SizedBox(height: 10),
                  SkelBox(width: 120, height: 12),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 18),
        SkelBox(width: 90, height: 24, radius: 100),
        SizedBox(height: 14),
        SkelBox(height: 12),
        SizedBox(height: 8),
        SkelBox(width: 220, height: 12),
      ],
    ),
  );
}

/// A stack of [count] skeleton cards for first-load states.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 3});
  final int count;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < count; i++)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: SkeletonCard(),
        ),
    ],
  );
}

// --- Simple horizontal bar distribution --------------------------------------

class BarDatum {
  const BarDatum(this.label, this.value, this.color);
  final String label;
  final num value;
  final Color color;
}

/// Labelled horizontal bars sharing one scale; bars animate via [TrackBar].
class BarDistribution extends StatelessWidget {
  const BarDistribution({super.key, required this.bars, this.labelWidth = 104});
  final List<BarDatum> bars;
  final double labelWidth;
  @override
  Widget build(BuildContext context) {
    final maxValue = bars.fold<num>(1, (m, b) => b.value > m ? b.value : m);
    return Column(
      children: [
        for (final b in bars)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    b.label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: TrackBar(
                    value: b.value <= 0 ? 0 : b.value / maxValue,
                    color: b.color,
                    height: 14,
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${b.value}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

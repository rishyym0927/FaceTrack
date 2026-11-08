part of '../teacher_admin.dart';

/// One stop of the guided tour. [target] is spotlighted; without one the card
/// is centred. [section] is opened first so the target exists.
class _TourStep {
  const _TourStep({
    required this.title,
    required this.body,
    required this.section,
    this.target,
    this.icon = Icons.tips_and_updates_outlined,
  });
  final String title, body;
  final _Section section;
  final GlobalKey? target;
  final IconData icon;
}

/// Coach marks drawn in the app's overlay: the page is dimmed except for a
/// rounded spotlight on the current target, with a card that explains it.
/// Input to the page underneath is blocked while the tour runs.
class _TourController {
  _TourController({
    required this.steps,
    required this.prepare,
    required this.onEnd,
  });
  final List<_TourStep> Function() steps;

  /// Opens the step's section and scrolls its target into view.
  final Future<void> Function(_TourStep step) prepare;
  final VoidCallback onEnd;
  OverlayEntry? _entry;
  int index = 0;

  bool get active => _entry != null;

  Future<void> start(BuildContext context) async {
    if (active) return;
    index = 0;
    _entry = OverlayEntry(builder: (_) => _TourOverlay(controller: this));
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    await go(0);
  }

  Future<void> go(int i) async {
    final all = steps();
    if (i < 0 || i >= all.length) return;
    index = i;
    await prepare(all[i]);
    _entry?.markNeedsBuild();
  }

  void next() => index + 1 >= steps().length ? end() : go(index + 1);
  void back() => go(index - 1);

  void end() {
    if (!active) return;
    _entry!
      ..remove()
      ..dispose();
    _entry = null;
    onEnd();
  }

  /// Removes the overlay without counting the tour as seen (page disposed).
  void dispose() {
    _entry
      ?..remove()
      ..dispose();
    _entry = null;
  }
}

class _TourOverlay extends StatefulWidget {
  const _TourOverlay({required this.controller});
  final _TourController controller;
  @override
  State<_TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<_TourOverlay> {
  Rect? _last;
  final _focus = FocusNode(debugLabel: 'admin-tour');

  @override
  void initState() {
    super.initState();
    // Take keyboard focus from the page so arrows and Esc drive the tour.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final c = widget.controller;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      c.next();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        c.index > 0) {
      c.back();
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      c.end();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Rect? _targetRect(_TourStep step) {
    final box = step.target?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final steps = c.steps();
    final step = steps[c.index.clamp(0, steps.length - 1)];
    final rect = _targetRect(step);
    // The target may still be moving (scrolling, a section switch); follow it.
    if (rect != _last) {
      _last = rect;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _targetRect(step) != _last) setState(() {});
      });
    }
    final size = MediaQuery.sizeOf(context);
    final hole = rect?.inflate(8);
    final cardWidth = (size.width - 32).clamp(0.0, 380.0);
    final narrow = size.width < 600;
    // Large text on a short phone: the card scrolls instead of pushing its
    // buttons off screen.
    Widget card = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (size.height - 32 - MediaQuery.paddingOf(context).vertical)
            .clamp(120.0, double.infinity),
      ),
      child: SingleChildScrollView(
        child: _TourCard(controller: c, step: step, total: steps.length),
      ),
    );
    card = SizedBox(width: narrow ? null : cardWidth, child: card);

    final Widget placed;
    if (hole == null) {
      placed = Center(
        child: Padding(padding: const EdgeInsets.all(16), child: card),
      );
    } else if (narrow) {
      // Phones: keep the card at whichever end the target is not.
      final targetLow = hole.center.dy > size.height / 2;
      placed = Positioned(
        left: 16,
        right: 16,
        top: targetLow ? 16 + MediaQuery.paddingOf(context).top : null,
        bottom: targetLow ? null : 16,
        child: card,
      );
    } else {
      placed = Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: _CardPlacement(hole, cardWidth),
          child: card,
        ),
      );
    }
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          const Positioned.fill(
            child: ModalBarrier(dismissible: false, color: Colors.transparent),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: hole == null
                  ? CustomPaint(painter: _SpotlightPainter(null))
                  : TweenAnimationBuilder<Rect?>(
                      tween: RectTween(end: hole),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      builder: (context, r, _) =>
                          CustomPaint(painter: _SpotlightPainter(r)),
                    ),
            ),
          ),
          placed,
        ],
      ),
    );
  }
}

/// Puts the card below the target if it fits, else above, else pinned to the
/// bottom of the screen (a target taller than the screen); measured, so large
/// text never pushes the buttons off screen.
class _CardPlacement extends SingleChildLayoutDelegate {
  _CardPlacement(this.hole, this.width);
  final Rect hole;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints(maxWidth: width, maxHeight: c.maxHeight - 32);

  @override
  Offset getPositionForChild(Size size, Size child) {
    const gap = 12.0, edge = 16.0;
    final left = hole.left.clamp(
      edge,
      (size.width - child.width - edge).clamp(edge, double.infinity),
    );
    final double top;
    if (hole.bottom + gap + child.height <= size.height - edge) {
      top = hole.bottom + gap;
    } else if (hole.top - gap - child.height >= edge) {
      top = hole.top - gap - child.height;
    } else {
      top = size.height - edge - child.height;
    }
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_CardPlacement old) =>
      old.hole != hole || old.width != width;
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter(this.hole);
  final Rect? hole;
  @override
  void paint(Canvas canvas, Size size) {
    final dim = Path()..addRect(Offset.zero & size);
    if (hole != null) {
      dim
        ..addRRect(RRect.fromRectAndRadius(hole!, const Radius.circular(18)))
        ..fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(dim, Paint()..color = const Color(0xb3061a17));
    if (hole != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(hole!, const Radius.circular(18)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xff5fd3a6),
      );
    }
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.hole != hole;
}

class _TourCard extends StatelessWidget {
  const _TourCard({
    required this.controller,
    required this.step,
    required this.total,
  });
  final _TourController controller;
  final _TourStep step;
  final int total;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final i = controller.index;
    final last = i == total - 1;
    return KeyedSubtree(
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Guided tour, step ${i + 1} of $total',
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(20),
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(step.icon, color: scheme.primary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Step ${i + 1} of $total',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close the tour',
                      icon: const Icon(Icons.close),
                      onPressed: controller.end,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  step.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(step.body, style: const TextStyle(height: 1.5)),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: (i + 1) / total,
                    minHeight: 5,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!last)
                      TextButton(
                        onPressed: controller.end,
                        child: const Text('Skip tour'),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (i > 0)
                          OutlinedButton(
                            onPressed: controller.back,
                            child: const Text('Back'),
                          ),
                        FilledButton(
                          onPressed: controller.next,
                          child: Text(last ? 'Finish' : 'Next'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

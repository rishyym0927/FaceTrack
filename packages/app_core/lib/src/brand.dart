import 'package:flutter/material.dart';

/// Brand colours, matching the app theme and the home banner.
class Brand {
  const Brand._();
  static const deep = Color(0xff0d2a2c);
  static const green = Color(0xff135f50);
  static const light = Color(0xff23906f);
  static const mint = Color(0xffd5e9e2);
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [deep, green, light],
  );
}

/// FaceTrack's logo mark: a rounded tile with scan corners around a simple face.
class FaceTrackMark extends StatelessWidget {
  const FaceTrackMark({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'FaceTrack',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter()),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final tile = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(s * .28),
    );
    canvas.drawRRect(
      tile,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff2fae86), Color(0xff0f5a49)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawRRect(
      tile.deflate(s * .02),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * .02
        ..color = Colors.white.withValues(alpha: .25),
    );
    // Scan corners.
    final bracket = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * .07
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    final inset = s * .2, arm = s * .17;
    void corner(double x, double y, double dx, double dy) {
      canvas.drawPath(
        Path()
          ..moveTo(x + dx * arm, y)
          ..lineTo(x, y)
          ..lineTo(x, y + dy * arm),
        bracket,
      );
    }

    corner(inset, inset, 1, 1);
    corner(s - inset, inset, -1, 1);
    corner(inset, s - inset, 1, -1);
    corner(s - inset, s - inset, -1, -1);
    // A face: head and shoulders.
    final fill = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(s * .5, s * .43), s * .1, fill);
    final shoulders = Path()
      ..moveTo(s * .33, s * .67)
      ..quadraticBezierTo(s * .5, s * .44, s * .67, s * .67)
      ..close();
    canvas.drawPath(shoulders, fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

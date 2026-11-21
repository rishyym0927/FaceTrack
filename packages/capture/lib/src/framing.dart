import 'dart:ui' show Rect;

/// One look at the live preview in the browser: faces (as 0-1 fractions of the frame, with a
/// temporary track id and whether the face is fully in view and steady) and how bright it is.
class FramingReading {
  const FramingReading({
    this.video = false,
    this.ended = false,
    this.detector = false,
    this.faces,
    this.light,
    this.width = 0,
    this.height = 0,
  });

  /// A live preview picture was found.
  final bool video;

  /// The camera's picture stopped for good: unplugged, or taken by another application.
  final bool ended;

  /// The face detector is loaded. When false only [light] is available.
  final bool detector;

  /// Null when this frame was not analysed (same picture as before, or detector missing).
  final List<({int id, Rect bounds, bool framed})>? faces;

  /// Mean brightness 0-255, or null when it could not be read.
  final int? light;
  final int width, height;

  factory FramingReading.fromJson(Map<String, dynamic> json) {
    final list = json['faces'];
    return FramingReading(
      video: json['video'] == true,
      ended: json['ended'] == true,
      detector: json['detector'] == true,
      light: (json['light'] as num?)?.toInt(),
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      faces: list is! List
          ? null
          : [
              for (final f in list.cast<Map<String, dynamic>>())
                (
                  id: (f['id'] as num).toInt(),
                  bounds: Rect.fromLTWH(
                    (f['x'] as num).toDouble(),
                    (f['y'] as num).toDouble(),
                    (f['w'] as num).toDouble(),
                    (f['h'] as num).toDouble(),
                  ),
                  framed: f['framed'] == true,
                ),
            ],
    );
  }
}

/// Light and size advice the scan page can show before and during a scan.
enum Lighting { unknown, tooDark, good, tooBright }

Lighting lightingOf(int? light) => light == null
    ? Lighting.unknown
    : light < 55
    ? Lighting.tooDark
    : light > 205
    ? Lighting.tooBright
    : Lighting.good;

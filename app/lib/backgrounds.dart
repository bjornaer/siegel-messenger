import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import 'l10n/app_localizations.dart';
import 'src/rust/api/core.dart';
import 'themes.dart';

/// Settings keys. The photo is a JPEG kept in the encrypted database, like everything else.
const _kind = 'chat_background'; // '' = the theme's pattern, 'plain', 'photo'
const _photo = 'chat_background_photo'; // base64

/// Behind every chat: the theme's pattern, nothing, or the user's photo, dimmed so bubbles read.
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.core, required this.child});
  final Core core;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final Widget back = switch (core.setting(key: _kind)) {
      'plain' => const SizedBox.expand(),
      'photo' when (core.setting(key: _photo) ?? '').isNotEmpty => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(color: (dark ? Colors.black : Colors.white).withValues(alpha: dark ? 0.45 : 0.3)),
        child: Image.memory(
          base64Decode(core.setting(key: _photo)!),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
          excludeFromSemantics: true,
        ),
      ),
      _ => CustomPaint(
        painter: ThemePattern(themeChoice.value.id, theme.colorScheme.onSurface.withValues(alpha: dark ? 0.07 : 0.06)),
        child: const SizedBox.expand(),
      ),
    };
    return Stack(
      children: [
        Positioned.fill(child: RepaintBoundary(child: back)),
        child,
      ],
    );
  }
}

/// A faint repeating motif for each theme, drawn in code so it is sharp at any size.
class ThemePattern extends CustomPainter {
  ThemePattern(this.themeId, this.color);
  final String themeId;
  final Color color;

  static const _tile = 92.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (themeId == 'lindwurm') return _scales(canvas, size, p); // fills the whole area
    final motif = _motifs[themeId] ?? _seal;
    var row = 0;
    for (var y = -_tile / 2; y < size.height + _tile; y += _tile * 0.75, row++) {
      for (var x = row.isOdd ? _tile / 2 : 0.0; x < size.width + _tile; x += _tile) {
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(((row * 7 + x ~/ _tile * 3) % 5 - 2) * 0.12); // a little life, still regular
        motif(canvas, p);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(ThemePattern old) => old.themeId != themeId || old.color != color;

  static final Map<String, void Function(Canvas, Paint)> _motifs = {
    'siegel': _seal,
    'drache': _flame,
    'loewe': _crown,
    'schnee': _snowflake,
    'krampus': _horns,
    'nordlicht': _aurora,
    'fernweh': _compass,
    'edelweiss': _edelweiss,
    'kraehe': _feather,
  };

  /// A wax seal: scalloped rim, inner ring.
  static void _seal(Canvas c, Paint p) {
    final rim = Path();
    for (var i = 0; i <= 72; i++) {
      final a = i / 72 * 2 * math.pi;
      final r = 15 + 1.6 * math.sin(a * 12);
      final o = Offset(r * math.cos(a), r * math.sin(a));
      i == 0 ? rim.moveTo(o.dx, o.dy) : rim.lineTo(o.dx, o.dy);
    }
    c.drawPath(rim, p);
    c.drawCircle(Offset.zero, 10, p);
  }

  /// A flame: two curved tongues.
  static void _flame(Canvas c, Paint p) {
    c.drawPath(
      Path()
        ..moveTo(0, 14)
        ..cubicTo(-12, 8, -8, -6, 0, -16)
        ..cubicTo(2, -6, 12, -2, 8, 8)
        ..cubicTo(6, 12, 3, 14, 0, 14)
        ..moveTo(0, 10)
        ..cubicTo(-4, 6, -3, 0, 1, -5)
        ..cubicTo(2, 1, 5, 4, 3, 8),
      p,
    );
  }

  /// A heraldic crown.
  static void _crown(Canvas c, Paint p) {
    c.drawPath(
      Path()
        ..moveTo(-13, 8)
        ..lineTo(-14, -6)
        ..lineTo(-7, 1)
        ..lineTo(0, -10)
        ..lineTo(7, 1)
        ..lineTo(14, -6)
        ..lineTo(13, 8)
        ..close(),
      p,
    );
    c.drawLine(const Offset(-13, 12), const Offset(13, 12), p);
    for (final x in [-14.0, 0.0, 14.0]) {
      c.drawCircle(Offset(x, x == 0 ? -12.5 : -8.5), 1.6, p);
    }
  }

  /// Six arms with two pairs of branches each.
  static void _snowflake(Canvas c, Paint p) {
    for (var i = 0; i < 6; i++) {
      c.save();
      c.rotate(i * math.pi / 3);
      c.drawLine(Offset.zero, const Offset(0, -15), p);
      for (final (y, w) in [(-7.0, 4.0), (-11.5, 3.0)]) {
        c.drawLine(Offset(0, y), Offset(-w, y - w), p);
        c.drawLine(Offset(0, y), Offset(w, y - w), p);
      }
      c.restore();
    }
  }

  /// Two horns sweeping up and out from a brow.
  static void _horns(Canvas c, Paint p) {
    for (final s in [-1.0, 1.0]) {
      c.drawPath(
        Path()
          ..moveTo(3 * s, 8)
          ..cubicTo(6 * s, -2, 10 * s, -8, 17 * s, -15)
          ..cubicTo(13 * s, -6, 11 * s, 2, 9 * s, 9),
        p,
      );
    }
    c.drawLine(const Offset(-9, 9), const Offset(9, 9), p);
  }

  /// Two ribbons of light and a star.
  static void _aurora(Canvas c, Paint p) {
    for (final dy in [-4.0, 4.0]) {
      final path = Path()..moveTo(-26, dy);
      for (var x = -26.0; x <= 26; x += 2) {
        path.lineTo(x, dy + 5 * math.sin(x / 6 + dy));
      }
      c.drawPath(path, p);
    }
    _star(c, p, const Offset(18, -16), 3);
  }

  /// A compass star over a wave.
  static void _compass(Canvas c, Paint p) {
    _star(c, p, const Offset(0, -4), 11);
    final wave = Path()..moveTo(-18, 14);
    for (var x = -18.0; x <= 18; x += 2) {
      wave.lineTo(x, 14 + 2.5 * math.sin(x / 3));
    }
    c.drawPath(wave, p);
  }

  /// Eight pointed, felted petals around a cluster of dots.
  static void _edelweiss(Canvas c, Paint p) {
    for (var i = 0; i < 8; i++) {
      c.save();
      c.rotate(i * math.pi / 4);
      c.drawPath(
        Path()
          ..moveTo(0, -4)
          ..quadraticBezierTo(-5, -10, 0, -17)
          ..quadraticBezierTo(5, -10, 0, -4),
        p,
      );
      c.restore();
    }
    for (final o in [Offset.zero, const Offset(-2.5, -1.5), const Offset(2.5, -1.5), const Offset(0, 2.6)]) {
      c.drawCircle(o, 1.2, p);
    }
  }

  /// A feather: quill and slanted barbs.
  static void _feather(Canvas c, Paint p) {
    c.save();
    c.rotate(-math.pi / 5);
    c.drawLine(const Offset(0, 18), const Offset(0, -18), p);
    c.drawPath(
      Path()
        ..moveTo(0, -18)
        ..quadraticBezierTo(-8, -6, -6, 10)
        ..lineTo(0, 12)
        ..moveTo(0, -18)
        ..quadraticBezierTo(8, -6, 6, 10)
        ..lineTo(0, 12),
      p,
    );
    for (var y = -12.0; y <= 6; y += 4.5) {
      c.drawLine(Offset(0, y), Offset(-5, y + 3), p);
      c.drawLine(Offset(0, y), Offset(5, y + 3), p);
    }
    c.restore();
  }

  static void _star(Canvas c, Paint p, Offset at, double r) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 - math.pi / 2;
      final rr = i.isEven ? r : r * 0.32;
      final o = at + Offset(rr * math.cos(a), rr * math.sin(a));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    c.drawPath(path..close(), p);
  }

  /// Lindwurm: overlapping scales, row upon row.
  static void _scales(Canvas c, Size size, Paint p) {
    const w = 40.0, h = 20.0;
    var row = 0;
    for (var y = 0.0; y < size.height + h; y += h, row++) {
      for (var x = row.isOdd ? w / 2 : 0.0; x < size.width + w; x += w) {
        c.drawArc(Rect.fromCenter(center: Offset(x, y), width: w, height: w), 0, math.pi, false, p);
      }
    }
  }
}

/// Settings row and picker for the chat background.
class ChatBackgroundTile extends StatefulWidget {
  const ChatBackgroundTile({super.key, required this.core});
  final Core core;

  @override
  State<ChatBackgroundTile> createState() => _ChatBackgroundTileState();
}

class _ChatBackgroundTileState extends State<ChatBackgroundTile> {
  Future<void> _choose() async {
    final t = AppLocalizations.of(context)!;
    final current = widget.core.setting(key: _kind) ?? '';
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, icon, label) in [
              ('', Icons.texture, t.backgroundPattern),
              ('plain', Icons.crop_square, t.backgroundPlain),
              ('photo', Icons.photo_outlined, t.backgroundPhoto),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                trailing: value == current ? Icon(Icons.check, semanticLabel: t.selected) : null,
                onTap: () => Navigator.pop(c, value),
              ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    if (pick == 'photo') {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      // Phone-screen sized: sharp behind a chat, small in the database.
      final jpeg = await FlutterImageCompress.compressWithList(
        await file.readAsBytes(),
        minWidth: 1440,
        minHeight: 1440,
        quality: 80,
        keepExif: false,
      );
      widget.core.setSetting(key: _photo, value: base64Encode(jpeg));
    } else {
      widget.core.setSetting(key: _photo, value: '');
    }
    widget.core.setSetting(key: _kind, value: pick);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return ListTile(
      leading: const Icon(Icons.wallpaper_outlined),
      title: Text(t.chatBackground),
      subtitle: Text(switch (widget.core.setting(key: _kind)) {
        'plain' => t.backgroundPlain,
        'photo' => t.backgroundPhoto,
        _ => t.backgroundPattern,
      }),
      onTap: _choose,
    );
  }
}

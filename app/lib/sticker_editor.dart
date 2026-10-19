import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'themes.dart';

/// One caption on a sticker: where (as a fraction of the square), how big, which colour.
class _Caption {
  _Caption(this.text, this.color);
  String text;
  Color color;
  Offset at = const Offset(0.5, 0.82);
  double size = 0.11; // of the side
}

const _colors = [
  Colors.white,
  Colors.black,
  Color(0xFFFFD54F),
  Color(0xFFE53935),
  Color(0xFF1E88E5),
  Color(0xFF43A047),
];

/// Text over a sticker (imported, saved or made from a photo). Returns the edited sticker as a
/// 512 px PNG, or null when cancelled. Animated stickers keep their first frame.
class StickerEditor extends StatefulWidget {
  const StickerEditor({super.key, required this.image});
  final Uint8List image;

  @override
  State<StickerEditor> createState() => _StickerEditorState();
}

class _StickerEditorState extends State<StickerEditor> {
  final _captions = <_Caption>[];
  _Caption? _selected;
  bool _busy = false;

  Future<String?> _ask(String initial) {
    final t = AppLocalizations.of(context)!;
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t.stickerText),
        content: TextField(controller: c, autofocus: true, maxLength: 40),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(t.save)),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final text = await _ask('');
    if (text == null || text.isEmpty) return;
    setState(() {
      final c = _Caption(text, Colors.white);
      _captions.add(c);
      _selected = c;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final png = await renderSticker(widget.image, [for (final c in _captions) (c.text, c.color, c.at, c.size)]);
    if (mounted) Navigator.pop(context, png);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final sel = _selected;
    return Scaffold(
      appBar: SiegelBar(
        title: Text(t.editSticker),
        actions: [TextButton(onPressed: _busy ? null : _save, child: Text(t.save))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, box) {
                final side = box.maxWidth;
                return Stack(
                  children: [
                    Positioned.fill(child: Image.memory(widget.image, fit: BoxFit.contain, gaplessPlayback: true)),
                    for (final c in _captions)
                      Positioned(
                        left: c.at.dx * side - side / 2,
                        top: c.at.dy * side - c.size * side,
                        width: side,
                        child: GestureDetector(
                          onTap: () => setState(() => _selected = c),
                          onDoubleTap: () async {
                            final text = await _ask(c.text);
                            if (text != null && text.isNotEmpty) setState(() => c.text = text);
                          },
                          onPanUpdate: (d) => setState(() {
                            _selected = c;
                            c.at = Offset(
                              (c.at.dx + d.delta.dx / side).clamp(0.05, 0.95),
                              (c.at.dy + d.delta.dy / side).clamp(0.1, 0.98),
                            );
                          }),
                          child: _CaptionText(caption: c, side: side, selected: identical(c, sel)),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(t.stickerTextHelp, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(onPressed: _add, icon: const Icon(Icons.text_fields), label: Text(t.addText)),
          if (sel != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final col in _colors)
                  Semantics(
                    button: true,
                    selected: sel.color == col,
                    label: '#${col.toARGB32().toRadixString(16).substring(2)}',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => sel.color = col),
                      child: SizedBox.square(
                        dimension: 48,
                        child: Center(
                          child: CircleAvatar(
                            radius: sel.color == col ? 18 : 14,
                            backgroundColor: Theme.of(context).colorScheme.outline,
                            child: CircleAvatar(radius: sel.color == col ? 16 : 12, backgroundColor: col),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Slider(
              value: sel.size,
              min: 0.06,
              max: 0.22,
              label: t.textSize,
              onChanged: (v) => setState(() => sel.size = v),
            ),
            TextButton.icon(
              onPressed: () => setState(() {
                _captions.remove(sel);
                _selected = null;
              }),
              icon: const Icon(Icons.delete_outline),
              label: Text(t.removeText),
            ),
          ],
        ],
      ),
    );
  }
}

class _CaptionText extends StatelessWidget {
  const _CaptionText({required this.caption, required this.side, required this.selected});
  final _Caption caption;
  final double side;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final style = captionStyle(caption.color, caption.size * side);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: selected ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(caption.text, textAlign: TextAlign.center, style: style.$1),
          Text(caption.text, textAlign: TextAlign.center, style: style.$2),
        ],
      ),
    );
  }
}

/// Bold text with an outline in the opposite tone, so it reads on any sticker: (outline, fill).
(TextStyle, TextStyle) captionStyle(Color color, double size) {
  final edge = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  final base = TextStyle(fontFamily: 'Roboto', fontSize: size, fontWeight: FontWeight.w900, height: 1.1);
  return (
    base.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size / 6
        ..strokeJoin = StrokeJoin.round
        ..color = edge,
    ),
    base.copyWith(color: color),
  );
}

/// The sticker with its captions, drawn at 512 px as a PNG.
Future<Uint8List> renderSticker(Uint8List image, List<(String, Color, Offset, double)> captions) async {
  const side = 512.0;
  final codec = await ui.instantiateImageCodec(image);
  final img = (await codec.getNextFrame()).image;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final scale = side / (img.width > img.height ? img.width : img.height);
  final w = img.width * scale, h = img.height * scale;
  c.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    Rect.fromLTWH((side - w) / 2, (side - h) / 2, w, h),
    Paint()..filterQuality = FilterQuality.high,
  );
  for (final (text, color, at, size) in captions) {
    final (outline, fill) = captionStyle(color, size * side);
    for (final style in [outline, fill]) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: side);
      tp.paint(c, Offset(at.dx * side - tp.width / 2, at.dy * side - size * side));
    }
  }
  final out = await rec.endRecording().toImage(side.toInt(), side.toInt());
  return (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

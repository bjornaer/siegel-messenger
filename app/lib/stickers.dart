import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';
import 'sticker_editor.dart';

/// A sticker ready to send.
typedef StickerPick = ({Uint8List data, String mime});

/// The sticker sheet: the built-in Siegel pack, my stickers, GIFs (GIPHY), and imported packs.
/// Returns the sticker or GIF ('image/gif') to send, or null.
Future<StickerPick?> pickSticker(BuildContext context, Core core) => showModalBottomSheet<StickerPick>(
  context: context,
  isScrollControlled: true,
  builder: (c) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom), // the GIF search's keyboard
      child: SizedBox(height: 420, child: _StickerSheet(core: core)),
    ),
  ),
);

const _usesKey = 'sticker_uses';

class _StickerSheet extends StatefulWidget {
  const _StickerSheet({required this.core});
  final Core core;

  @override
  State<_StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends State<_StickerSheet> {
  Core get core => widget.core;

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  /// A photo becomes a sticker: the middle square, rounded, 512 px, WebP.
  Future<void> _fromPhoto() => _run(() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final square = await squareSticker(await file.readAsBytes());
    if (!mounted) return;
    // Straight into the editor: add a caption, or just save.
    final png = await Navigator.of(context)
        .push<Uint8List>(MaterialPageRoute(builder: (_) => StickerEditor(image: square)));
    if (png != null) await saveSticker(core, png);
  });

  /// Edit (text on top) or remove a stored sticker.
  Future<void> _options(String pack, StickerView s, Uint8List data) async {
    final t = AppLocalizations.of(context)!;
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: Text(t.editSticker),
              onTap: () => Navigator.pop(c, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(t.removeSticker),
              onTap: () => Navigator.pop(c, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (pick == 'remove') return _remove(pack, s.id);
    if (pick != 'edit') return;
    final png = await Navigator.of(context)
        .push<Uint8List>(MaterialPageRoute(builder: (_) => StickerEditor(image: data)));
    if (png != null) await _run(() => saveSticker(core, png)); // a new sticker; the original stays
  }

  /// Sticker files (WebP, PNG) and WhatsApp packs (.wastickers), several at once.
  Future<void> _import() => _run(() async {
    final t = AppLocalizations.of(context)!;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['webp', 'png', 'wastickers', 'zip'],
    );
    if (picked.isEmpty) return;
    try {
      final files = <(String, Uint8List)>[];
      for (final f in picked.take(120)) {
        if ((f.lengthSync() ?? 0) > 64 << 20) continue;
        files.add((f.name, await f.readAsBytes()));
      }
      final added = importStickerFiles(core, files);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.stickersAdded(added))));
      }
    } finally {
      unawaited(FilePicker.clearTemporaryFiles()); // the picker's plaintext copies in our cache
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final all = core.stickers();
    final packs = {for (final s in all) s.pack}..remove('');
    final mine = all.where((s) => s.pack.isEmpty).toList();
    final uses = _uses();
    final top = all.where((s) => (uses[s.id] ?? 0) > 0).toList()..sort((a, b) => uses[b.id]!.compareTo(uses[a.id]!));
    return DefaultTabController(
      length: 3 + packs.length,
      initialIndex: mine.isEmpty && top.isEmpty ? 0 : 1, // their own stickers first, once they have some
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Siegel'),
              Tab(text: t.myStickers),
              Tab(text: t.gifs),
              for (final p in packs) Tab(text: p),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                CustomScrollView(
                  slivers: [
                    _grid([
                      for (final id in siegelStickers)
                        _Cell(
                          label: id,
                          child: CustomPaint(painter: SiegelSticker(id)),
                          onTap: () async {
                            final png = await renderSiegelSticker(id);
                            if (context.mounted) Navigator.pop(context, (data: png, mime: 'image/png'));
                          },
                        ),
                    ]),
                  ],
                ),
                mine.isEmpty && top.isEmpty
                    ? Center(child: Text(t.noStickers, textAlign: TextAlign.center))
                    : _stored(mine, '', mostUsed: top.take(15).toList()),
                _Gifs(core: core),
                for (final p in packs) _stored(all.where((s) => s.pack == p).toList(), p),
              ],
            ),
          ),
          OverflowBar(
            alignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(t.stickerFromPhoto),
                onPressed: _fromPhoto,
              ),
              TextButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: Text(t.importStickers),
                onPressed: _import,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// How often each stored sticker was sent, kept in the encrypted database's settings.
  Map<String, int> _uses() {
    try {
      return (jsonDecode(core.setting(key: _usesKey) ?? '{}') as Map).cast<String, int>();
    } on Object {
      return {};
    }
  }

  void _send(StickerView s, Uint8List d) {
    final uses = _uses();
    uses[s.id] = (uses[s.id] ?? 0) + 1;
    core.setSetting(key: _usesKey, value: jsonEncode(uses));
    Navigator.pop(context, (data: d, mime: s.mimeType));
  }

  List<Widget> _cells(List<StickerView> list) {
    final t = AppLocalizations.of(context)!;
    return [
      for (final s in list)
        if (core.stickerData(id: s.id) case final d? when d.isNotEmpty)
          _Cell(
            label: t.sticker,
            child: Image.memory(d, fit: BoxFit.contain, gaplessPlayback: true),
            onTap: () => _send(s, d),
            onLongPress: () => _options(s.pack, s, d),
          ),
    ];
  }

  /// A pack's stickers; in Mine, the 15 most sent (from any pack) come first.
  Widget _stored(List<StickerView> list, String pack, {List<StickerView> mostUsed = const []}) {
    final t = AppLocalizations.of(context)!;
    final heading = Theme.of(context).textTheme.labelLarge;
    Widget title(String text) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Semantics(header: true, child: Text(text, style: heading)),
      ),
    );
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (mostUsed.isNotEmpty) ...[
                title(t.mostUsedStickers),
                _grid(_cells(mostUsed)),
                if (list.isNotEmpty) title(t.myStickers),
              ],
              _grid(_cells(list)),
            ],
          ),
        ),
        if (pack.isNotEmpty) TextButton(onPressed: () => _remove(pack, ''), child: Text(t.removeStickerPack(pack))),
      ],
    );
  }

  Future<void> _remove(String pack, String id) async {
    final t = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(id.isEmpty ? t.removeStickerPack(pack) : t.removeSticker),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok == true) await _run(() async => core.removeStickers(pack: pack, id: id));
  }

  Widget _grid(List<Widget> cells) => SliverPadding(
    padding: const EdgeInsets.all(8),
    sliver: SliverGrid.count(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8, children: cells),
  );
}

/// GIPHY search, trending until something is typed. Everything goes through our server
/// (server/gifs.go); the chosen GIF is then sent like a photo.
class _Gifs extends StatefulWidget {
  const _Gifs({required this.core});
  final Core core;

  @override
  State<_Gifs> createState() => _GifsState();
}

class _GifsState extends State<_Gifs> {
  final _previews = <String, Future<Uint8List>>{};
  List<String> _ids = [];
  String _query = '';
  bool _loading = false, _end = false, _failed = false, _sending = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      setState(() {
        _query = q.trim();
        _ids = [];
        _end = _failed = false;
      });
      _more();
    });
  }

  Future<void> _more() async {
    if (_loading || _end) return;
    final q = _query;
    setState(() => _loading = true);
    try {
      final page = await widget.core.gifSearch(query: q, offset: _ids.length);
      if (!mounted || q != _query) return;
      setState(() {
        _ids = [..._ids, ...page.where((id) => !_ids.contains(id))];
        _end = page.isEmpty;
      });
    } on Object {
      if (mounted && q == _query) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send(String id) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final gif = await widget.core.gif(id: id, full: true);
      if (mounted) Navigator.pop(context, (data: gif, mime: 'image/gif'));
    } on CoreError catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t.searchGifs, isDense: true),
            textInputAction: TextInputAction.search,
            onChanged: _search,
          ),
        ),
        if (_sending) const LinearProgressIndicator(),
        Expanded(
          child: _ids.isEmpty && !_loading
              ? Center(child: Text(_failed ? t.gifsUnavailable : t.noGifs, textAlign: TextAlign.center))
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 300) _more();
                    return false;
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemCount: _ids.length,
                    itemBuilder: (_, i) {
                      final id = _ids[i];
                      return _Cell(
                        label: t.gifs,
                        onTap: () => _send(id),
                        child: FutureBuilder(
                          future: _previews[id] ??= widget.core.gif(id: id, full: false),
                          builder: (_, s) => s.hasData
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
                                )
                              : ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                        ),
                      );
                    },
                  ),
                ),
        ),
        Tooltip(
          message: t.gifsPrivacy,
          triggerMode: TooltipTriggerMode.tap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text('Powered by GIPHY', style: Theme.of(context).textTheme.labelSmall),
          ),
        ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.child, required this.onTap, this.onLongPress});
  final String label;
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(padding: const EdgeInsets.all(4), child: child),
    ),
  );
}

/// A sticker edited or made here (PNG): kept as WebP when the phone can encode it.
Future<void> saveSticker(Core core, Uint8List png) async {
  final webp = await FlutterImageCompress.compressWithList(png, format: CompressFormat.webp, quality: 85);
  core.addSticker(data: webp.isNotEmpty ? webp : png, mimeType: webp.isNotEmpty ? 'image/webp' : 'image/png', pack: '');
}

/// Files picked or shared to Siegel: WebP or PNG stickers go to my stickers, .wastickers packs
/// become packs. Returns how many stickers were added; anything else is skipped.
int importStickerFiles(Core core, List<(String, Uint8List)> files) {
  var added = 0;
  for (final (name, bytes) in files) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.wastickers') || lower.endsWith('.zip')) {
      added += importStickerPack(core, bytes, fallbackName: name.replaceAll(RegExp(r'\.[^.]*$'), ''));
      continue;
    }
    final mime = _isWebp(bytes)
        ? 'image/webp'
        : _isPng(bytes)
        ? 'image/png'
        : null;
    if (mime == null) continue;
    try {
      core.addSticker(data: bytes, mimeType: mime, pack: '');
      added++;
    } on CoreError {
      // too large: skip it
    }
  }
  return added;
}

bool _isWebp(Uint8List b) =>
    b.length > 12 &&
    String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
    String.fromCharCodes(b.sublist(8, 12)) == 'WEBP';
bool _isPng(Uint8List b) => b.length > 8 && b[0] == 0x89 && String.fromCharCodes(b.sublist(1, 4)) == 'PNG';

/// Adds every WebP sticker in a .wastickers zip as one pack; returns how many.
int importStickerPack(Core core, Uint8List zip, {required String fallbackName}) {
  final Archive files;
  try {
    files = ZipDecoder().decodeBytes(zip);
  } on Object {
    return 0;
  }
  String text(String name) {
    final f = files.findFile(name);
    return f == null ? '' : utf8.decode(f.content, allowMalformed: true).trim();
  }

  final title = text('title.txt');
  final pack = (title.isEmpty ? fallbackName : title).characters.take(40).toString();
  var added = 0;
  for (final f in files.files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.webp')).take(120)) {
    try {
      core.addSticker(data: f.content, mimeType: 'image/webp', pack: pack);
      added++;
    } on CoreError {
      // too large or empty: skip it, keep the rest
    }
  }
  return added;
}

/// The middle square of a photo, rounded, as a 512 px PNG with a transparent outside.
Future<Uint8List> squareSticker(Uint8List photo) async {
  final codec = await ui.instantiateImageCodec(photo);
  final img = (await codec.getNextFrame()).image;
  final side = math.min(img.width, img.height).toDouble();
  final src = Rect.fromLTWH((img.width - side) / 2, (img.height - side) / 2, side, side);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.clipRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 512, 512), const Radius.circular(64)));
  c.drawImageRect(img, src, const Rect.fromLTWH(0, 0, 512, 512), Paint()..filterQuality = FilterQuality.high);
  final out = await rec.endRecording().toImage(512, 512);
  return (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// The built-in pack, drawn in code.
const siegelStickers = [
  'seal', 'hallo', 'danke', 'servus', 'ja', 'nein', //
  'edelweiss', 'snowflake', 'crown', 'flame', 'horns', 'mountain',
];

Future<Uint8List> renderSiegelSticker(String id) async {
  final rec = ui.PictureRecorder();
  SiegelSticker(id).paint(Canvas(rec), const Size.square(512));
  final img = await rec.endRecording().toImage(512, 512);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// One sticker of the Siegel pack: a coloured shape with a white sticker edge and a soft
/// shadow, designed on a 100-unit square.
class SiegelSticker extends CustomPainter {
  SiegelSticker(this.id);
  final String id;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100);
    switch (id) {
      case 'seal':
        _seal(canvas);
      case 'hallo':
        _bubble(canvas, 'Hallo!', const Color(0xFF2F8F4E));
      case 'danke':
        _heart(canvas, 'Danke');
      case 'servus':
        _bubble(canvas, 'Servus!', const Color(0xFF1F6FB2));
      case 'ja':
        _badge(canvas, 'Ja!', const Color(0xFF2E9D4A), check: true);
      case 'nein':
        _badge(canvas, 'Nein', const Color(0xFFC62828), check: false);
      case 'edelweiss':
        _edelweiss(canvas);
      case 'snowflake':
        _snowflake(canvas);
      case 'crown':
        _crown(canvas);
      case 'flame':
        _flame(canvas);
      case 'horns':
        _horns(canvas);
      case 'mountain':
        _mountain(canvas);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SiegelSticker old) => old.id != id;

  /// White sticker edge and shadow behind [path], then the fill.
  static void _shape(Canvas c, Path path, Paint fill) {
    c.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    c.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeJoin = StrokeJoin.round,
    );
    c.drawPath(path, fill);
  }

  /// Centred bold text, shrunk to fit [maxWidth].
  static void _text(
    Canvas c,
    String s,
    Offset center,
    double size, {
    Color color = Colors.white,
    double maxWidth = 72,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontFamily: 'Roboto', color: color, fontSize: size, fontWeight: FontWeight.w900),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final k = math.min(1.0, maxWidth / tp.width);
    c.save();
    c.translate(center.dx, center.dy);
    c.scale(k);
    tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
    c.restore();
  }

  static Path _circle(Offset o, double r) => Path()..addOval(Rect.fromCircle(center: o, radius: r));

  void _seal(Canvas c) {
    final rim = Path();
    for (var i = 0; i <= 96; i++) {
      final a = i / 96 * 2 * math.pi;
      final r = 40 + 3.5 * math.sin(a * 14);
      final o = Offset(50 + r * math.cos(a), 50 + r * math.sin(a));
      i == 0 ? rim.moveTo(o.dx, o.dy) : rim.lineTo(o.dx, o.dy);
    }
    _shape(c, rim..close(), Paint()..color = const Color(0xFFB3182F));
    c.drawCircle(const Offset(50, 50), 29, Paint()..color = const Color(0xFF8E1024));
    c.drawCircle(
      const Offset(50, 50),
      29,
      Paint()
        ..color = const Color(0xFFE8B04A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _text(c, 'S', const Offset(50, 50), 36, color: const Color(0xFFE8B04A));
  }

  void _bubble(Canvas c, String word, Color color) {
    final p = Path()
      ..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(8, 18, 84, 52), const Radius.circular(20)))
      ..moveTo(26, 66)
      ..lineTo(20, 86)
      ..lineTo(40, 68)
      ..close();
    _shape(c, p, Paint()..color = color);
    _text(c, word, const Offset(50, 44), 19);
  }

  void _heart(Canvas c, String word) {
    final p = Path()
      ..moveTo(50, 88)
      ..cubicTo(10, 62, 4, 36, 18, 22)
      ..cubicTo(30, 10, 46, 16, 50, 30)
      ..cubicTo(54, 16, 70, 10, 82, 22)
      ..cubicTo(96, 36, 90, 62, 50, 88)
      ..close();
    _shape(c, p, Paint()..color = const Color(0xFFE91E63));
    _text(c, word, const Offset(50, 46), 17);
  }

  void _badge(Canvas c, String word, Color color, {required bool check}) {
    _shape(c, _circle(const Offset(50, 50), 40), Paint()..color = color);
    final mark = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    if (check) {
      c.drawPath(
        Path()
          ..moveTo(32, 40)
          ..lineTo(44, 52)
          ..lineTo(68, 28),
        mark,
      );
    } else {
      c.drawLine(const Offset(36, 26), const Offset(64, 54), mark);
      c.drawLine(const Offset(64, 26), const Offset(36, 54), mark);
    }
    _text(c, word, const Offset(50, 71), 16);
  }

  void _edelweiss(Canvas c) {
    _shape(c, _circle(const Offset(50, 50), 44), Paint()..color = const Color(0xFF2F543B));
    final petals = Path();
    for (var i = 0; i < 9; i++) {
      final a = i * 2 * math.pi / 9 - math.pi / 2;
      Offset at(double r, double da) => Offset(50 + r * math.cos(a + da), 50 + r * math.sin(a + da));
      final (l, tip, r) = (at(12, -0.5), at(40, 0), at(12, 0.5));
      petals
        ..moveTo(l.dx, l.dy)
        ..quadraticBezierTo(at(30, -0.28).dx, at(30, -0.28).dy, tip.dx, tip.dy)
        ..quadraticBezierTo(at(30, 0.28).dx, at(30, 0.28).dy, r.dx, r.dy)
        ..close();
    }
    c.drawPath(petals, Paint()..color = const Color(0xFFF4F4EE));
    c.drawPath(
      petals,
      Paint()
        ..color = const Color(0xFFB9BDB0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (final o in [
      const Offset(45, 46), const Offset(55, 46), const Offset(50, 55), //
      const Offset(50, 42), const Offset(44, 54), const Offset(56, 54),
    ]) {
      c.drawCircle(o, 4.5, Paint()..color = const Color(0xFFE3C55A));
    }
  }

  void _snowflake(Canvas c) {
    final p = Path();
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      Offset at(double r, double da) => Offset(50 + r * math.cos(a + da), 50 + r * math.sin(a + da));
      p
        ..moveTo(50, 50)
        ..lineTo(at(42, 0).dx, at(42, 0).dy);
      for (final r in [22.0, 32.0]) {
        p
          ..moveTo(at(r, 0).dx, at(r, 0).dy)
          ..lineTo(at(r + 9, 0.32).dx, at(r + 9, 0.32).dy)
          ..moveTo(at(r, 0).dx, at(r, 0).dy)
          ..lineTo(at(r + 9, -0.32).dx, at(r + 9, -0.32).dy);
      }
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    c.drawPath(
      p,
      stroke
        ..color = Colors.white
        ..strokeWidth = 13,
    );
    c.drawPath(
      p,
      Paint()
        ..color = const Color(0xFF4FA3E0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  void _crown(Canvas c) {
    final p = Path()
      ..moveTo(14, 74)
      ..lineTo(10, 30)
      ..lineTo(32, 48)
      ..lineTo(50, 18)
      ..lineTo(68, 48)
      ..lineTo(90, 30)
      ..lineTo(86, 74)
      ..close();
    _shape(c, p, Paint()..color = const Color(0xFFE8B04A));
    c.drawRect(const Rect.fromLTWH(14, 66, 72, 8), Paint()..color = const Color(0xFFC8962E));
    for (final (o, col) in [
      (const Offset(50, 56), const Color(0xFFB3182F)),
      (const Offset(32, 60), const Color(0xFF1F6FB2)),
      (const Offset(68, 60), const Color(0xFF2E9D4A)),
    ]) {
      c.drawCircle(o, 5, Paint()..color = col);
    }
  }

  void _flame(Canvas c) {
    final outer = Path()
      ..moveTo(50, 92)
      ..cubicTo(20, 86, 14, 58, 30, 40)
      ..cubicTo(34, 50, 40, 52, 42, 48)
      ..cubicTo(38, 30, 50, 16, 58, 8)
      ..cubicTo(60, 26, 84, 40, 80, 66)
      ..cubicTo(78, 84, 64, 92, 50, 92)
      ..close();
    _shape(c, outer, Paint()..color = const Color(0xFFE8631E));
    c.drawPath(
      Path()
        ..moveTo(52, 88)
        ..cubicTo(36, 84, 34, 66, 46, 54)
        ..cubicTo(48, 62, 54, 62, 56, 58)
        ..cubicTo(68, 66, 68, 86, 52, 88)
        ..close(),
      Paint()..color = const Color(0xFFFFD54F),
    );
  }

  void _horns(Canvas c) {
    Path horn(double s) => Path()
      ..moveTo(50 + 6 * s, 74)
      ..cubicTo(50 + 14 * s, 44, 50 + 26 * s, 26, 50 + 44 * s, 10)
      ..cubicTo(50 + 36 * s, 34, 50 + 32 * s, 56, 50 + 30 * s, 78)
      ..close();
    final both = Path()
      ..addPath(horn(-1), Offset.zero)
      ..addPath(horn(1), Offset.zero);
    _shape(c, both, Paint()..color = const Color(0xFF5C1A12));
    _shape(
      c,
      Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(12, 70, 76, 16), const Radius.circular(8))),
      Paint()..color = const Color(0xFFC2410C),
    );
  }

  void _mountain(Canvas c) {
    c.drawCircle(const Offset(74, 26), 12, Paint()..color = const Color(0xFFFFCA28));
    final p = Path()
      ..moveTo(6, 84)
      ..lineTo(40, 24)
      ..lineTo(56, 50)
      ..lineTo(66, 38)
      ..lineTo(94, 84)
      ..close();
    _shape(c, p, Paint()..color = const Color(0xFF35618E));
    c.drawPath(
      Path()
        ..moveTo(31, 40)
        ..lineTo(40, 24)
        ..lineTo(49, 40)
        ..lineTo(44, 36)
        ..lineTo(40, 42)
        ..lineTo(36, 36)
        ..close(),
      Paint()..color = Colors.white,
    );
  }
}

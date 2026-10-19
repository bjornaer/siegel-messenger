import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';

/// What stands in for a message in the chat list, quotes and notifications.
String messageText(AppLocalizations t, MessageView m) {
  final a = m.attachment;
  if (a == null) return m.text;
  if (a.voiceNote) return '🎤 ${t.voiceMessage} (${formatDuration(a.durationMs)})';
  if (a.sticker) return '💟 ${t.sticker}';
  return switch (kindOf(a)) {
    AttachmentKind.audio => '🎵 ${a.fileName}',
    AttachmentKind.image => '📷 ${t.photo}',
    AttachmentKind.video => '🎥 ${t.video} (${formatDuration(a.durationMs)})',
    AttachmentKind.file => '📄 ${a.fileName}',
  };
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// MED-09: 64 bars from loudness samples in dBFS (-60 dB and quieter is silence), 0-255 each.
Uint8List waveform(List<double> dbfs, [int bars = 64]) {
  if (dbfs.isEmpty) return Uint8List(0);
  final out = Uint8List(min(bars, dbfs.length));
  for (var i = 0; i < out.length; i++) {
    final slice = dbfs.sublist(i * dbfs.length ~/ out.length, (i + 1) * dbfs.length ~/ out.length);
    final loudest = slice.reduce(max);
    out[i] = (((loudest + 60) / 60).clamp(0.0, 1.0) * 255).round();
  }
  return out;
}

typedef Recording = ({Uint8List data, int ms, Uint8List waveform});

/// MED-09: AAC-LC in M4A from the platform encoder. The recording sits in the app's cache only
/// until it is sent or cancelled.
class VoiceRecorder {
  final _rec = AudioRecorder();
  final _levels = <double>[];
  final _watch = Stopwatch();
  StreamSubscription<Amplitude>? _sub;

  Duration get elapsed => _watch.elapsed;

  /// False when the microphone permission was refused.
  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: '${dir.path}/voice-${DateTime.now().microsecondsSinceEpoch}.m4a',
    );
    _sub = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) => _levels.add(a.current));
    _watch
      ..reset()
      ..start();
    return true;
  }

  /// Ends the recording and deletes its file; null when [keep] is false.
  Future<Recording?> stop({bool keep = true}) async {
    _watch.stop();
    await _sub?.cancel();
    final path = await _rec.stop();
    if (path == null) return null;
    final f = File(path);
    try {
      return keep ? (data: await f.readAsBytes(), ms: _watch.elapsedMilliseconds, waveform: waveform(_levels)) : null;
    } finally {
      _levels.clear();
      if (await f.exists()) await f.delete();
    }
  }

  void dispose() => unawaited(_rec.dispose());
}

/// A voice note or audio file in a bubble: downloads on first play (MED-12: audio is manual),
/// plays from memory, one at a time.
class AudioMessage extends StatefulWidget {
  const AudioMessage({super.key, required this.core, required this.message});

  final Core core;
  final MessageView message;

  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  static const _waveWidth = 176.0; // the bubble's width less the play button
  static _AudioMessageState? _playing;
  AudioPlayer? _player;
  Uint8List? _data;
  bool _loading = false;
  Duration _pos = Duration.zero;
  Duration? _len;

  AttachmentView get _a => widget.message.attachment!;
  bool get _isPlaying => _player?.state == PlayerState.playing;

  @override
  void dispose() {
    if (_playing == this) _playing = null;
    unawaited(_player?.dispose());
    super.dispose();
  }

  AudioPlayer _ensurePlayer() => _player ??= AudioPlayer()
    ..onPositionChanged.listen((p) => mounted ? setState(() => _pos = p) : null)
    ..onDurationChanged.listen((d) => mounted ? setState(() => _len = d) : null)
    ..onPlayerStateChanged.listen((_) => mounted ? setState(() {}) : null)
    ..onPlayerComplete.listen((_) => mounted ? setState(() => _pos = Duration.zero) : null);

  Future<void> _toggle() async {
    if (_isPlaying) return _player!.pause();
    if (_data == null) {
      setState(() => _loading = true);
      try {
        _data = await widget.core.attachmentData(messageId: widget.message.messageId);
      } on CoreError catch (e) {
        if (mounted) showError(context, e);
        return;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    if (_playing != this) await _playing?._player?.pause();
    _playing = this;
    final p = _ensurePlayer();
    if (p.state == PlayerState.paused) return p.resume();
    await p.play(BytesSource(_data!, mimeType: _a.mimeType));
  }

  Future<void> _seek(double fraction) async {
    final len = _len;
    if (len != null && _player != null) await _player!.seek(len * fraction);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final total = _len?.inMilliseconds ?? _a.durationMs;
    final progress = total > 0 ? (_pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    return SizedBox(
      width: 240,
      child: Row(
        children: [
          _loading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  tooltip: _isPlaying ? t.pause : t.play,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: _toggle,
                ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_a.voiceNote) Text(_a.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                GestureDetector(
                  excludeFromSemantics: true, // seeking by touch; Play and Pause are the accessible controls
                  onTapDown: (d) => _seek((d.localPosition.dx / _waveWidth).clamp(0.0, 1.0)),
                  child: _a.waveform.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: SizedBox(
                            width: _waveWidth,
                            child: LinearProgressIndicator(value: progress),
                          ),
                        )
                      : CustomPaint(
                          size: const Size(_waveWidth, 28),
                          painter: _WaveformPainter(_a.waveform, progress, colors.primary, colors.outline),
                        ),
                ),
                Text(
                  formatDuration(_isPlaying || _pos > Duration.zero ? _pos.inMilliseconds : total),
                  style: Theme.of(context).textTheme.labelSmall,
                  // CMP-05: "Voice message, 0:04", not just a time.
                  semanticsLabel: _a.voiceNote ? '${t.voiceMessage}, ${formatDuration(total)}' : formatDuration(total),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.bars, this.progress, this.played, this.rest);

  final Uint8List bars;
  final double progress;
  final Color played, rest;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / bars.length;
    final paint = Paint()
      ..strokeWidth = max(1.5, step * 0.6)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars.length; i++) {
      final h = max(2.0, bars[i] / 255 * size.height);
      final x = step * (i + 0.5);
      paint.color = (i + 0.5) / bars.length <= progress ? played : rest;
      canvas.drawLine(Offset(x, (size.height - h) / 2), Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.progress != progress || old.bars != bars;
}

/// Something picked to send, ready for Core.sendAttachment.
typedef Outgoing = ({
  Uint8List data,
  String mime,
  String name,
  int ms,
  int width,
  int height,
  Uint8List thumbnail,
  bool voice,
  Uint8List waveform,
  bool sticker,
});

Outgoing outgoing(
  Uint8List data,
  String mime, {
  String name = '',
  int ms = 0,
  int width = 0,
  int height = 0,
  Uint8List? thumbnail,
  bool voice = false,
  Uint8List? waveform,
  bool sticker = false,
}) => (
  data: data,
  mime: mime,
  name: name,
  ms: ms,
  width: width,
  height: height,
  thumbnail: thumbnail ?? Uint8List(0),
  voice: voice,
  waveform: waveform ?? Uint8List(0),
  sticker: sticker,
);

const maxAttachment = 100 << 20; // MED-06

class TooLarge implements Exception {}

const _mimes = {
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'txt': 'text/plain',
};

String mimeFor(String name) => _mimes[name.split('.').last.toLowerCase()] ?? 'application/octet-stream';

/// MED-04: a JPEG preview of at most 20 KB.
Future<Uint8List> thumbnailOf(Uint8List image) async {
  for (final (side, q) in [(160, 60), (120, 45), (80, 35)]) {
    final t = await FlutterImageCompress.compressWithList(image, minWidth: side, minHeight: side, quality: q);
    if (t.length <= 20 << 10) return t;
  }
  return Uint8List(0);
}

Future<(int, int)> sizeOf(Uint8List image) async {
  final d = await ui.ImageDescriptor.encoded(await ui.ImmutableBuffer.fromUint8List(image));
  final s = (d.width, d.height);
  d.dispose();
  return s;
}

/// MED-07, MED-11: a photo from the gallery, compressed to at most 2048 px as JPEG with no EXIF
/// (so no location). GIFs go as they are, to stay animated.
Future<Outgoing?> pickPhoto() async {
  final f = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (f == null) return null;
  final raw = await f.readAsBytes();
  final gif = f.name.toLowerCase().endsWith('.gif');
  if (gif && raw.length > maxAttachment) throw TooLarge();
  final data = gif
      ? raw
      : await FlutterImageCompress.compressWithList(raw, minWidth: 2048, minHeight: 2048, quality: 82, keepExif: false);
  final (w, h) = await sizeOf(data);
  return outgoing(data, gif ? 'image/gif' : 'image/jpeg', width: w, height: h, thumbnail: await thumbnailOf(data));
}

/// MED-08: a video from the gallery, compressed when the sender chooses or must (over 100 MB).
Future<Outgoing?> pickVideo(Future<bool?> Function(bool mustCompress) askCompress) async {
  final f = await ImagePicker().pickVideo(source: ImageSource.gallery);
  if (f == null) return null;
  final compress = await askCompress(await f.length() > maxAttachment);
  if (compress == null) return null;
  // Length and size from the original: the compressed copy may lack them.
  final info = await VideoCompress.getMediaInfo(f.path);
  File? compressed;
  try {
    if (compress) {
      final out = await VideoCompress.compressVideo(f.path, quality: VideoQuality.MediumQuality, includeAudio: true);
      if (out?.path == null) return null;
      compressed = File(out!.path!);
    }
    final file = compressed ?? File(f.path);
    if (await file.length() > maxAttachment) throw TooLarge();
    final still = await VideoCompress.getByteThumbnail(f.path, quality: 60);
    final portrait = info.orientation == 90 || info.orientation == 270;
    return outgoing(
      await file.readAsBytes(),
      mimeFor(f.path) == 'video/quicktime' && !compress ? 'video/quicktime' : 'video/mp4',
      ms: (info.duration ?? 0).round(),
      width: (portrait ? info.height : info.width) ?? 0,
      height: (portrait ? info.width : info.height) ?? 0,
      thumbnail: still == null ? null : await thumbnailOf(still),
    );
  } finally {
    compressed?.delete().ignore(); // the plugin's deleteAllCache crashes (video_compress 3.1.4)
  }
}

/// MED-10 (and MED-09 audio files): any file, sent unchanged.
Future<Outgoing?> pickFile({bool audio = false}) async {
  final f = await FilePicker.pickFile(type: audio ? FileType.audio : FileType.any);
  if (f == null) return null;
  if ((f.lengthSync() ?? 0) > maxAttachment) throw TooLarge(); // before reading it all
  try {
    return outgoing(await f.readAsBytes(), mimeFor(f.name), name: f.name);
  } finally {
    unawaited(FilePicker.clearTemporaryFiles()); // the picker's plaintext copy in our cache
  }
}

enum AttachmentKind { audio, image, video, file }

AttachmentKind kindOf(AttachmentView a) => a.voiceNote || a.mimeType.startsWith('audio/')
    ? AttachmentKind.audio
    : a.mimeType.startsWith('image/')
    ? AttachmentKind.image
    : a.mimeType.startsWith('video/')
    ? AttachmentKind.video
    : AttachmentKind.file;

String formatSize(int bytes) =>
    bytes < 1 << 20 ? '${(bytes / 1024).ceil()} KB' : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

/// MED-12: which kinds download by themselves, per network. Stored as core settings.
const _autoDefaults = {'auto_wifi': 'image', 'auto_mobile': 'image'};

Set<String> autoDownloadKinds(Core core, {required bool metered}) {
  final key = metered ? 'auto_mobile' : 'auto_wifi';
  final v = core.setting(key: key) ?? _autoDefaults[key]!;
  return v.split(',').where((s) => s.isNotEmpty).toSet();
}

void setAutoDownloadKinds(Core core, {required bool metered, required Set<String> kinds}) =>
    core.setSetting(key: metered ? 'auto_mobile' : 'auto_wifi', value: kinds.join(','));

const _app = MethodChannel('siegel/app');

Future<bool> isMetered() async {
  try {
    return await _app.invokeMethod<bool>('metered') ?? true;
  } on Object {
    return true; // unknown: be careful with data
  }
}

/// MED-12: fetches a new attachment ahead of time when the settings allow it on this network.
Future<void> autoDownload(Core core, MessageView m) async {
  final a = m.attachment;
  if (a == null || a.voiceNote) return; // voice notes download on play
  // Nothing from people not yet accepted downloads by itself (M7).
  if (core.chats().any((c) => c.request && listEquals(c.groupId, m.groupId))) return;
  final kind = switch (kindOf(a)) {
    AttachmentKind.image => 'image',
    AttachmentKind.video => 'video',
    _ => 'file',
  };
  if (!autoDownloadKinds(core, metered: await isMetered()).contains(kind)) return;
  try {
    await core.attachmentData(messageId: m.messageId);
  } on Object {
    // Shown as not downloaded; the user can tap to retry.
  }
}

/// Lets the user keep a received file: the system's save dialog, nothing opened automatically.
Future<void> saveToDevice(BuildContext context, Core core, MessageView m) async {
  try {
    final data = await core.attachmentData(messageId: m.messageId);
    final a = m.attachment!;
    final name = a.fileName.isNotEmpty
        ? a.fileName
        : 'siegel-${DateTime.now().millisecondsSinceEpoch}.${_ext(a.mimeType)}';
    await FilePicker.saveFile(fileName: name, bytes: data);
  } on CoreError catch (e) {
    if (context.mounted) showError(context, e);
  }
}

String _ext(String mime) =>
    _mimes.entries.firstWhere((e) => e.value == mime, orElse: () => const MapEntry('bin', '')).key;

/// Fetches an attachment for a bubble: spinner while loading, errors as snackbars.
mixin _Fetch<T extends StatefulWidget> on State<T> {
  Uint8List? data;
  bool loading = false;

  Future<Uint8List?> fetch(Core core, MessageView m) async {
    if (data != null) return data;
    setState(() => loading = true);
    try {
      data = await core.attachmentData(messageId: m.messageId);
      return data;
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
      return null;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
}

class _Held extends StatefulWidget {
  const _Held({required this.core, required this.message});
  final Core core;
  final MessageView message;

  @override
  State<_Held> createState() => _HeldState();
}

class _HeldState extends State<_Held> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    if (_shown) return _attachmentView(widget.core, widget.message);
    final t = AppLocalizations.of(context)!;
    final thumb = widget.message.attachment!.thumbnail;
    return Semantics(
      button: true,
      label: t.tapToView,
      child: InkWell(
        onTap: () => setState(() => _shown = true),
        child: SizedBox(
          width: 220,
          height: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumb.isNotEmpty)
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Image.memory(thumb, fit: BoxFit.cover, excludeFromSemantics: true),
                  )
                else
                  ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHigh),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: ExcludeSemantics(
                          child: Text(
                            t.tapToView,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sticker: large, no bubble. Stickers are small, so they always download by themselves.
class StickerMessage extends StatefulWidget {
  const StickerMessage({super.key, required this.core, required this.message});
  final Core core;
  final MessageView message;

  @override
  State<StickerMessage> createState() => _StickerMessageState();
}

class _StickerMessageState extends State<StickerMessage> with _Fetch {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) fetch(widget.core, widget.message);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final d = data;
    return SizedBox.square(
      dimension: 160,
      child: d == null
          ? Center(
              child: loading ? const CircularProgressIndicator() : Icon(Icons.image_outlined, semanticLabel: t.sticker),
            )
          : Image.memory(d, fit: BoxFit.contain, gaplessPlayback: true, semanticLabel: t.sticker),
    );
  }
}

/// MED-07: a photo in a bubble: the preview until downloaded (auto or on tap), then the photo.
class ImageMessage extends StatefulWidget {
  const ImageMessage({super.key, required this.core, required this.message});
  final Core core;
  final MessageView message;

  @override
  State<ImageMessage> createState() => _ImageMessageState();
}

class _ImageMessageState extends State<ImageMessage> with _Fetch {
  @override
  void initState() {
    super.initState();
    if (widget.core.attachmentDownloaded(messageId: widget.message.messageId)) fetch(widget.core, widget.message);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final a = widget.message.attachment!;
    final ratio = a.width > 0 && a.height > 0 ? (a.width / a.height).clamp(0.5, 2.0) : 1.0;
    final shown = data ?? (a.thumbnail.isEmpty ? null : a.thumbnail);
    return GestureDetector(
      onTap: () async {
        // The first tap only downloads, into the bubble; a downloaded photo opens full screen.
        final had = data != null;
        final d = await fetch(widget.core, widget.message);
        if (had && d != null && context.mounted) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _PhotoScreen(core: widget.core, message: widget.message, data: d),
            ),
          );
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 240,
          child: AspectRatio(
            aspectRatio: ratio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (shown != null)
                  Image.memory(shown, fit: BoxFit.cover, gaplessPlayback: true, semanticLabel: t.photo)
                else
                  ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHigh),
                if (data == null)
                  Center(
                    child: loading
                        ? const CircularProgressIndicator()
                        : CircleAvatar(
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.download, color: Colors.white, semanticLabel: t.download),
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoScreen extends StatelessWidget {
  const _PhotoScreen({required this.core, required this.message, required this.data});
  final Core core;
  final MessageView message;
  final Uint8List data;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: t.saveToDevice,
            icon: const Icon(Icons.download),
            onPressed: () => saveToDevice(context, core, message),
          ),
        ],
      ),
      body: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(data))),
    );
  }
}

/// MED-08: a video in a bubble: its preview and length; tap to download and play.
class VideoMessage extends StatefulWidget {
  const VideoMessage({super.key, required this.core, required this.message});
  final Core core;
  final MessageView message;

  @override
  State<VideoMessage> createState() => _VideoMessageState();
}

class _VideoMessageState extends State<VideoMessage> with _Fetch {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final a = widget.message.attachment!;
    final ratio = a.width > 0 && a.height > 0 ? (a.width / a.height).clamp(0.5, 2.0) : 16 / 9;
    final ready = data != null || widget.core.attachmentDownloaded(messageId: widget.message.messageId);
    return GestureDetector(
      onTap: () async {
        final d = await fetch(widget.core, widget.message);
        if (d != null && context.mounted) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _VideoScreen(core: widget.core, message: widget.message, data: d),
            ),
          );
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 240,
          child: AspectRatio(
            aspectRatio: ratio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (a.thumbnail.isNotEmpty)
                  Image.memory(a.thumbnail, fit: BoxFit.cover)
                else
                  const ColoredBox(color: Colors.black),
                Center(
                  child: loading
                      ? const CircularProgressIndicator()
                      : CircleAvatar(
                          radius: 24,
                          backgroundColor: Colors.black54,
                          child: Icon(
                            ready ? Icons.play_arrow : Icons.download,
                            color: Colors.white,
                            semanticLabel: ready ? t.play : t.download,
                          ),
                        ),
                ),
                Positioned(
                  left: 8,
                  bottom: 6,
                  child: Text(
                    ready
                        ? formatDuration(a.durationMs)
                        : '${formatDuration(a.durationMs)} · ${formatSize(a.size.toInt())}',
                    style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plays from a temporary file (the player can't read memory), deleted when the screen closes.
class _VideoScreen extends StatefulWidget {
  const _VideoScreen({required this.core, required this.message, required this.data});
  final Core core;
  final MessageView message;
  final Uint8List data;

  @override
  State<_VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<_VideoScreen> {
  File? _file;
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    () async {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/play-${DateTime.now().microsecondsSinceEpoch}');
      await f.writeAsBytes(widget.data, flush: true);
      _file = f;
      final p = VideoPlayerController.file(f);
      await p.initialize();
      if (!mounted) return p.dispose();
      setState(() => _player = p);
      await p.play();
    }();
  }

  @override
  void dispose() {
    _player?.dispose();
    _file?.delete().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final p = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: t.saveToDevice,
            icon: const Icon(Icons.download),
            onPressed: () => saveToDevice(context, widget.core, widget.message),
          ),
        ],
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
              onTap: () => setState(() => p.value.isPlaying ? p.pause() : p.play()),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p)),
                    ),
                  ),
                  VideoProgressIndicator(p, allowScrubbing: true, padding: const EdgeInsets.all(16)),
                ],
              ),
            ),
    );
  }
}

/// MED-10: any other file: name and size; tap to download and save. Never opened automatically.
class FileMessage extends StatefulWidget {
  const FileMessage({super.key, required this.core, required this.message});
  final Core core;
  final MessageView message;

  @override
  State<FileMessage> createState() => _FileMessageState();
}

class _FileMessageState extends State<FileMessage> with _Fetch {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final a = widget.message.attachment!;
    return GestureDetector(
      onTap: () async {
        if (await fetch(widget.core, widget.message) != null && context.mounted) {
          await saveToDevice(context, widget.core, widget.message);
        }
      },
      child: SizedBox(
        width: 240,
        child: Row(
          children: [
            loading
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.insert_drive_file_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(formatSize(a.size.toInt()), style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
            Icon(Icons.download, semanticLabel: t.saveToDevice),
          ],
        ),
      ),
    );
  }
}

/// Picks what goes in a bubble for an attachment.
/// [held]: from someone not yet accepted (a message request). Photos, videos and stickers stay
/// blurred and undownloaded until tapped (M7, docs/csa-risk-assessment.md).
Widget attachmentView(Core core, MessageView m, {bool held = false}) =>
    held &&
        (m.attachment!.sticker || const {AttachmentKind.image, AttachmentKind.video}.contains(kindOf(m.attachment!)))
    ? _Held(core: core, message: m)
    : _attachmentView(core, m);

Widget _attachmentView(Core core, MessageView m) => m.attachment!.sticker
    ? StickerMessage(core: core, message: m)
    : switch (kindOf(m.attachment!)) {
        AttachmentKind.audio => AudioMessage(core: core, message: m),
        AttachmentKind.image => ImageMessage(core: core, message: m),
        AttachmentKind.video => VideoMessage(core: core, message: m),
        AttachmentKind.file => FileMessage(core: core, message: m),
      };

/// MED-12 in Settings: per network, which kinds download by themselves.
class AutoDownloadTile extends StatefulWidget {
  const AutoDownloadTile({super.key, required this.core});
  final Core core;

  @override
  State<AutoDownloadTile> createState() => _AutoDownloadTileState();
}

class _AutoDownloadTileState extends State<AutoDownloadTile> {
  String _summary(AppLocalizations t, bool metered) {
    final k = autoDownloadKinds(widget.core, metered: metered);
    final names = [
      if (k.contains('image')) t.photos,
      if (k.contains('video')) t.videos,
      if (k.contains('file')) t.files,
    ];
    return '${metered ? t.onMobile : t.onWifi}: ${names.isEmpty ? t.none : names.join(', ')}';
  }

  Future<void> _edit() async {
    await showDialog<void>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) {
          final t = AppLocalizations.of(d)!;
          return AlertDialog(
            title: Text(t.autoDownload),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.autoDownloadHelp),
                  for (final metered in [false, true]) ...[
                    const SizedBox(height: 12),
                    Text(metered ? t.onMobile : t.onWifi, style: Theme.of(d).textTheme.titleSmall),
                    for (final (kind, label) in [('image', t.photos), ('video', t.videos), ('file', t.files)])
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(label),
                        value: autoDownloadKinds(widget.core, metered: metered).contains(kind),
                        onChanged: (on) => set(() {
                          final k = autoDownloadKinds(widget.core, metered: metered);
                          on == true ? k.add(kind) : k.remove(kind);
                          setAutoDownloadKinds(widget.core, metered: metered, kinds: k);
                        }),
                      ),
                  ],
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(t.close))],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return ListTile(
      leading: const Icon(Icons.downloading),
      title: Text(t.autoDownload),
      subtitle: Text('${_summary(t, false)}\n${_summary(t, true)}'),
      isThreeLine: true,
      onTap: _edit,
    );
  }
}

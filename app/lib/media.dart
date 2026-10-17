import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';

/// What stands in for a message in the chat list, quotes and notifications.
String messageText(AppLocalizations t, MessageView m) {
  final a = m.attachment;
  if (a == null) return m.text;
  return a.voiceNote ? '🎤 ${t.voiceMessage} (${formatDuration(a.durationMs)})' : '🎵 ${a.fileName}';
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

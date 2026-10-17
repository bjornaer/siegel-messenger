import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'l10n/app_localizations.dart';
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';

/// Decoded pictures by account ("" is ours), reused while the bytes stay the same so rebuilds
/// don't decode them again.
final _cache = <String, (Uint8List, MemoryImage)>{};

ImageProvider? _image(String key, Uint8List? bytes) {
  if (bytes == null) {
    _cache.remove(key);
    return null;
  }
  final hit = _cache[key];
  if (hit != null && listEquals(hit.$1, bytes)) return hit.$2;
  final img = MemoryImage(bytes);
  _cache[key] = (bytes, img);
  return img;
}

/// MED-15: a group's picture ([groupId]), someone's ([account]) or ours (neither); an icon
/// when there is none.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.core, this.account, this.groupId, this.radius = 20, this.icon});

  final Core core;
  final List<int>? account;
  final List<int>? groupId;
  final double radius;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (a, g) = (account, groupId);
    final img = g != null
        ? _image('g${g.join(',')}', core.groupAvatar(groupId: Uint8List.fromList(g)))
        : a == null
        ? _image('', core.myAvatar())
        : _image(a.join(','), core.avatar(account: Uint8List.fromList(a)));
    final icon = this.icon ?? (g != null ? Icons.group_outlined : Icons.person_outline);
    return CircleAvatar(
      radius: radius,
      backgroundImage: img,
      child: img == null ? Icon(icon, size: radius) : null,
    );
  }
}

/// The picture square, cropped from the middle, as PNG: re-encoding also drops any EXIF data
/// (location included, MED-11).
Future<Uint8List> squarePng(Uint8List bytes, {int size = 384}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final img = (await codec.getNextFrame()).image;
  final side = min(img.width, img.height).toDouble();
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(
    img,
    Rect.fromLTWH((img.width - side) / 2, (img.height - side) / 2, side, side),
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  final out = await rec.endRecording().toImage(size, size);
  return (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Our picture, or a group's ([groupId]), with a camera badge: tap to choose a photo, or to
/// remove the current one.
class AvatarEditor extends StatefulWidget {
  const AvatarEditor({super.key, required this.core, this.groupId, this.radius = 40, this.onChanged});

  final Core core;
  final VoidCallback? onChanged;
  final Uint8List? groupId;
  final double radius;

  @override
  State<AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<AvatarEditor> {
  bool _busy = false;

  Future<void> _set(Uint8List? png) async {
    setState(() => _busy = true);
    try {
      final g = widget.groupId;
      g == null ? await widget.core.setAvatar(image: png) : await widget.core.setGroupAvatar(groupId: g, image: png);
      widget.onChanged?.call();
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose() async {
    final t = AppLocalizations.of(context)!;
    final g = widget.groupId;
    final has = (g == null ? widget.core.myAvatar() : widget.core.groupAvatar(groupId: g)) != null;
    final remove = has
        ? await showModalBottomSheet<bool>(
            context: context,
            builder: (c) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: Text(t.choosePhoto),
                    onTap: () => Navigator.pop(c, false),
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text(t.removePhoto),
                    onTap: () => Navigator.pop(c, true),
                  ),
                ],
              ),
            ),
          )
        : false;
    if (remove == null) return;
    if (remove) return _set(null);
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    await _set(await squarePng(await file.readAsBytes()));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      label: t.profilePhoto,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _busy ? null : _choose,
        child: Stack(
          children: [
            Avatar(core: widget.core, groupId: widget.groupId, radius: widget.radius),
            if (_busy) Positioned.fill(child: CircularProgressIndicator(strokeWidth: 2)),
            Positioned(
              right: 0,
              bottom: 0,
              child: CircleAvatar(
                radius: widget.radius * 0.3,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: Icon(
                  Icons.photo_camera_outlined,
                  size: widget.radius * 0.35,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'format.dart' show firstLink;
import 'links.dart' show openUrl;
import 'media.dart' show thumbnailOf;
import 'src/rust/api/core.dart';

/// Settings key; on unless 'off'.
const previewsSetting = 'link_previews';

/// The card for the first link in [text], fetched by this phone: the site sees the sender, never
/// Siegel's server, and recipients get the card inside the encrypted message. Null when there's no
/// link or the page has no title. A browser can't read other sites (CORS), so the web app sends none.
Future<LinkPreviewView?> fetchPreview(String text) async {
  final shown = firstLink(text);
  if (kIsWeb || shown == null) return null;
  final url = Uri.tryParse(shown.startsWith('www.') ? 'https://$shown' : shown);
  if (url == null) return null;
  try {
    return await _fetch(url, shown).timeout(const Duration(seconds: 10));
  } catch (_) {
    return null; // no card is fine
  }
}

Future<LinkPreviewView?> _fetch(Uri url, String shown) async {
  final page = await _get(url, 512 << 10, 'text/html');
  if (page == null) return null;
  // Only the head matters; a cut-off page is fine.
  final r = readPage(utf8.decode(page, allowMalformed: true));
  if (r == null) return null;
  var image = Uint8List(0);
  if (r.image case final src?) {
    final img = await _get(url.resolve(src), 5 << 20, 'image/');
    if (img != null) image = await thumbnailOf(img);
  }
  return LinkPreviewView(url: shown, title: r.title, description: r.description, image: image);
}

/// Title, description and image address from a page's head; null without a title.
@visibleForTesting
({String title, String description, String? image})? readPage(String html) {
  final metas = _metas(html);
  final title = metas['og:title'] ?? RegExp(r'<title[^>]*>([^<]*)', caseSensitive: false).firstMatch(html)?[1];
  if (title == null || title.trim().isEmpty) return null;
  return (
    title: _cut(_unescape(title.trim()), 300),
    description: _cut(_unescape((metas['og:description'] ?? metas['description'] ?? '').trim()), 1000),
    image: metas['og:image'],
  );
}

/// The body, when the answer is a 200 of [type]. Pages over [max] are cut; images are dropped.
Future<Uint8List?> _get(Uri u, int max, String type) async {
  if (u.scheme != 'https' && u.scheme != 'http') return null;
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final res = await (await c.getUrl(u)).close();
    if (res.statusCode != 200 || !(res.headers.contentType?.mimeType.startsWith(type) ?? false)) return null;
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      b.add(chunk);
      if (b.length > max) return type == 'text/html' ? b.takeBytes() : null;
    }
    return b.takeBytes();
  } finally {
    c.close(force: true);
  }
}

final _meta = RegExp(r'<meta\s[^>]*>', caseSensitive: false);
final _attr = RegExp(r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');

/// `<meta property|name=… content=…>`, first one wins, keys lowercase.
Map<String, String> _metas(String html) {
  final out = <String, String>{};
  for (final tag in _meta.allMatches(html)) {
    final a = {for (final m in _attr.allMatches(tag[0]!)) m[1]!.toLowerCase(): m[2] ?? m[3]!};
    final key = (a['property'] ?? a['name'])?.toLowerCase();
    if (key != null && a['content'] != null) out.putIfAbsent(key, () => a['content']!);
  }
  return out;
}

String _unescape(String s) =>
    s.replaceAllMapped(RegExp(r'&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);', caseSensitive: false), (m) {
      final e = m[1]!.toLowerCase();
      if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
      if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
      return const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '}[e]!;
    });

/// At most [bytes] of UTF-8, whole characters.
String _cut(String s, int bytes) {
  final out = StringBuffer();
  var n = 0;
  for (final r in s.runes) {
    n += utf8.encode(String.fromCharCode(r)).length;
    if (n > bytes) break;
    out.writeCharCode(r);
  }
  return out.toString();
}

/// The card in a bubble; tapping it opens the link.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard(this.p, {super.key});
  final LinkPreviewView p;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = p.url.startsWith('www.') ? 'https://${p.url}' : p.url;
    return Semantics(
      link: true,
      child: InkWell(
        onTap: () => openUrl(url),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.image.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(p.image, height: 120, fit: BoxFit.cover, excludeFromSemantics: true),
                  ),
                ),
              Text(
                p.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (p.description.isNotEmpty)
                Text(p.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              Text(Uri.tryParse(url)?.host ?? '', style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

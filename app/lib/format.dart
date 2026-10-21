import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// MSG-05 inline formatting, WhatsApp style: *bold*, _italic_, ~strike~, `monospace`. Markers
/// only count at word boundaries, so snake_case, 2*3*4 and e-mail addresses stay plain. Styles
/// nest, except inside monospace. The text is sent as typed; only the display changes.
/// Web addresses are links, taken before any marker so an address's _ or * stays in it.
TextSpan formatText(String s, {void Function(String url)? onLink}) {
  final out = <InlineSpan>[];
  final plain = StringBuffer();
  void flush() {
    if (plain.isNotEmpty) out.add(TextSpan(text: plain.toString()));
    plain.clear();
  }

  var i = 0;
  while (i < s.length) {
    final link = _word(s, i - 1) ? null : _link.matchAsPrefix(s, i);
    if (link != null) {
      flush();
      final shown = _trimEnd(link[0]!);
      final url = shown.startsWith('www.') ? 'https://$shown' : shown;
      out.add(
        TextSpan(
          text: shown,
          style: const TextStyle(decoration: TextDecoration.underline),
          // ponytail: recognizers aren't disposed; one small object per link per build.
          recognizer: onLink == null ? null : (TapGestureRecognizer()..onTap = () => onLink(url)),
        ),
      );
      i += shown.length;
      continue;
    }
    final style = _styles[s[i]];
    final end = style == null ? -1 : _closing(s, i);
    if (end > 0) {
      flush();
      final inner = s.substring(i + 1, end);
      out.add(
        s[i] == '`'
            ? TextSpan(text: inner, style: style)
            : TextSpan(
                children: [formatText(inner, onLink: onLink)],
                style: style,
              ),
      );
      i = end + 1;
    } else {
      plain.write(s[i]);
      i++;
    }
  }
  flush();
  return TextSpan(children: out);
}

const _styles = {
  '*': TextStyle(fontWeight: FontWeight.bold),
  '_': TextStyle(fontStyle: FontStyle.italic),
  '~': TextStyle(decoration: TextDecoration.lineThrough),
  '`': TextStyle(fontFamily: 'monospace'),
};

final _link = RegExp(r'(https?://|www\.)[^\s<>"]+', caseSensitive: false);

/// Sentence punctuation after an address isn't part of it; a ) is, if the address opened one.
String _trimEnd(String u) {
  while (u.isNotEmpty) {
    final c = u[u.length - 1];
    if (c == ')' && '('.allMatches(u).length >= ')'.allMatches(u).length) break;
    if (!'.,;:!?\'")]}'.contains(c)) break;
    u = u.substring(0, u.length - 1);
  }
  return u;
}

final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _word(String s, int i) => i >= 0 && i < s.length && _wordChar.hasMatch(s[i]);

bool _space(String c) => c.trim().isEmpty;

/// Index of the marker closing the one at [open], or -1. The content must be non-empty, start
/// and end with a non-space character and stay on one line.
int _closing(String s, int open) {
  final m = s[open];
  if (_word(s, open - 1) || open + 1 >= s.length || _space(s[open + 1]) || s[open + 1] == m) return -1;
  for (var k = open + 2; k < s.length; k++) {
    if (s[k] == '\n') return -1;
    if (s[k] == m && !_space(s[k - 1]) && !_word(s, k + 1)) return k;
  }
  return -1;
}

/// A 64-bit number from the core: an int on phones, a BigInt in the browser (M8).
int asInt(Object v) => v is BigInt ? v.toInt() : v as int;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:siegel/format.dart';

/// Flattens a span into (text, bold, italic, strike, mono) runs.
List<(String, String)> runs(InlineSpan span, [TextStyle base = const TextStyle()]) {
  final s = base.merge((span as TextSpan).style);
  final tags = [
    if (s.fontWeight == FontWeight.bold) 'b',
    if (s.fontStyle == FontStyle.italic) 'i',
    if (s.decoration == TextDecoration.lineThrough) 's',
    if (s.fontFamily == 'monospace') 'm',
  ].join();
  return [if (span.text != null) (span.text!, tags), for (final c in span.children ?? <InlineSpan>[]) ...runs(c, s)];
}

void main() {
  test('MSG-05: WhatsApp-style markers', () {
    expect(runs(formatText('hi *there* _you_ ~old~ `x*y*`')), [
      ('hi ', ''),
      ('there', 'b'),
      (' ', ''),
      ('you', 'i'),
      (' ', ''),
      ('old', 's'),
      (' ', ''),
      ('x*y*', 'm'), // nothing inside monospace
    ]);
    expect(runs(formatText('*bold _and italic_*')), [('bold ', 'b'), ('and italic', 'bi')]);
  });

  test('MSG-05: markers inside words and odd cases stay plain', () {
    for (final s in ['snake_case_name', '2*3*4', 'a@b_c.de', '* not bold *', '**', 'no *end', '*multi\nline*']) {
      expect(runs(formatText(s)), [(s, '')], reason: s);
    }
    expect(runs(formatText('¡*hola*!')), [('¡', ''), ('hola', 'b'), ('!', '')], reason: 'punctuation is a boundary');
  });
}

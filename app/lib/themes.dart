import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

/// A colour theme. Names stay German everywhere (they fit "Siegel"); the meaning is translated.
/// Schemes come from one seed colour (Material 3), so light, dark and contrast all follow.
class SiegelTheme {
  const SiegelTheme(
    this.id,
    this.name,
    this.seed,
    this.meaning, {
    this.variant = DynamicSchemeVariant.tonalSpot,
    this.gradient,
    this.lightOnly = false,
  });
  final String id; // stored in settings; never rename
  final String name;
  final Color seed;
  final String Function(AppLocalizations) meaning;
  final DynamicSchemeVariant variant;

  /// Gradient themes paint top bars, our own bubbles and their swatch with this.
  final SiegelGradient? gradient;

  /// Stays light when the phone is in dark mode (Edelweiß is white by nature).
  final bool lightOnly;

  ThemeData data(Brightness b) {
    final brightness = lightOnly ? Brightness.light : b;
    final g = gradient;
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness, dynamicSchemeVariant: variant),
      appBarTheme: g == null ? null : AppBarTheme(foregroundColor: g.on, backgroundColor: g.colors.first),
      extensions: [?g],
    );
  }
}

/// The colours of a gradient theme, what reads on top of them, and the read ticks on our
/// bubbles (a colour that is neither the gradient nor [on]).
class SiegelGradient extends ThemeExtension<SiegelGradient> {
  const SiegelGradient(this.colors, this.on, this.read);
  final List<Color> colors;
  final Color on;
  final Color read;

  LinearGradient get linear => LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight);

  @override
  SiegelGradient copyWith({List<Color>? colors, Color? on, Color? read}) =>
      SiegelGradient(colors ?? this.colors, on ?? this.on, read ?? this.read);

  @override
  SiegelGradient lerp(SiegelGradient? other, double t) => t < 0.5 || other == null ? this : other;
}

/// WCAG contrast ratio, 1 to 21.
double contrast(Color a, Color b) {
  final (x, y) = (a.computeLuminance(), b.computeLuminance());
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// MSG-04: read ticks stand out from our bubble: 3:1 contrast (WCAG 1.4.11), a clearly different
/// hue, and saturated, so they never look like the grey sent and delivered ticks.
Color readTickColor(ThemeData theme) {
  final g = theme.extension<SiegelGradient>();
  if (g != null) return g.read;
  final s = theme.colorScheme;
  final bg = HSLColor.fromColor(s.primaryContainer);
  final dark = theme.brightness == Brightness.dark;
  final vivid = dark
      ? const [Color(0xFF64B5F6), Color(0xFFF48FB1), Color(0xFF81C784)] // sky, rose, leaf
      : const [Color(0xFF1565C0), Color(0xFFAD1457), Color(0xFF2E7D32)]; // gentian, raspberry, fir
  bool apart(Color c) {
    final h = HSLColor.fromColor(c);
    final d = (h.hue - bg.hue).abs() % 360;
    return contrast(c, s.primaryContainer) >= 3 && h.saturation >= 0.35 && math.min(d, 360 - d) >= 60;
  }

  return vivid.firstWhere(apart, orElse: () => vivid.first);
}

/// [child] restyled to read on the gradient [g] (our bubbles); unchanged without one.
Widget onGradient(BuildContext context, SiegelGradient? g, Widget child) {
  if (g == null) return child;
  final theme = Theme.of(context);
  final on = g.on;
  return Theme(
    data: theme.copyWith(
      colorScheme: theme.colorScheme.copyWith(
        onSurface: on,
        onSurfaceVariant: on.withValues(alpha: 0.8),
        primary: on,
        outline: on.withValues(alpha: 0.45),
        error: on,
      ),
      textTheme: theme.textTheme.apply(bodyColor: on, displayColor: on),
      iconTheme: IconThemeData(color: on),
    ),
    child: DefaultTextStyle.merge(
      style: TextStyle(color: on),
      child: IconTheme.merge(
        data: IconThemeData(color: on),
        child: child,
      ),
    ),
  );
}

/// An AppBar that shows the theme's gradient, if it has one.
class SiegelBar extends AppBar {
  SiegelBar({super.key, super.title, super.actions, super.leading, super.bottom, super.titleSpacing})
    : super(flexibleSpace: const _GradientFill());
}

class _GradientFill extends StatelessWidget {
  const _GradientFill();

  @override
  Widget build(BuildContext context) {
    final g = Theme.of(context).extension<SiegelGradient>();
    return g == null
        ? const SizedBox.shrink()
        : DecoratedBox(
            decoration: BoxDecoration(gradient: g.linear),
            child: const SizedBox.expand(),
          );
  }
}

final siegelThemes = [
  SiegelTheme('siegel', 'Siegel', const Color(0xFF2F543B), (t) => t.themeSiegel), // the logo green
  SiegelTheme(
    'drache',
    'Drache',
    const Color(0xFF9B1B30),
    (t) => t.themeDrache,
    variant: DynamicSchemeVariant.vibrant,
    gradient: const SiegelGradient(
      [Color(0xFFB3182F), Color(0xFF5C0A24)],
      Colors.white,
      Color(0xFFFFD54F),
    ), // fire to dried blood; gold
  ),
  SiegelTheme('loewe', 'Löwe', const Color(0xFFC8962E), (t) => t.themeLoewe),
  SiegelTheme(
    'lindwurm',
    'Lindwurm',
    const Color(0xFF0F7C73),
    (t) => t.themeLindwurm,
    gradient: const SiegelGradient(
      [Color(0xFF12A190), Color(0xFF0B4A43)],
      Colors.white,
      Color(0xFFFFD54F),
    ), // scales into deep water; gold
  ),
  SiegelTheme('schnee', 'Schnee', const Color(0xFF8FB8DE), (t) => t.themeSchnee),
  SiegelTheme(
    'krampus',
    'Krampus',
    const Color(0xFFC2410C),
    (t) => t.themeKrampus,
    variant: DynamicSchemeVariant.fidelity,
    gradient: const SiegelGradient(
      [Color(0xFFE8631E), Color(0xFF3A1A12)],
      Colors.white,
      Color(0xFF80DEEA),
    ), // ember to soot; ice
  ),
  SiegelTheme(
    'nordlicht',
    'Nordlicht',
    const Color(0xFF6A4FC3),
    (t) => t.themeNordlicht,
    variant: DynamicSchemeVariant.rainbow,
  ),
  SiegelTheme('fernweh', 'Fernweh', const Color(0xFF1F6FB2), (t) => t.themeFernweh),
  SiegelTheme(
    'edelweiss',
    'Edelweiß',
    const Color(0xFFE3C55A), // the flower's yellow heart
    (t) => t.themeEdelweiss,
    lightOnly: true,
    gradient: const SiegelGradient(
      [Color(0xFFFFFFFF), Color(0xFFC3C9D2)],
      Color(0xFF22272E),
      Color(0xFF1565C0),
    ), // snow to silver; gentian blue
  ),
  SiegelTheme(
    'kraehe',
    'Krähe',
    const Color(0xFF1B2D5E),
    (t) => t.themeKraehe,
    gradient: const SiegelGradient(
      [Color(0xFF1B2D5E), Color(0xFF050608)],
      Colors.white,
      Color(0xFFFFCA28),
    ), // midnight blue to black; amber
  ),
];

SiegelTheme themeById(String? id) => siegelThemes.firstWhere((t) => t.id == id, orElse: () => siegelThemes.first);

/// The chosen theme; the app rebuilds when it changes.
final themeChoice = ValueNotifier<SiegelTheme>(siegelThemes.first);

/// Settings screen: pick a theme, applied at once.
class ThemePicker extends StatelessWidget {
  const ThemePicker({super.key, required this.onPick});
  final ValueChanged<SiegelTheme> onPick;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: SiegelBar(title: Text(t.theme)),
      body: ValueListenableBuilder(
        valueListenable: themeChoice,
        builder: (context, current, _) => ListView(
          children: [
            for (final th in siegelThemes)
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: th.gradient?.linear,
                    border: th.gradient == null
                        ? null
                        : Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    color: th.gradient != null
                        ? null
                        : ColorScheme.fromSeed(
                            seedColor: th.seed,
                            brightness: Theme.of(context).brightness,
                            dynamicSchemeVariant: th.variant,
                          ).primary,
                  ),
                ),
                title: Text(th.name),
                subtitle: Text(th.meaning(t)),
                trailing: th.id == current.id ? Icon(Icons.check, semanticLabel: t.selected) : null,
                selected: th.id == current.id,
                onTap: () => onPick(th),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

/// A colour theme. Names stay German everywhere (they fit "Siegel"); the meaning is translated.
/// Schemes come from one seed colour (Material 3), so light, dark and contrast all follow.
class SiegelTheme {
  const SiegelTheme(this.id, this.name, this.seed, this.meaning, {this.variant = DynamicSchemeVariant.tonalSpot});
  final String id; // stored in settings; never rename
  final String name;
  final Color seed;
  final String Function(AppLocalizations) meaning;
  final DynamicSchemeVariant variant;

  ThemeData data(Brightness b) => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b, dynamicSchemeVariant: variant),
  );
}

final siegelThemes = [
  SiegelTheme('siegel', 'Siegel', const Color(0xFF2F543B), (t) => t.themeSiegel), // the logo green
  SiegelTheme('drache', 'Drache', const Color(0xFF9B1B30), (t) => t.themeDrache, variant: DynamicSchemeVariant.vibrant),
  SiegelTheme('loewe', 'Löwe', const Color(0xFFC8962E), (t) => t.themeLoewe),
  SiegelTheme('lindwurm', 'Lindwurm', const Color(0xFF0F7C73), (t) => t.themeLindwurm),
  SiegelTheme('schnee', 'Schnee', const Color(0xFF8FB8DE), (t) => t.themeSchnee),
  SiegelTheme(
    'krampus',
    'Krampus',
    const Color(0xFFC2410C),
    (t) => t.themeKrampus,
    variant: DynamicSchemeVariant.fidelity,
  ),
  SiegelTheme(
    'nordlicht',
    'Nordlicht',
    const Color(0xFF6A4FC3),
    (t) => t.themeNordlicht,
    variant: DynamicSchemeVariant.rainbow,
  ),
  SiegelTheme('fernweh', 'Fernweh', const Color(0xFF1F6FB2), (t) => t.themeFernweh),
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
      appBar: AppBar(title: Text(t.theme)),
      body: ValueListenableBuilder(
        valueListenable: themeChoice,
        builder: (context, current, _) => ListView(
          children: [
            for (final th in siegelThemes)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: ColorScheme.fromSeed(
                    seedColor: th.seed,
                    brightness: Theme.of(context).brightness,
                    dynamicSchemeVariant: th.variant,
                  ).primary,
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

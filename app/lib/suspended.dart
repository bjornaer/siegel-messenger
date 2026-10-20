import 'format.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n/app_localizations.dart';
import 'links.dart' show openPage;
import 'report.dart' show ReportReason, reasonLabel;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// The rule a notice names, in the guidelines' words.
String ruleLabel(AppLocalizations t, int rule) =>
    rule >= 1 && rule <= ReportReason.values.length ? reasonLabel(t, ReportReason.values[rule - 1]) : t.reportOther;

/// M7: a suspended account's whole app. Says what, why and until when (DSA Art. 17), how to
/// appeal, and still lets the person delete the account.
class SuspendedScreen extends StatelessWidget {
  const SuspendedScreen({super.key, required this.notice, required this.onDelete});
  final NoticeView notice;
  final Future<void> Function(BuildContext) onDelete;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final until = DateTime.fromMillisecondsSinceEpoch(asInt(notice.untilMs));
    return Scaffold(
      appBar: SiegelBar(title: Text(t.suspendedTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text(t.suspendedUntil(DateFormat.yMMMd(t.localeName).add_Hm().format(until))),
          const SizedBox(height: 16),
          Text(t.noticeRule(ruleLabel(t, notice.rule)), style: Theme.of(context).textTheme.titleMedium),
          if (notice.reason.isNotEmpty) ...[const SizedBox(height: 8), Text(notice.reason)],
          const SizedBox(height: 16),
          Text(t.appealHow),
          TextButton(onPressed: () => openPage('/terms'), child: Text(t.termsAndGuidelines)),
          const SizedBox(height: 24),
          OutlinedButton(onPressed: () => onDelete(context), child: Text(t.deleteAccount)),
        ],
      ),
    );
  }
}

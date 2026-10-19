import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'chats.dart' show chatTitle;
import 'groups.dart' show memberName;
import 'l10n/app_localizations.dart';
import 'media.dart' show messageText;
import 'onboarding.dart' show showError;
import 'src/rust/api/core.dart';
import 'themes.dart';

/// The report categories, numbered as ReportCategory in proto/siegel/v1/reports.proto.
enum ReportReason { spam, harassment, hate, childSafety, nonConsensual, violence, impersonation, other }

String reasonLabel(AppLocalizations t, ReportReason r) => switch (r) {
  ReportReason.spam => t.reportSpam,
  ReportReason.harassment => t.reportHarassment,
  ReportReason.hate => t.reportHate,
  ReportReason.childSafety => t.reportChildSafety,
  ReportReason.nonConsensual => t.reportNonConsensual,
  ReportReason.violence => t.reportViolence,
  ReportReason.impersonation => t.reportImpersonation,
  ReportReason.other => t.reportOther,
};

const _maxMessages = 50;

/// CMP-03 (M7 part 3): choose why, which messages go along (readable, to the moderators), and
/// whether to block. [around] pre-selects that message and up to 10 before it from the same
/// sender; without it, the last 10 from others.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.core, required this.chat, this.around, this.block = false});
  final Core core;
  final ChatSummary chat;
  final MessageView? around;
  final bool block;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late final List<MessageView> _messages = widget.core
      .messages(groupId: widget.chat.groupId, limit: 200)
      .where((m) => m.event == null && !m.keyChange && !m.deleted)
      .toList();
  late final Set<String> _chosen = _preselect();
  late bool _block = widget.block;
  final _note = TextEditingController();
  ReportReason? _reason;
  bool _busy = false;

  String _id(MessageView m) => m.messageId.join(',');

  Set<String> _preselect() {
    final around = widget.around;
    final from = around?.senderAccount;
    final pool = around == null
        ? _messages.where((m) => !m.outgoing)
        : _messages.takeWhile((m) => !listEquals(m.messageId, around.messageId)).followedBy([around]);
    return pool
        .where((m) => !m.outgoing && (from == null || listEquals(m.senderAccount, from)))
        .toList()
        .reversed
        .take(around == null ? 10 : 11)
        .map(_id)
        .toSet();
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      await widget.core.report(
        groupId: widget.chat.groupId,
        category: _reason!.index + 1,
        note: _note.text,
        messageIds: [
          for (final m in _messages)
            if (_chosen.contains(_id(m))) m.messageId,
        ],
        block: _block && !widget.chat.isGroup,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.reportSent)));
      Navigator.of(context).pop(true);
    } on CoreError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final c = widget.chat;
    String sender(MessageView m) => m.outgoing
        ? t.you
        : c.isGroup
        ? memberName(t, widget.core, m.senderAccount)
        : chatTitle(t, c);
    return Scaffold(
      appBar: SiegelBar(title: Text(c.isGroup && widget.around == null ? t.reportGroup : t.report)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text(t.reportWhy, style: Theme.of(context).textTheme.titleMedium),
          RadioGroup<ReportReason>(
            groupValue: _reason,
            onChanged: (r) => setState(() => _reason = r),
            child: Column(
              children: [
                for (final r in ReportReason.values)
                  RadioListTile<ReportReason>(
                    contentPadding: EdgeInsets.zero,
                    value: r,
                    title: Text(reasonLabel(t, r)),
                  ),
              ],
            ),
          ),
          if (_reason == ReportReason.childSafety) Text(t.reportChildSafetyHelp),
          const SizedBox(height: 16),
          Text(t.reportMessages(_chosen.length, _maxMessages), style: Theme.of(context).textTheme.titleMedium),
          Text(t.reportReadable),
          for (final m in _messages.reversed.take(_maxMessages * 2))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _chosen.contains(_id(m)),
              onChanged: (on) => setState(() {
                if (on == true && _chosen.length < _maxMessages) {
                  _chosen.add(_id(m));
                } else {
                  _chosen.remove(_id(m));
                }
              }),
              title: Text(messageText(t, m), maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: Text(sender(m)),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            maxLength: 1000,
            maxLines: 3,
            decoration: InputDecoration(labelText: t.reportNote),
          ),
          if (!c.isGroup)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _block,
              onChanged: (v) => setState(() => _block = v ?? false),
              title: Text(t.reportAlsoBlock(chatTitle(t, c))),
            ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _reason == null || _busy ? null : _send, child: Text(t.reportSend)),
        ],
      ),
    );
  }
}

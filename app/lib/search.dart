import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'chats.dart';
import 'format.dart' show asInt;
import 'themes.dart' show SiegelBar;
import 'l10n/app_localizations.dart';
import 'media.dart';
import 'src/rust/api/core.dart';

/// CLI-05: every chat's messages, searched on this device only (the server can't read them).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.core, required this.service});
  final Core core;
  final ChatService service;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<MessageView>? _found; // null: nothing searched yet
  int _asked = 0; // only the newest search's answer is shown

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final n = ++_asked;
      final found = q.trim().isEmpty ? null : await widget.core.search(query: q, limit: 100);
      if (mounted && n == _asked) setState(() => _found = found);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final chats = {for (final c in widget.core.chats()) base64Encode(c.groupId): c};
    final found = _found;
    return Scaffold(
      appBar: SiegelBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: t.searchMessages, border: InputBorder.none),
          onChanged: _changed,
        ),
      ),
      body: found == null
          ? const SizedBox.shrink()
          : found.isEmpty
          ? Center(child: Text(t.noMessagesFound))
          : ListView.builder(
              itemCount: found.length,
              itemBuilder: (context, i) {
                final m = found[i];
                final c = chats[base64Encode(m.groupId)];
                if (c == null) return const SizedBox.shrink(); // its chat was deleted meanwhile
                final sent = DateTime.fromMillisecondsSinceEpoch(asInt(m.sentAt));
                return ListTile(
                  title: Text(chatTitle(t, c), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text.rich(_highlight(messageText(t, m), _query.text.trim()), maxLines: 2),
                  trailing: Text(DateFormat.yMd(Localizations.localeOf(context).toString()).format(sent)),
                  onTap: () => openChat(context, widget.core, widget.service, m.groupId, jumpTo: m.messageId),
                );
              },
            ),
    );
  }
}

/// The match in bold, where it matches as typed (accents can differ: then it's just the text).
TextSpan _highlight(String text, String q) {
  final at = q.isEmpty ? -1 : text.toLowerCase().indexOf(q.toLowerCase());
  if (at < 0) return TextSpan(text: text);
  return TextSpan(
    children: [
      TextSpan(text: text.substring(0, at)),
      TextSpan(
        text: text.substring(at, at + q.length),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      TextSpan(text: text.substring(at + q.length)),
    ],
  );
}

//! CMP-03 (M7 part 3): reporting a person, a message or a group. The report holds the messages
//! the reporter chose, readable, and is sealed here to the moderators' key before it leaves.

use core_net::pb;
use prost::Message as _;

use core_store::Store as _;

use crate::{CoreError, SiegelCore, chat::chat_message, storage};

/// At most this many messages in one report, and this much media in all; bigger media goes as
/// its thumbnail.
const MAX_MESSAGES: usize = 50;
const MAX_MEDIA: usize = 24 << 20;
const MAX_ONE_MEDIA: usize = 10 << 20;
const MAX_NOTE: usize = 1000;

impl SiegelCore {
    /// Reports `message_ids` from this chat (any may be empty) under `category`
    /// (`pb::ReportCategory`). In a 1:1 chat it reports the other person; in a group, the one
    /// sender of the chosen messages, or the group itself. `block` blocks the person too (MSG-16).
    pub async fn report(
        &self,
        group_id: &[u8],
        category: i32,
        note: &str,
        message_ids: &[Vec<u8>],
        block: bool,
    ) -> Result<(), CoreError> {
        if message_ids.len() > MAX_MESSAGES
            || note.chars().count() > MAX_NOTE
            || pb::ReportCategory::try_from(category).is_err()
            || category == 0
        {
            return Err(CoreError::new("report_invalid"));
        }
        let token = self.token()?;
        let key = self.net.report_key(&token).await?;
        if key.is_empty() {
            return Err(CoreError::new("reports_unavailable"));
        }
        let conv = self.conversation(group_id)?;
        let me = self.me()?;
        let name_of = |account: &[u8]| {
            self.contact(account)
                .and_then(|c| c.username.map(|u| format!("@{u}")).or(c.display_name))
                .unwrap_or_default()
        };
        let mut messages = Vec::new();
        let mut media_left = MAX_MEDIA;
        for id in message_ids {
            let Some(m) = self.with_store(|s| storage(s.message(id)))? else {
                continue;
            };
            if m.group_id != group_id {
                continue;
            }
            let sender = m.sender_account.clone();
            let Some(cm) = chat_message(m, vec![]) else {
                continue;
            };
            let mut r = pb::ReportedMessage {
                message_id: cm.message_id.clone(),
                sender_name: if sender == me {
                    String::new()
                } else {
                    name_of(&sender)
                },
                sender_account: sender,
                sent_at: cm.sent_at,
                text: cm.text,
                ..Default::default()
            };
            if let Some(a) = cm.attachment {
                r.mime_type = a.mime_type;
                r.file_name = a.file_name;
                let size = a.size as usize;
                r.media = if size <= MAX_ONE_MEDIA && size <= media_left {
                    match self.attachment_data(&cm.message_id).await {
                        Ok(d) => {
                            media_left -= d.len().min(media_left);
                            d
                        }
                        Err(_) => a.thumbnail, // expired from the server: the preview is what's left
                    }
                } else {
                    a.thumbnail
                };
            }
            messages.push(r);
        }
        // Who is reported: the other person in a 1:1 chat; in a group, the one other sender of
        // the chosen messages, or nobody (the group itself).
        let others: std::collections::BTreeSet<&Vec<u8>> = messages
            .iter()
            .map(|m| &m.sender_account)
            .filter(|a| **a != me)
            .collect();
        let reported = if !conv.is_group {
            conv.peer_account.clone()
        } else if others.len() == 1 {
            (*others.first().unwrap()).clone()
        } else {
            vec![]
        };
        let report = pb::Report {
            category,
            note: note.trim().into(),
            reporter_account: me,
            reported_name: if reported.is_empty() {
                String::new()
            } else {
                name_of(&reported)
            },
            reported_account: reported.clone(),
            group_id: if conv.is_group {
                group_id.to_vec()
            } else {
                vec![]
            },
            group_name: if conv.is_group {
                self.group_info(group_id)
                    .map(|g| g.name)
                    .unwrap_or_default()
            } else {
                String::new()
            },
            messages,
            reported_at: crate::chat::now_ms(),
        };
        let sealed = core_crypto::reports::seal(&key, &report.encode_to_vec())
            .ok_or(CoreError::new("reports_unavailable"))?;
        self.net
            .submit_report(&token, category, &reported, sealed)
            .await?;
        if block && !conv.is_group {
            self.block(&conv.peer_account).await?;
        }
        Ok(())
    }
}

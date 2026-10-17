//! Headless client against a real server (section 15 test levels).
//! Needs the local stack: docker compose up -d, then
//!   SIEGEL_TEST_SERVER_URL=http://localhost:58080 cargo test -p core-api
//! The dev server stubs SMS, so the OTP is read from its database with `docker compose exec`.

use core_api::{Platform, SiegelCore};

/// A random 8-digit suffix: timestamps repeat across runs and would re-register old accounts.
fn fresh_number() -> u128 {
    uuid::Uuid::now_v7().as_u128() % 100_000_000
}

/// Tests run in parallel; "newest OTP in the DB" is only safe for one registration at a time.
static REGISTER: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn register(core: &SiegelCore, phone: &str) {
    let _one_at_a_time = REGISTER.lock().await;
    core.request_otp(phone, "", Platform::Android)
        .await
        .unwrap();
    core.verify(phone, &otp_from_db(), "", Platform::Android)
        .await
        .unwrap();
}

fn otp_from_db() -> String {
    let out = std::process::Command::new("docker")
        .args([
            "compose",
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "postgres",
            "-d",
            "siegel",
            "-tAc",
            "SELECT code FROM otps ORDER BY expires_at DESC LIMIT 1",
        ])
        .output()
        .expect("docker");
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[tokio::test]
async fn register_username_lock_delete() {
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        eprintln!("SIEGEL_TEST_SERVER_URL not set, skipping");
        return;
    };
    let dir = std::env::temp_dir().join(format!("siegel-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("core.db");
    let core = SiegelCore::open(db.to_str().unwrap(), &[9; 32], &url).unwrap();
    assert!(!core.is_registered());

    let n = fresh_number();
    let phone = format!("+346{n:08}");
    assert_eq!(
        core.request_otp("0034", "", Platform::Android)
            .await
            .unwrap_err()
            .code,
        "phone_invalid"
    );
    let one_at_a_time = REGISTER.lock().await;
    core.request_otp(&phone, "", Platform::Android)
        .await
        .unwrap();
    assert_eq!(
        core.verify(&phone, "000000x", "", Platform::Ios)
            .await
            .unwrap_err()
            .code,
        "otp_invalid"
    );
    assert!(
        !core
            .verify(&phone, &otp_from_db(), "", Platform::Ios)
            .await
            .unwrap()
    );
    drop(one_at_a_time);
    assert!(core.is_registered());

    let name = format!("e2e{n}");
    core.set_username(&name).await.unwrap();
    assert_eq!(core.username().as_deref(), Some(name.as_str()));
    assert_eq!(
        core.set_display_name(" ").unwrap_err().code,
        "display_name_invalid"
    );
    core.set_display_name("Ana ✨").unwrap();
    assert_eq!(core.setting("app_lock"), None);
    core.set_setting("app_lock", "60").unwrap();
    assert_eq!(core.lookup_username(&name).await.unwrap().len(), 16);
    assert_eq!(
        core.set_registration_lock("12a4").await.unwrap_err().code,
        "pin_invalid"
    );
    core.set_registration_lock("1234").await.unwrap();

    // State survives reopening the encrypted DB.
    drop(core);
    let core = SiegelCore::open(db.to_str().unwrap(), &[9; 32], &url).unwrap();
    assert!(core.is_registered());
    assert_eq!(core.display_name().as_deref(), Some("Ana ✨"));
    assert_eq!(core.setting("app_lock").as_deref(), Some("60"));

    core.delete_account().await.unwrap();
    assert!(!db.exists(), "local DB wiped");
    assert_eq!(
        core.set_username("whatever").await.unwrap_err().code,
        "not_registered"
    );
    assert!(!core.is_registered());
}

/// Registers a fresh account with a username; returns the core and its DB directory.
async fn new_user(url: &str, tag: &str) -> (std::sync::Arc<SiegelCore>, String) {
    let n = fresh_number();
    let dir = std::env::temp_dir().join(format!("siegel-e2e-{tag}-{n}"));
    std::fs::create_dir_all(&dir).unwrap();
    let core = SiegelCore::open(dir.join("core.db").to_str().unwrap(), &[7; 32], url).unwrap();
    let phone = format!("+346{n:08}");
    register(&core, &phone).await;
    let name = format!("{tag}{n}");
    core.set_display_name(&format!("{tag} display")).unwrap();
    core.set_username(&name).await.unwrap();
    (std::sync::Arc::new(core), name)
}

/// Runs the device's stream in the background and returns its events.
fn listen(
    core: &std::sync::Arc<SiegelCore>,
) -> tokio::sync::mpsc::UnboundedReceiver<core_api::Event> {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let c = core.clone();
    tokio::spawn(async move { c.run_stream(move |e| tx.send(e).unwrap()).await });
    rx
}

async fn next_event(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<core_api::Event>,
) -> core_api::Event {
    tokio::time::timeout(std::time::Duration::from_secs(10), rx.recv())
        .await
        .expect("event in time")
        .unwrap()
}

#[tokio::test]
async fn two_users_chat_over_mls() {
    // AC-01: two new users find each other by @username and exchange text; the server never sees it.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let mut bob_events = listen(&bob);
    let mut alice_events = listen(&alice);

    let chat = alice.start_chat(&bob_name).await.unwrap();
    assert_eq!(
        alice.start_chat(&bob_name).await.unwrap(),
        chat,
        "one 1:1 chat per peer"
    );
    let peer = alice.conversations().unwrap()[0].peer_account.clone();
    assert_eq!(
        alice.contact(&peer).unwrap().username.as_deref(),
        Some(bob_name.as_str())
    );
    let core_api::Event::ConversationStarted { group_id, .. } = next_event(&mut bob_events).await
    else {
        panic!("welcome")
    };
    assert_eq!(group_id, chat);

    let canary = format!("canary-{}", std::process::id());
    alice
        .send_text(&chat, &format!("hello bob {canary}"), None)
        .await
        .unwrap();
    let core_api::Event::Message(m) = until(&mut bob_events, |e| {
        matches!(e, core_api::Event::Message(_))
    })
    .await
    else {
        panic!("message")
    };
    assert_eq!(
        (m.text.as_str(), m.outgoing),
        (format!("hello bob {canary}").as_str(), false)
    );

    bob.accept(&chat).await.unwrap();
    bob.send_text(&chat, "hi alice", None).await.unwrap();
    let core_api::Event::Message(m) = until(&mut alice_events, |e| {
        matches!(e, core_api::Event::Message(_))
    })
    .await
    else {
        panic!("reply")
    };
    assert_eq!(m.text, "hi alice");

    let history: Vec<_> = alice
        .messages(&chat, 10)
        .unwrap()
        .into_iter()
        .map(|m| (m.text, m.outgoing))
        .collect();
    assert_eq!(
        history,
        vec![
            (format!("hello bob {canary}"), true),
            ("hi alice".into(), false)
        ]
    );

    // Nothing the server stored contains the plaintext.
    let dump = std::process::Command::new("docker")
        .args([
            "compose",
            "exec",
            "-T",
            "postgres",
            "pg_dump",
            "-U",
            "postgres",
            "--data-only",
            "siegel",
        ])
        .output()
        .expect("docker");
    assert!(!dump.stdout.is_empty());
    // AC-01: neither the database nor the server's logs hold message text or profile names.
    let logs = std::process::Command::new("docker")
        .args(["compose", "logs", "server"])
        .output()
        .expect("docker");
    assert!(!logs.stdout.is_empty(), "no server logs to check");
    for (what, out) in [("database", &dump.stdout), ("logs", &logs.stdout)] {
        let text = String::from_utf8_lossy(out);
        for secret in [canary.as_str(), "alice display", "bob display"] {
            assert!(!text.contains(secret), "{secret} reached the server {what}");
        }
    }
}

/// Manual peer for device tests: registers, writes its @username to $ECHO_FILE and answers
/// every message with "pong: <text>" for five minutes.
///   SIEGEL_TEST_SERVER_URL=... ECHO_FILE=/tmp/echo cargo test -p core-api --test e2e echo_peer -- --ignored
#[tokio::test]
#[ignore]
async fn echo_peer() {
    let url = std::env::var("SIEGEL_TEST_SERVER_URL").unwrap();
    let (peer, name) = new_user(&url, "echo").await;
    std::fs::write(std::env::var("ECHO_FILE").unwrap(), &name).unwrap();
    let mut events = listen(&peer);
    // ECHO_TARGET=<username>: start the chat ourselves, so the app gets a message request.
    if let Ok(target) = std::env::var("ECHO_TARGET") {
        let chat = peer.start_chat(&target).await.unwrap();
        peer.send_text(&chat, "hello from echo", None)
            .await
            .unwrap();
    }
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(300);
    while let Ok(Some(e)) = tokio::time::timeout_at(deadline, events.recv()).await {
        if let core_api::Event::Message(m) = e {
            peer.send_text(&m.group_id, &format!("pong: {}", m.text), None)
                .await
                .unwrap();
        }
    }
}

/// Polls `done` for up to 40 s: for conditions that span several clients or wait on timers
/// (a leave is committed within GRP-10's 60 s).
async fn eventually(done: impl Fn() -> bool) {
    for _ in 0..200 {
        if done() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    panic!("condition not reached in time");
}

/// Waits until `done` holds, re-checking after every event (it may already hold).
async fn settle(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<core_api::Event>,
    done: impl Fn() -> bool,
) {
    while !done() {
        next_event(rx).await;
    }
}

async fn until<F: Fn(&core_api::Event) -> bool>(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<core_api::Event>,
    want: F,
) -> core_api::Event {
    loop {
        let e = next_event(rx).await;
        if want(&e) {
            return e;
        }
    }
}

#[tokio::test]
async fn requests_profiles_sealed_sender_and_blocking() {
    // MSG-10, MSG-15, MSG-16.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let mut bob_events = listen(&bob);
    let mut alice_events = listen(&alice);

    let chat = alice.start_chat(&bob_name).await.unwrap();
    let core_api::Event::ConversationStarted {
        request,
        peer_account: alice_id,
        ..
    } = until(&mut bob_events, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await
    else {
        unreachable!()
    };
    assert!(
        request,
        "a chat from a non-contact is a message request (MSG-15)"
    );
    until(&mut bob_events, |e| {
        matches!(e, core_api::Event::ProfileUpdated { .. })
    })
    .await;
    let a = bob.contact(&alice_id).unwrap();
    assert_eq!(
        a.display_name.as_deref(),
        Some("alice display"),
        "requester's profile is visible"
    );
    assert!(bob.is_request(&chat).unwrap());
    assert_eq!(
        bob.send_text(&chat, "too early", None)
            .await
            .unwrap_err()
            .code,
        "request_pending"
    );

    alice.send_text(&chat, "hello", None).await.unwrap();
    until(&mut bob_events, |e| {
        matches!(e, core_api::Event::Message(_))
    })
    .await;

    bob.accept(&chat).await.unwrap();
    let core_api::Event::ProfileUpdated { account } = until(&mut alice_events, |e| {
        matches!(e, core_api::Event::ProfileUpdated { .. })
    })
    .await
    else {
        unreachable!()
    };
    assert_eq!(
        alice.contact(&account).unwrap().display_name.as_deref(),
        Some("bob display")
    );

    // Both hold each other's profile key now, so these go sealed (MSG-10).
    bob.send_text(&chat, "sealed hi", None).await.unwrap();
    let core_api::Event::Message(m) = until(&mut alice_events, |e| {
        matches!(e, core_api::Event::Message(_))
    })
    .await
    else {
        unreachable!()
    };
    assert_eq!(m.text, "sealed hi");

    // MSG-16: after Bob blocks Alice her messages vanish silently; her send still succeeds.
    bob.block(&alice_id).await.unwrap();
    alice.send_text(&chat, "you there?", None).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    assert!(
        !bob.messages(&chat, 100)
            .unwrap()
            .iter()
            .any(|m| m.text == "you there?"),
        "blocked sender's message must not arrive"
    );

    assert_eq!(bob.blocked().unwrap()[0].account_id, alice_id);
    bob.unblock(&alice_id).await.unwrap();
    assert!(bob.blocked().unwrap().is_empty());
    alice.send_text(&chat, "unblocked?", None).await.unwrap();
    let core_api::Event::Message(m) = until(&mut bob_events, |e| {
        matches!(e, core_api::Event::Message(_))
    })
    .await
    else {
        unreachable!()
    };
    assert_eq!(m.text, "unblocked?");
}

#[tokio::test]
async fn replies_reactions_edits_deletes_receipts_typing() {
    // MSG-04, MSG-07..09, MSG-11..14.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    use core_api::{Event, Status};
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let mut bob_events = listen(&bob);
    let mut alice_events = listen(&alice);
    let chat = alice.start_chat(&bob_name).await.unwrap();
    until(&mut bob_events, |e| {
        matches!(e, Event::ConversationStarted { .. })
    })
    .await;
    bob.accept(&chat).await.unwrap();
    until(&mut alice_events, |e| {
        matches!(e, Event::ProfileUpdated { .. })
    })
    .await;

    let first = alice.send_text(&chat, "first", None).await.unwrap();
    assert_eq!(first.status, Status::Sent);
    until(&mut bob_events, |e| matches!(e, Event::Message(_))).await;

    let status = |c: &core_api::SiegelCore, id: &[u8]| {
        c.messages(&chat, 50)
            .unwrap()
            .into_iter()
            .find(|m| m.message_id == id)
            .unwrap()
    };
    settle(&mut alice_events, || {
        status(&alice, &first.message_id).status == Status::Delivered
    })
    .await;

    bob.mark_read(&chat).await.unwrap();
    settle(&mut alice_events, || {
        status(&alice, &first.message_id).status == Status::Read
    })
    .await;

    let reply = bob
        .send_text(&chat, "a reply", Some(&first.message_id))
        .await
        .unwrap();
    let Event::Message(m) = until(&mut alice_events, |e| matches!(e, Event::Message(_))).await
    else {
        unreachable!()
    };
    assert_eq!(m.reply_to.as_deref(), Some(first.message_id.as_slice()));

    bob.react(&chat, &first.message_id, "👍").await.unwrap();
    settle(&mut alice_events, || {
        !status(&alice, &first.message_id).reactions.is_empty()
    })
    .await;
    assert_eq!(status(&alice, &first.message_id).reactions[0].1, "👍");

    assert_eq!(
        bob.edit(&chat, &first.message_id, "not mine")
            .await
            .unwrap_err()
            .code,
        "not_allowed",
        "only the sender edits"
    );
    alice
        .edit(&chat, &first.message_id, "first!")
        .await
        .unwrap();

    settle(&mut bob_events, || status(&bob, &first.message_id).edited).await;
    let m = status(&bob, &first.message_id);
    assert_eq!((m.text.as_str(), m.edited), ("first!", true));
    assert_eq!(bob.versions(&first.message_id).unwrap(), vec!["first"]);

    bob.delete_for_everyone(&chat, &reply.message_id)
        .await
        .unwrap();
    settle(&mut alice_events, || {
        status(&alice, &reply.message_id).deleted
    })
    .await;
    let m = status(&alice, &reply.message_id);
    assert!(m.deleted && m.text.is_empty());

    alice.send_typing(&chat).await.unwrap();
    until(&mut bob_events, |e| matches!(e, Event::Typing { .. })).await;

    // Reciprocal: with read receipts off, Alice sends none and ignores Bob's.
    alice.set_setting(core_api::READ_RECEIPTS, "off").unwrap();
    let second = alice.send_text(&chat, "second", None).await.unwrap();
    until(&mut bob_events, |e| matches!(e, Event::Message(_))).await;
    bob.mark_read(&chat).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    assert_eq!(status(&alice, &second.message_id).status, Status::Delivered);

    alice.delete_for_me(&second.message_id).unwrap();
    assert!(
        !alice
            .messages(&chat, 50)
            .unwrap()
            .iter()
            .any(|m| m.message_id == second.message_id)
    );
}

#[tokio::test]
async fn safety_numbers_and_reregistration_key_change() {
    // CRY-12, CRY-13, ID-09.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    use core_api::Event;
    let (alice, _) = new_user(&url, "alice").await;
    let n = fresh_number();
    let bob_phone = format!("+346{n:08}");
    let bob_dir = std::env::temp_dir().join(format!("siegel-e2e-rebob-{n}"));
    std::fs::create_dir_all(&bob_dir).unwrap();
    let open_bob = |file: &str| {
        std::sync::Arc::new(
            SiegelCore::open(bob_dir.join(file).to_str().unwrap(), &[7; 32], &url).unwrap(),
        )
    };
    let bob = open_bob("one.db");
    register(&bob, &bob_phone).await;
    let bob_name = format!("rebob{n}");
    bob.set_username(&bob_name).await.unwrap();
    let mut bob_events = listen(&bob);
    let mut alice_events = listen(&alice);

    let chat = alice.start_chat(&bob_name).await.unwrap();
    let Event::ConversationStarted {
        group_id: bob_chat, ..
    } = until(&mut bob_events, |e| {
        matches!(e, Event::ConversationStarted { .. })
    })
    .await
    else {
        unreachable!()
    };
    bob.accept(&bob_chat).await.unwrap();

    let number = alice.safety_number(&chat).unwrap().unwrap();
    assert_eq!(number.len(), 60);
    assert_eq!(
        bob.safety_number(&bob_chat).unwrap().as_deref(),
        Some(number.as_str())
    );
    assert!(!alice.verify_safety_number(&chat, &"0".repeat(60)).unwrap());
    assert!(alice.verify_safety_number(&chat, &number).unwrap());
    let bob_id = alice.conversations().unwrap()[0].peer_account.clone();
    assert!(alice.contact(&bob_id).unwrap().verified);

    // Bob re-registers on a new phone: new identity key, old device revoked (ID-09).
    let new_bob = open_bob("two.db");
    register(&new_bob, &bob_phone).await;
    until(&mut bob_events, |e| matches!(e, Event::Deregistered)).await;
    assert_eq!(
        new_bob.username().as_deref(),
        Some(bob_name.as_str()),
        "ID-09: the @username comes back with the account"
    );
    assert!(!new_bob.has_registration_lock());
    let mut new_bob_events = listen(&new_bob);

    // Alice's next message finds Bob's devices revoked, re-keys the same chat and delivers.
    alice.send_text(&chat, "still there?", None).await.unwrap();
    let Event::Message(m) = until(&mut new_bob_events, |e| matches!(e, Event::Message(_))).await
    else {
        unreachable!()
    };
    assert_eq!(m.text, "still there?");
    let messages = alice.messages(&chat, 50).unwrap();
    assert!(
        messages.iter().any(|m| m.key_change),
        "CRY-13 notice in the chat"
    );
    assert!(
        !alice.contact(&bob_id).unwrap().verified,
        "verified mark cleared"
    );
    assert_ne!(alice.safety_number(&chat).unwrap().unwrap(), number);
    assert_eq!(
        alice.conversations().unwrap().len(),
        1,
        "same chat, not a new one"
    );

    // New Bob answers in his new chat; it lands in Alice's existing one.
    new_bob.accept(&m.group_id).await.unwrap();
    new_bob
        .send_text(&m.group_id, "new phone", None)
        .await
        .unwrap();
    let Event::Message(r) = until(&mut alice_events, |e| matches!(e, Event::Message(_))).await
    else {
        unreachable!()
    };
    assert_eq!((r.group_id, r.text.as_str()), (chat, "new phone"));
}

#[tokio::test]
async fn push_token_and_drain_after_wake_up() {
    // MSG-17: a woken app fetches what is queued, then returns.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    bob.set_push_token("fcm-token-for-test").await.unwrap();
    let chat = alice.start_chat(&bob_name).await.unwrap();
    alice.send_text(&chat, "wake up", None).await.unwrap();

    let got = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = got.clone();
    let start = std::time::Instant::now();
    bob.drain(move |e| sink.lock().unwrap().push(e))
        .await
        .unwrap();
    assert!(start.elapsed() < std::time::Duration::from_secs(15));
    assert!(
        got.lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, core_api::Event::Message(m) if m.text == "wake up"))
    );
}

/// Store screenshot extras: three named contacts that reply with scripted lines. Writes their
/// @usernames to $DEMO_FILE, one per line, then answers for ten minutes.
///   SIEGEL_TEST_SERVER_URL=... DEMO_FILE=/tmp/demo cargo test -p core-api --test e2e demo_peers -- --ignored
#[tokio::test]
#[ignore]
async fn demo_peers() {
    let url = std::env::var("SIEGEL_TEST_SERVER_URL").unwrap();
    let scripts: [(&str, &str, &[&str]); 3] = [
        (
            "lena",
            "Lena Weber",
            &[
                "Yes! 10:00 at the Hauptbahnhof 🚆",
                "Bring the good coffee ☕",
            ],
        ),
        (
            "jonas",
            "Jonas",
            &["That hike was amazing. Same trail next month?"],
        ),
        (
            "klara",
            "Klara",
            &["Happy birthday!! 🎉 Dinner on me this week"],
        ),
    ];
    let mut names = Vec::new();
    let mut links = Vec::new();
    let mut tasks = Vec::new();
    for (tag, display, lines) in scripts {
        let (peer, name) = new_user(&url, tag).await;
        peer.set_display_name(display).unwrap();
        names.push(name);
        links.push(peer.contact_link().unwrap().unwrap_or_default());
        let mut events = listen(&peer);
        tasks.push(tokio::spawn(async move {
            let mut next = 0;
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(600);
            while let Ok(Some(e)) = tokio::time::timeout_at(deadline, events.recv()).await {
                match e {
                    core_api::Event::ConversationStarted { group_id, .. } => {
                        peer.accept(&group_id).await.unwrap();
                    }
                    core_api::Event::Message(m) if next < lines.len() => {
                        peer.mark_read(&m.group_id).await.unwrap();
                        peer.react(&m.group_id, &m.message_id, "❤️").await.unwrap();
                        for line in &lines[next..] {
                            peer.send_typing(&m.group_id).await.unwrap();
                            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                            peer.send_text(&m.group_id, line, None).await.unwrap();
                        }
                        next = lines.len();
                    }
                    _ => {}
                }
            }
        }));
    }
    let file = std::env::var("DEMO_FILE").unwrap();
    std::fs::write(&file, names.join("\n")).unwrap();
    std::fs::write(format!("{file}.links"), links.join("\n")).unwrap();
    for t in tasks {
        t.await.unwrap();
    }
}

/// Two users who are each other's contacts, with a 1:1 chat accepted on both sides.
async fn befriend(
    a: &std::sync::Arc<SiegelCore>,
    a_events: &mut tokio::sync::mpsc::UnboundedReceiver<core_api::Event>,
    b: &std::sync::Arc<SiegelCore>,
    b_name: &str,
    b_events: &mut tokio::sync::mpsc::UnboundedReceiver<core_api::Event>,
) {
    let chat = a.start_chat(b_name).await.unwrap();
    until(b_events, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await;
    b.accept(&chat).await.unwrap();
    until(a_events, |e| {
        matches!(e, core_api::Event::ProfileUpdated { .. })
    })
    .await;
}

fn group_names(c: &SiegelCore, gid: &[u8]) -> Vec<String> {
    c.group_info(gid)
        .unwrap()
        .members
        .into_iter()
        .map(|m| m.username.or(m.display_name).unwrap_or_default())
        .collect()
}

#[tokio::test]
async fn groups_invites_roles_rename_add_leave() {
    // GRP-01..GRP-13.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    use core_api::{Event, GroupEventKind, Status};
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let (carol, carol_name) = new_user(&url, "carol").await;
    let (dave, dave_name) = new_user(&url, "dave").await;
    let (mut ae, mut be, mut ce, mut de) =
        (listen(&alice), listen(&bob), listen(&carol), listen(&dave));
    befriend(&alice, &mut ae, &bob, &bob_name, &mut be).await;

    let gid = alice
        .create_group("Hikers", &[bob_name.clone(), carol_name.clone()])
        .await
        .unwrap();
    // Bob is Alice's contact and joins; Carol isn't and gets an invite (GRP-11).
    let Event::ConversationStarted {
        request, group_id, ..
    } = until(&mut be, |e| matches!(e, Event::ConversationStarted { .. })).await
    else {
        unreachable!()
    };
    assert_eq!((request, group_id.as_slice()), (false, gid.as_slice()));
    let Event::ConversationStarted { request, .. } =
        until(&mut ce, |e| matches!(e, Event::ConversationStarted { .. })).await
    else {
        unreachable!()
    };
    assert!(request, "an add from a non-contact is an invite");
    let info = bob.group_info(&gid).unwrap();
    assert_eq!(
        (info.name.as_str(), info.members.len(), info.me_admin),
        ("Hikers", 3, false)
    );
    assert!(info.members[0].admin, "the creator is admin (GRP-04)");

    let hi = alice.send_text(&gid, "hi group", None).await.unwrap();
    for rx in [&mut be, &mut ce] {
        until(
            rx,
            |e| matches!(e, Event::Message(m) if m.text == "hi group"),
        )
        .await;
    }
    // GRP-13: delivered once both got it; Bob's read receipt is recorded per member.
    settle(&mut ae, || {
        alice
            .messages(&gid, 50)
            .unwrap()
            .iter()
            .any(|m| m.message_id == hi.message_id && m.status == Status::Delivered)
    })
    .await;
    bob.mark_read(&gid).await.unwrap();
    settle(&mut ae, || {
        alice
            .message_receipts(&hi.message_id)
            .unwrap()
            .iter()
            .any(|(_, s)| *s == Status::Read)
    })
    .await;

    carol.accept(&gid).await.unwrap();
    carol.send_text(&gid, "glad to join", None).await.unwrap();
    until(
        &mut ae,
        |e| matches!(e, Event::Message(m) if m.text == "glad to join"),
    )
    .await;

    // GRP-05, GRP-06: only admins rename and remove by default.
    assert_eq!(
        bob.rename_group(&gid, "Bob's").await.unwrap_err().code,
        "not_allowed"
    );
    let carol_id = carol
        .group_info(&gid)
        .unwrap()
        .members
        .into_iter()
        .find(|m| m.me)
        .unwrap()
        .account;
    assert_eq!(
        bob.remove_member(&gid, &carol_id).await.unwrap_err().code,
        "not_allowed"
    );
    let bob_id = bob
        .group_info(&gid)
        .unwrap()
        .members
        .into_iter()
        .find(|m| m.me)
        .unwrap()
        .account;
    // GRP-15: a mention travels inside the encrypted message.
    alice
        .send_text_mentioning(&gid, "@bob look", None, std::slice::from_ref(&bob_id))
        .await
        .unwrap();
    let Event::Message(m) = until(
        &mut be,
        |e| matches!(e, Event::Message(m) if m.text == "@bob look"),
    )
    .await
    else {
        unreachable!()
    };
    assert_eq!(m.mentions, vec![bob_id.clone()]);
    alice.set_admin(&gid, &bob_id, true).await.unwrap();
    settle(&mut be, || bob.group_info(&gid).unwrap().me_admin).await;
    bob.rename_group(&gid, "Hikers 2026").await.unwrap();
    for (c, rx) in [(&alice, &mut ae), (&carol, &mut ce)] {
        settle(rx, || c.group_info(&gid).unwrap().name == "Hikers 2026").await;
    }

    // GRP-09: Bob, now admin, adds Dave; Dave sees only what comes after.
    bob.add_members(&gid, std::slice::from_ref(&dave_name))
        .await
        .unwrap();
    until(&mut de, |e| matches!(e, Event::ConversationStarted { .. })).await;
    assert_eq!(dave.group_info(&gid).unwrap().name, "Hikers 2026");
    assert!(
        !dave
            .messages(&gid, 50)
            .unwrap()
            .iter()
            .any(|m| m.text == "hi group")
    );
    settle(&mut ae, || {
        alice.group_info(&gid).unwrap().members.len() == 4
    })
    .await;

    // GRP-10: Carol leaves; someone commits it within seconds.
    carol.leave_group(&gid).await.unwrap();
    assert_eq!(
        carol
            .send_text(&gid, "still here?", None)
            .await
            .unwrap_err()
            .code,
        "group_left"
    );
    for c in [&alice, &bob, &dave] {
        eventually(|| !group_names(c, &gid).contains(&carol_name)).await;
    }

    // GRP-12: system lines tell the story.
    let kinds: Vec<GroupEventKind> = alice
        .messages(&gid, 100)
        .unwrap()
        .into_iter()
        .filter_map(|m| m.event.map(|e| e.kind))
        .collect();
    for k in [
        GroupEventKind::Created,
        GroupEventKind::AdminAdded,
        GroupEventKind::Renamed,
        GroupEventKind::Added,
        GroupEventKind::Left,
    ] {
        assert!(kinds.contains(&k), "{k:?} missing from {kinds:?}");
    }
}

#[tokio::test]
async fn concurrent_admin_commits_converge() {
    // AC-04: both admins commit at the same epoch; one wins, the other rebases.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let (mut ae, mut be) = (listen(&alice), listen(&bob));
    befriend(&alice, &mut ae, &bob, &bob_name, &mut be).await;
    let gid = alice
        .create_group("Race", std::slice::from_ref(&bob_name))
        .await
        .unwrap();
    until(&mut be, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await;
    let bob_id = bob
        .group_info(&gid)
        .unwrap()
        .members
        .into_iter()
        .find(|m| m.me)
        .unwrap()
        .account;
    alice.set_admin(&gid, &bob_id, true).await.unwrap();
    settle(&mut be, || bob.group_info(&gid).unwrap().me_admin).await;

    let (a, b) = tokio::join!(
        alice.rename_group(&gid, "Alpha"),
        bob.rename_group(&gid, "Bravo")
    );
    a.unwrap();
    b.unwrap();
    eventually(|| alice.group_info(&gid).unwrap().name == bob.group_info(&gid).unwrap().name).await;
    let name = alice.group_info(&gid).unwrap().name;
    assert!(name == "Alpha" || name == "Bravo");
}

#[tokio::test]
async fn removed_member_cannot_read_later_messages() {
    // AC-03 at a size CI can afford; SIEGEL_AC03_MEMBERS=256 runs the full test.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let n: usize = std::env::var("SIEGEL_AC03_MEMBERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(12);
    let (admin, _) = new_user(&url, "admin").await;
    let mut members = Vec::new();
    for i in 1..n {
        members.push(new_user(&url, &format!("m{i}x")).await);
    }
    let names: Vec<String> = members.iter().map(|(_, name)| name.clone()).collect();
    let gid = admin.create_group("Big", &names).await.unwrap();
    let (gone, _) = members.remove(0);
    let mut gone_events = listen(&gone);
    let (stay, _) = &members[members.len() - 1];
    let mut stay_events = listen(stay);
    until(&mut gone_events, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await;
    until(&mut stay_events, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await;
    assert_eq!(stay.group_info(&gid).unwrap().members.len(), n);

    let gone_id = gone
        .group_info(&gid)
        .unwrap()
        .members
        .into_iter()
        .find(|m| m.me)
        .unwrap()
        .account;
    admin.remove_member(&gid, &gone_id).await.unwrap();
    settle(&mut gone_events, || {
        gone.conversations()
            .unwrap()
            .iter()
            .any(|c| c.group_id == gid && c.left)
    })
    .await;
    admin.send_text(&gid, "after removal", None).await.unwrap();
    until(
        &mut stay_events,
        |e| matches!(e, core_api::Event::Message(m) if m.text == "after removal"),
    )
    .await;
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    assert!(
        !gone
            .messages(&gid, 100)
            .unwrap()
            .iter()
            .any(|m| m.text == "after removal"),
        "a removed member must not decrypt later messages"
    );
}

#[tokio::test]
async fn contact_links_skip_the_request_and_verify() {
    // DISC-08, DISC-02.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, _) = new_user(&url, "bob").await;
    let (carol, _) = new_user(&url, "carol").await;
    let mut bob_events = listen(&bob);
    let link = bob.contact_link().unwrap().expect("on from registration");
    assert!(link.starts_with(&format!("{url}/u/")));

    // A tampered fingerprint means a different key: refused.
    let (head, frag) = link.split_once('#').unwrap();
    let forged = format!(
        "{head}#AAAAAAAAAAAAAAAA{}",
        &frag[frag.find('.').unwrap()..]
    );
    assert_eq!(
        alice.open_contact_link(&forged).await.unwrap_err().code,
        "link_key_mismatch"
    );

    let chat = alice.open_contact_link(&link).await.unwrap();
    let bob_id = alice.conversations().unwrap()[0].peer_account.clone();
    assert!(
        alice.contact(&bob_id).unwrap().verified,
        "the link verifies Bob (DISC-02)"
    );
    let core_api::Event::ConversationStarted { group_id, .. } = until(&mut bob_events, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await
    else {
        unreachable!()
    };
    settle(&mut bob_events, || !bob.is_request(&group_id).unwrap()).await;
    bob.send_text(&group_id, "no request needed", None)
        .await
        .unwrap();
    assert!(!alice.is_request(&chat).unwrap());

    // After a reset the old link is just a username: Carol lands in requests.
    bob.reset_contact_link().unwrap();
    carol.open_contact_link(&link).await.unwrap();
    let core_api::Event::ConversationStarted {
        group_id: from_carol,
        ..
    } = until(&mut bob_events, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await
    else {
        unreachable!()
    };
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    assert!(bob.is_request(&from_carol).unwrap());
    bob.set_contact_link(false).unwrap();
    assert_eq!(bob.contact_link().unwrap(), None);
}

#[tokio::test]
async fn group_invite_links() {
    // GRP-16: join by link with no member online, admins only, revocable.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    use core_api::Event;
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let (dave, _) = new_user(&url, "dave").await;
    let (erin, _) = new_user(&url, "erin").await;
    let (mut ae, mut be) = (listen(&alice), listen(&bob));
    let gid = alice
        .create_group("Climbers", std::slice::from_ref(&bob_name))
        .await
        .unwrap();
    until(&mut be, |e| matches!(e, Event::ConversationStarted { .. })).await;

    assert_eq!(
        bob.create_group_link(&gid).await.unwrap_err().code,
        "not_allowed"
    );
    let link = alice.create_group_link(&gid).await.unwrap();
    assert!(link.starts_with(&format!("{url}/g/")));
    assert_eq!(alice.group_links(&gid).unwrap().len(), 1);

    // Dave isn't anyone's contact and nobody needs to be online for him to join.
    let preview = dave.preview_group_link(&link).await.unwrap();
    assert_eq!((preview.name.as_str(), preview.members), ("Climbers", 2));
    let dave_gid = dave.join_group_link(&link).await.unwrap();
    assert_eq!(dave_gid, gid);
    for (c, rx) in [(&alice, &mut ae), (&bob, &mut be)] {
        settle(rx, || c.group_info(&gid).unwrap().members.len() == 3).await;
    }
    let mut de = listen(&dave);
    dave.send_text(&gid, "hi from the link", None)
        .await
        .unwrap();
    until(
        &mut ae,
        |e| matches!(e, Event::Message(m) if m.text == "hi from the link"),
    )
    .await;
    alice.send_text(&gid, "welcome", None).await.unwrap();
    until(
        &mut de,
        |e| matches!(e, Event::Message(m) if m.text == "welcome"),
    )
    .await;

    // Revoked: the link no longer works.
    let id = alice.group_links(&gid).unwrap()[0].id.clone();
    alice.revoke_group_link(&gid, &id).await.unwrap();
    assert_eq!(
        erin.preview_group_link(&link).await.unwrap_err().code,
        "invite_not_found"
    );
}

#[tokio::test]
async fn voice_notes_upload_download_and_delete() {
    // MED-01..06, MED-09, MSG-11: through the real server and its S3 store.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let mut alice_events = listen(&alice);
    let mut bob_events = listen(&bob);
    befriend(&alice, &mut alice_events, &bob, &bob_name, &mut bob_events).await;
    let chat = alice.conversations().unwrap()[0].group_id.clone();

    let audio: Vec<u8> = (0..300_000u32).map(|i| (i * 7 % 251) as u8).collect();
    let sent = alice
        .send_attachment(
            &chat,
            core_api::OutgoingAttachment {
                data: audio.clone(),
                mime_type: "audio/mp4".into(),
                file_name: String::new(),
                duration_ms: 4200,
                voice_note: true,
                waveform: vec![10, 200, 90],
            },
            None,
        )
        .await
        .unwrap();
    assert_eq!(sent.status, core_api::Status::Sent);
    let got = until(&mut bob_events, |e| {
        matches!(e, core_api::Event::Message(_))
    })
    .await;
    let core_api::Event::Message(m) = got else {
        unreachable!()
    };
    let info = m.attachment.clone().expect("an attachment");
    assert!(info.voice_note && info.duration_ms == 4200 && info.waveform == vec![10, 200, 90]);
    assert_eq!(bob.attachment_data(&m.message_id).await.unwrap(), audio);
    assert_eq!(
        alice.attachment_data(&sent.message_id).await.unwrap(),
        audio,
        "sender keeps it"
    );

    // Delete for everyone removes the blob from the receiver's device too.
    let media = std::env::temp_dir()
        .join(format!("siegel-e2e-bob-{}", &bob_name[3..]))
        .join("core.db.media");
    assert_eq!(std::fs::read_dir(&media).unwrap().count(), 1);
    alice
        .delete_for_everyone(&chat, &sent.message_id)
        .await
        .unwrap();
    until(&mut bob_events, |e| {
        matches!(e, core_api::Event::Updated { .. })
    })
    .await;
    assert_eq!(std::fs::read_dir(&media).unwrap().count(), 0);
}

#[tokio::test]
async fn profile_pictures_reach_contacts() {
    // MED-15: set, change and remove a picture; contacts get each change, and a new name too.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let mut alice_events = listen(&alice);
    let mut bob_events = listen(&bob);
    befriend(&alice, &mut alice_events, &bob, &bob_name, &mut bob_events).await;
    let alice_id = bob.conversations().unwrap()[0].peer_account.clone();

    alice.set_avatar(Some(vec![1; 5000])).await.unwrap();
    eventually(|| bob.avatar(&alice_id) == Some(vec![1; 5000])).await;
    assert_eq!(alice.my_avatar(), Some(vec![1; 5000]));

    alice.set_display_name("Alice Renamed").unwrap();
    alice.set_avatar(Some(vec![2; 6000])).await.unwrap();
    eventually(|| {
        bob.avatar(&alice_id) == Some(vec![2; 6000])
            && bob.contact(&alice_id).unwrap().display_name.as_deref() == Some("Alice Renamed")
    })
    .await;

    alice.set_avatar(None).await.unwrap();
    eventually(|| bob.avatar(&alice_id).is_none()).await;
}

#[tokio::test]
async fn group_pictures() {
    // MED-15, GRP-06: the admin sets the picture, members get it; a member may not change it.
    let Ok(url) = std::env::var("SIEGEL_TEST_SERVER_URL") else {
        return;
    };
    let (alice, _) = new_user(&url, "alice").await;
    let (bob, bob_name) = new_user(&url, "bob").await;
    let (mut ae, mut be) = (listen(&alice), listen(&bob));
    befriend(&alice, &mut ae, &bob, &bob_name, &mut be).await;
    let gid = alice
        .create_group("Pics", std::slice::from_ref(&bob_name))
        .await
        .unwrap();
    until(&mut be, |e| {
        matches!(e, core_api::Event::ConversationStarted { .. })
    })
    .await;

    alice
        .set_group_avatar(&gid, Some(vec![5; 4000]))
        .await
        .unwrap();
    assert_eq!(alice.group_avatar(&gid), Some(vec![5; 4000]));
    eventually(|| bob.group_avatar(&gid) == Some(vec![5; 4000])).await;
    let photo_line = |c: &SiegelCore| {
        c.messages(&gid, 50).unwrap().iter().any(|m| {
            m.event
                .as_ref()
                .is_some_and(|e| e.kind == core_api::GroupEventKind::Avatar)
        })
    };
    assert!(photo_line(&alice) && photo_line(&bob));

    assert!(
        bob.set_group_avatar(&gid, Some(vec![6; 10])).await.is_err(),
        "admins only by default"
    );
    alice.set_group_avatar(&gid, None).await.unwrap();
    eventually(|| bob.group_avatar(&gid).is_none()).await;
}

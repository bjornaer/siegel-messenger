//! Headless client against a real server (section 15 test levels).
//! Needs the local stack: docker compose up -d, then
//!   SIEGEL_TEST_SERVER_URL=http://localhost:58080 cargo test -p core-api
//! The dev server stubs SMS, so the OTP is read from its database with `docker compose exec`.

use core_api::{Platform, SiegelCore};

/// Tests run in parallel; "newest OTP in the DB" is only safe for one registration at a time.
static REGISTER: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn register(core: &SiegelCore, phone: &str) {
    let _one_at_a_time = REGISTER.lock().await;
    core.request_otp(phone, "").await.unwrap();
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

    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_micros()
        % 100_000_000;
    let phone = format!("+346{n:08}");
    assert_eq!(
        core.request_otp("0034", "").await.unwrap_err().code,
        "phone_invalid"
    );
    let one_at_a_time = REGISTER.lock().await;
    core.request_otp(&phone, "").await.unwrap();
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
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_micros()
        % 100_000_000;
    let dir = std::env::temp_dir().join(format!("siegel-e2e-{tag}-{n}"));
    std::fs::create_dir_all(&dir).unwrap();
    let core = SiegelCore::open(dir.join("core.db").to_str().unwrap(), &[7; 32], url).unwrap();
    let phone = format!("+346{n:08}");
    register(&core, &phone).await;
    let name = format!("{tag}{n}");
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
        alice.peer_username(&peer).as_deref(),
        Some(bob_name.as_str())
    );
    let core_api::Event::ConversationStarted { group_id, .. } = next_event(&mut bob_events).await
    else {
        panic!("welcome")
    };
    assert_eq!(group_id, chat);

    let canary = format!("canary-{}", std::process::id());
    alice
        .send_text(&chat, &format!("hello bob {canary}"))
        .await
        .unwrap();
    let core_api::Event::Message(m) = next_event(&mut bob_events).await else {
        panic!("message")
    };
    assert_eq!(
        (m.text.as_str(), m.outgoing),
        (format!("hello bob {canary}").as_str(), false)
    );

    bob.send_text(&chat, "hi alice").await.unwrap();
    let core_api::Event::Message(m) = next_event(&mut alice_events).await else {
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
    assert!(
        !String::from_utf8_lossy(&dump.stdout).contains(&canary),
        "plaintext reached the server"
    );
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
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(300);
    while let Ok(Some(e)) = tokio::time::timeout_at(deadline, events.recv()).await {
        if let core_api::Event::Message(m) = e {
            peer.send_text(&m.group_id, &format!("pong: {}", m.text))
                .await
                .unwrap();
        }
    }
}

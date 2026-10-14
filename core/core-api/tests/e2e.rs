//! Headless client against a real server (section 15 test levels).
//! Needs the local stack: docker compose up -d, then
//!   SIEGEL_TEST_SERVER_URL=http://localhost:58080 cargo test -p core-api
//! The dev server stubs SMS, so the OTP is read from its database with `docker compose exec`.

use core_api::{Platform, SiegelCore};

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
    assert!(core.is_registered());

    let name = format!("e2e{n}");
    core.set_username(&name).await.unwrap();
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

    core.delete_account().await.unwrap();
    assert!(!db.exists(), "local DB wiped");
    assert_eq!(
        core.set_username("whatever").await.unwrap_err().code,
        "wiped"
    );
}

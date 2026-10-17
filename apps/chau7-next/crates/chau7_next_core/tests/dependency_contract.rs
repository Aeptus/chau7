//! Wire and storage contracts protected while updating registry dependencies.
//! All database fixtures are owned temporary files or private in-memory stores.
use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chau7_next_core::{
    config,
    history_store::HistoryStore,
    telemetry::{
        run::TelemetryRun,
        store::{StoreReadiness, TelemetryStore},
    },
};
use rusqlite::Connection;
use sha2::{Digest, Sha256};

#[test]
fn sha256_wire_hashes_remain_canonical() {
    for (bytes, expected) in [
        (
            &b""[..],
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ),
        (
            &b"abc"[..],
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ),
    ] {
        let digest = Sha256::digest(bytes);
        assert_eq!(
            digest
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>(),
            expected
        );
        let fixed: [u8; 32] = digest.into();
        assert_eq!(fixed.len(), 32);
    }
}

#[test]
fn base64_padding_and_alphabets_keep_the_wire_format() {
    for (plain, padded, url) in [
        (&b""[..], "", ""),
        (&b"f"[..], "Zg==", "Zg"),
        (&b"fo"[..], "Zm8=", "Zm8"),
        (&b"foo"[..], "Zm9v", "Zm9v"),
        (&[0xfb, 0xff][..], "+/8=", "-_8"),
    ] {
        assert_eq!(STANDARD.encode(plain), padded);
        assert_eq!(URL_SAFE_NO_PAD.encode(plain), url);
        assert_eq!(STANDARD.decode(padded).unwrap(), plain);
        assert_eq!(URL_SAFE_NO_PAD.decode(url).unwrap(), plain);
    }
    for malformed in ["Zg", "Zh==", "Zg===", "Zg==\n", "Zg==A", "_w==", "Zg==\0"] {
        assert!(
            STANDARD.decode(malformed).is_err(),
            "accepted {malformed:?}"
        );
    }
    for malformed in ["Zg==", "Zh", "+w", "Zg\n", "Zg\0"] {
        assert!(
            URL_SAFE_NO_PAD.decode(malformed).is_err(),
            "accepted {malformed:?}"
        );
    }
}

#[test]
fn toml_validator_preserves_the_swift_dialect_and_explicit_zero() {
    let text = "# keep comments\n[next]\n// explicit indefinite\ntelemetry_retention_days = 0\n[general]\n# keep spelling\nshell = \"/bin/zsh\"\n";
    let before = text.as_bytes().to_vec();
    assert!(config::is_valid_config(text));
    let raw = config::parse_raw(text);
    assert_eq!(raw["next"]["telemetry_retention_days"].as_int(), Some(0));
    assert_eq!(raw["general"]["shell"].as_str(), Some("/bin/zsh"));
    assert_eq!(text.as_bytes(), before);
    // The Swift-compatible parser preserves inline value comments as text.
    let inline = config::parse_raw("[next]\ntelemetry_retention_days = 0 // explicit indefinite\n");
    assert_eq!(inline["next"]["telemetry_retention_days"].as_int(), None);
    assert_eq!(
        inline["next"]["telemetry_retention_days"].as_str(),
        Some("0 // explicit indefinite")
    );
    for malformed in [
        "[next] # comment\ntelemetry_retention_days = 0\n",
        "[next] // comment\ntelemetry_retention_days = 0\n",
        "[next]\ntelemetry_retention_days = [\n",
        "[next]\ntelemetry_retention_days = {\n",
        "[next]\ntelemetry_retention_days = \"unterminated\n",
    ] {
        assert!(
            !config::is_valid_config(malformed),
            "accepted {malformed:?}"
        );
    }
}

#[test]
fn upgraded_sqlite_preserves_legacy_history_rows_and_nullable_fields() {
    let root =
        std::env::temp_dir().join(format!("chau7-next-dependency-db-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&root).unwrap();
    let database = root.join("history.sqlite");
    let old_schema = Connection::open(&database).unwrap();
    old_schema
        .execute_batch(
            "CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT, command TEXT NOT NULL,
        directory TEXT, exit_code INTEGER, shell TEXT, tab_id TEXT,
        session_id TEXT, timestamp REAL NOT NULL, duration REAL);
        PRAGMA user_version = 0;",
        )
        .unwrap();
    old_schema
        .execute(
            "INSERT INTO history (command,directory,timestamp) VALUES (?1,?2,?3)",
            rusqlite::params![
                "printf 'été 日本語'",
                "/synthetic/repository",
                1_700_000_000.125_f64
            ],
        )
        .unwrap();
    old_schema.close().unwrap();
    {
        let store = HistoryStore::open(&database).unwrap();
        assert_eq!(store.total_count(), 1);
        let rows = store.recent(10);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].command, "printf 'été 日本語'");
        assert_eq!(rows[0].exit_code, None);
        assert_eq!(rows[0].session_id, None);
        assert_eq!(rows[0].timestamp.timestamp_millis(), 1_700_000_000_125);
        assert_eq!(store.search("日本語", 10).len(), 1);
    }
    let reopened = Connection::open(&database).unwrap();
    assert_eq!(
        reopened
            .query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(
        reopened
            .query_row("SELECT count(*) FROM history", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    reopened.close().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn upgraded_sqlite_store_checked_close_still_rejects_late_writes() {
    // Private connection: no recorder, providers, process globals or profile.
    let store = TelemetryStore::in_memory();
    assert_eq!(store.readiness(), StoreReadiness::Ready);
    let run = TelemetryRun::new("synthetic", "/synthetic/repository");
    store.try_insert_run(&run).unwrap();
    assert_eq!(store.run_count(), 1);
    store.close().unwrap();
    store.close().unwrap();
    assert_eq!(store.readiness(), StoreReadiness::Closed);
    assert!(store.try_insert_run(&run).is_err());
    assert_eq!(store.failure_count(), 1);
}

#[test]
fn unsigned_sql_values_keep_checked_integer_boundaries() {
    let connection = Connection::open_in_memory().unwrap();
    assert_eq!(
        connection
            .query_row("SELECT ?", [i64::MAX], |row| row.get::<_, u64>(0))
            .unwrap(),
        i64::MAX as u64
    );
    assert!(
        connection
            .query_row("SELECT -1", [], |row| row.get::<_, u64>(0))
            .is_err()
    );
    assert!(
        connection
            .query_row("SELECT -1", [], |row| row.get::<_, usize>(0))
            .is_err()
    );
    connection
        .execute_batch("CREATE TABLE values_test (number INTEGER NOT NULL)")
        .unwrap();
    assert!(
        connection
            .execute("INSERT INTO values_test VALUES (?)", [u64::MAX])
            .is_err()
    );
    assert_eq!(
        connection
            .query_row("SELECT count(*) FROM values_test", [], |row| row
                .get::<_, usize>(0))
            .unwrap(),
        0
    );
    connection.close().unwrap();
}

//! Runs the production OS adapter without compiling the GPUI app.
#![cfg(unix)]
#[path = "../../chau7_next/src/remote/ipc.rs"]
mod ipc;
#[path = "../../chau7_next/src/remote/scheduling.rs"]
mod scheduling;

#[test]
#[ignore = "owned native idle fixture; run explicitly with --exact --ignored --nocapture"]
fn remote_ipc_idle_native_fixture() {
    use std::io::Write;
    let dir =
        std::path::PathBuf::from("/tmp").join(format!("c7-ipc-{}", uuid::Uuid::new_v4().simple()));
    let mut server = ipc::IpcServer::start(&dir.join("fixture.sock"), None).unwrap();
    println!("IPC_IDLE_READY {}", std::process::id());
    std::io::stdout().flush().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(10));
    server.stop();
    let _ = std::fs::remove_dir_all(dir);
}

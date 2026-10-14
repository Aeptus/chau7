//! Read-only saved-state inspection without starting the Chau7 application.
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::swift_restore_import::{
    SwiftRestoreSource, prepare_swift_import, validate_source_snapshot,
};
use std::path::PathBuf;
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 1 {
        eprintln!("Usage: inspect_swift_restore /absolute/source/home");
        std::process::exit(2);
    }
    let home = PathBuf::from(&args[0]);
    if !home.is_absolute() {
        eprintln!("Source home must be absolute");
        std::process::exit(2);
    }
    let root = DataRoot::with_home(home, false);
    let source = SwiftRestoreSource {
        bundle_root: root.swift_restore_bundle_root(),
        preferences_file: root.swift_preferences_file(),
    };
    match prepare_swift_import(&source).and_then(|plan| {
        if let Some(plan)=plan {validate_source_snapshot(&plan)?;let s=&plan.summary;
            println!("windows={} tabs={} panes={} context_bytes={} truncated_contexts={} dropped_ai_identities={} dropped_tab_preview_contexts={} dropped_dashboard_scopes={} dropped_resume_directories={}",s.windows,s.tabs,s.panes,s.context_bytes,s.truncated_contexts,s.dropped_unsupported_ai_identities,s.dropped_tab_preview_contexts,s.dropped_dashboard_group_ids,s.dropped_resume_directories);
        } else {println!("windows=0 tabs=0 panes=0");}
        Ok(())
    }) {
        Ok(())=>{},Err(error)=>{eprintln!("Restore inspection refused: {error}");std::process::exit(2);},
    }
}

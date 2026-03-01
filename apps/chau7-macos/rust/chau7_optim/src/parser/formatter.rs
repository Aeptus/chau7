/// Token-efficient formatting trait for canonical types
use super::types::*;

/// Output formatting modes
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatMode {
    /// Ultra-compact: Summary only (default)
    Compact,
    /// Verbose: Include details
    Verbose,
    /// Ultra-compressed: Symbols and abbreviations
    Ultra,
}

impl FormatMode {
    pub fn from_verbosity(verbosity: u8) -> Self {
        match verbosity {
            0 => FormatMode::Compact,
            1 => FormatMode::Verbose,
            _ => FormatMode::Ultra,
        }
    }
}

/// Trait for formatting canonical types into token-efficient strings
pub trait TokenFormatter {
    /// Format as compact summary (default)
    fn format_compact(&self) -> String;

    /// Format with details (verbose mode)
    fn format_verbose(&self) -> String;

    /// Format with symbols (ultra-compressed mode)
    fn format_ultra(&self) -> String;

    /// Format according to mode
    fn format(&self, mode: FormatMode) -> String {
        match mode {
            FormatMode::Compact => self.format_compact(),
            FormatMode::Verbose => self.format_verbose(),
            FormatMode::Ultra => self.format_ultra(),
        }
    }
}

impl TokenFormatter for TestResult {
    fn format_compact(&self) -> String {
        let mut lines = vec![format!("PASS ({}) FAIL ({})", self.passed, self.failed)];

        if !self.failures.is_empty() {
            lines.push(String::new());
            for (idx, failure) in self.failures.iter().enumerate().take(5) {
                lines.push(format!("{}. {}", idx + 1, failure.test_name));
                let error_preview: String = failure
                    .error_message
                    .lines()
                    .take(2)
                    .collect::<Vec<_>>()
                    .join(" ");
                lines.push(format!("   {}", error_preview));
            }

            if self.failures.len() > 5 {
                lines.push(format!("\n... +{} more failures", self.failures.len() - 5));
            }
        }

        if let Some(duration) = self.duration_ms {
            lines.push(format!("\nTime: {}ms", duration));
        }

        lines.join("\n")
    }

    fn format_verbose(&self) -> String {
        let mut lines = vec![format!(
            "Tests: {} passed, {} failed, {} skipped (total: {})",
            self.passed, self.failed, self.skipped, self.total
        )];

        if !self.failures.is_empty() {
            lines.push("\nFailures:".to_string());
            for (idx, failure) in self.failures.iter().enumerate() {
                lines.push(format!(
                    "\n{}. {} ({})",
                    idx + 1,
                    failure.test_name,
                    failure.file_path
                ));
                lines.push(format!("   {}", failure.error_message));
                if let Some(stack) = &failure.stack_trace {
                    let stack_preview: String =
                        stack.lines().take(3).collect::<Vec<_>>().join("\n   ");
                    lines.push(format!("   {}", stack_preview));
                }
            }
        }

        if let Some(duration) = self.duration_ms {
            lines.push(format!("\nDuration: {}ms", duration));
        }

        lines.join("\n")
    }

    fn format_ultra(&self) -> String {
        format!(
            "✓{} ✗{} ⊘{} ({}ms)",
            self.passed,
            self.failed,
            self.skipped,
            self.duration_ms.unwrap_or(0)
        )
    }
}

impl TokenFormatter for DependencyState {
    fn format_compact(&self) -> String {
        if self.outdated_count == 0 {
            return "All packages up-to-date ✓".to_string();
        }

        let mut lines = vec![format!(
            "{} outdated packages (of {})",
            self.outdated_count, self.total_packages
        )];

        for dep in self.dependencies.iter().take(10) {
            if let Some(latest) = &dep.latest_version {
                if &dep.current_version != latest {
                    lines.push(format!(
                        "{}: {} → {}",
                        dep.name, dep.current_version, latest
                    ));
                }
            }
        }

        if self.outdated_count > 10 {
            lines.push(format!("\n... +{} more", self.outdated_count - 10));
        }

        lines.join("\n")
    }

    fn format_verbose(&self) -> String {
        let mut lines = vec![format!(
            "Total packages: {} ({} outdated)",
            self.total_packages, self.outdated_count
        )];

        if self.outdated_count > 0 {
            lines.push("\nOutdated packages:".to_string());
            for dep in &self.dependencies {
                if let Some(latest) = &dep.latest_version {
                    if &dep.current_version != latest {
                        let dev_marker = if dep.dev_dependency { " (dev)" } else { "" };
                        lines.push(format!(
                            "  {}: {} → {}{}",
                            dep.name, dep.current_version, latest, dev_marker
                        ));
                        if let Some(wanted) = &dep.wanted_version {
                            if wanted != latest {
                                lines.push(format!("    (wanted: {})", wanted));
                            }
                        }
                    }
                }
            }
        }

        lines.join("\n")
    }

    fn format_ultra(&self) -> String {
        format!("📦{} ⬆️{}", self.total_packages, self.outdated_count)
    }
}


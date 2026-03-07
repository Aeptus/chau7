import Foundation

/// Power user tips displayed on new terminal tabs instead of "Last login: ..."
/// These help users discover shortcuts and features to improve productivity.
enum PowerUserTips {

    /// A single tip with its localization key and category
    struct Tip: Identifiable {
        let id: String
        let category: Category
        let shortcut: String? // Optional shortcut to highlight

        enum Category {
            case keyboard
            case mouse
            case tabs
            case search
            case splits
            case productivity
            case appearance
        }
    }

    // MARK: - All Tips

    static let allTips: [Tip] = [
        // Keyboard shortcuts
        Tip(id: "tip.cmd_t_new_tab", category: .tabs, shortcut: "⌘T"),
        Tip(id: "tip.cmd_n_new_window", category: .tabs, shortcut: "⌘N"),
        Tip(id: "tip.cmd_w_close_tab", category: .tabs, shortcut: "⌘W"),
        Tip(id: "tip.cmd_shift_w_close_window", category: .tabs, shortcut: "⌘⇧W"),
        Tip(id: "tip.cmd_1_9_switch_tabs", category: .tabs, shortcut: "⌘1-9"),
        Tip(id: "tip.cmd_shift_brackets_cycle_tabs", category: .tabs, shortcut: "⌘⇧[ / ]"),

        // Search
        Tip(id: "tip.cmd_f_search", category: .search, shortcut: "⌘F"),
        Tip(id: "tip.cmd_g_next_match", category: .search, shortcut: "⌘G"),
        Tip(id: "tip.cmd_shift_g_prev_match", category: .search, shortcut: "⌘⇧G"),
        Tip(id: "tip.cmd_e_search_selection", category: .search, shortcut: "⌘E"),

        // Splits
        Tip(id: "tip.cmd_d_split_right", category: .splits, shortcut: "⌘D"),
        Tip(id: "tip.cmd_shift_d_split_down", category: .splits, shortcut: "⌘⇧D"),
        Tip(id: "tip.cmd_opt_arrows_navigate_panes", category: .splits, shortcut: "⌘⌥↑↓←→"),
        Tip(id: "tip.cmd_ctrl_w_close_pane", category: .splits, shortcut: "⌘⌃W"),
        Tip(id: "tip.cmd_opt_e_equalize_panes", category: .splits, shortcut: "⌘⌥E"),
        Tip(id: "tip.cmd_shift_e_maximize_pane", category: .splits, shortcut: "⌘⇧E"),

        // Edit
        Tip(id: "tip.cmd_k_clear", category: .keyboard, shortcut: "⌘K"),
        Tip(id: "tip.cmd_shift_k_clear_scrollback", category: .keyboard, shortcut: "⌘⇧K"),
        Tip(id: "tip.cmd_plus_minus_font_size", category: .appearance, shortcut: "⌘+ / ⌘-"),
        Tip(id: "tip.cmd_0_reset_font", category: .appearance, shortcut: "⌘0"),

        // Selection
        Tip(id: "tip.cmd_a_select_line", category: .keyboard, shortcut: "⌘A"),
        Tip(id: "tip.cmd_a_a_select_all", category: .keyboard, shortcut: "⌘A ⌘A"),
        Tip(id: "tip.triple_click_select_line", category: .mouse, shortcut: nil),
        Tip(id: "tip.double_click_select_word", category: .mouse, shortcut: nil),

        // Mouse features
        Tip(id: "tip.cmd_click_open_path", category: .mouse, shortcut: "⌘+Click"),
        Tip(id: "tip.opt_click_position_cursor", category: .mouse, shortcut: "⌥+Click"),
        Tip(id: "tip.copy_on_select", category: .mouse, shortcut: nil),

        // Productivity
        Tip(id: "tip.cmd_p_print", category: .productivity, shortcut: "⌘P"),
        Tip(id: "tip.cmd_shift_p_command_palette", category: .productivity, shortcut: "⌘⇧P"),
        Tip(id: "tip.cmd_semicolon_snippets", category: .productivity, shortcut: "⌘;"),
        Tip(id: "tip.cmd_shift_o_ssh", category: .productivity, shortcut: "⌘⇧O"),
        Tip(id: "tip.cmd_ctrl_f_fullscreen", category: .productivity, shortcut: "⌘⌃F"),
        Tip(id: "tip.broadcast_mode", category: .productivity, shortcut: nil),

        // Status dot
        Tip(id: "tip.status_dot_colors", category: .productivity, shortcut: nil),

        // Tab colors
        Tip(id: "tip.tab_colors", category: .tabs, shortcut: nil),
        Tip(id: "tip.rename_tab", category: .tabs, shortcut: nil)
    ]

    // MARK: - Get Random Tip

    /// Returns a random tip, optionally filtered by category
    static func randomTip(category: Tip.Category? = nil) -> Tip {
        let filtered = category == nil ? allTips : allTips.filter { $0.category == category }
        return filtered.randomElement() ?? allTips[0]
    }

    /// Returns a formatted tip string for display
    static func formattedTip(_ tip: Tip) -> String {
        let text = L(tip.id, tip.id) // Localized tip text
        if let shortcut = tip.shortcut {
            return "💡 \(text) [\(shortcut)]"
        }
        return "💡 \(text)"
    }

    /// Returns a random formatted tip ready for display
    static func randomFormattedTip() -> String {
        return formattedTip(randomTip())
    }
}

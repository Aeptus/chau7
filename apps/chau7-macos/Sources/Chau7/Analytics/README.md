# Analytics

Terminal usage analytics dashboard with command stats, timing, and API usage tracking.

## Files

| File | Purpose |
|------|---------|
| `AnalyticsDashboardView.swift` | Dashboard view showing command frequency, error rates, and AI API usage |
| `TerminalAnalytics.swift` | Aggregates analytics data from PersistentHistoryStore and the API proxy |
| `TimelineScrubberView.swift` | Horizontal timeline bar for scrubbing through recorded terminal sessions |

## Key Types

- `TerminalAnalytics` — singleton ObservableObject aggregating usage stats across sessions
- `AnalyticsDashboardView` — SwiftUI dashboard with stat cards, charts, and breakdowns
- `TimelineScrubberView` — interactive timeline with command block segments and replay controls

## Dependencies

- **Uses:** History, Proxy, Logging
- **Used by:** Settings/Views, StatusBar

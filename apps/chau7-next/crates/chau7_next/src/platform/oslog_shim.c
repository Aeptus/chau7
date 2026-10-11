// C side of platform/oslog.rs: os_log_with_type is a macro that needs the
// format string at compile time, so Rust calls these two functions instead.

#include <os/log.h>
#include <os/signpost.h>
#include <stdint.h>

void *chau7_os_log_create(const char *subsystem, const char *category) {
    return (void *)os_log_create(subsystem, category);
}

// level: 0 debug, 1 info, 2 default, 3 error.
void chau7_os_log(void *log, int level, const char *message) {
    os_log_t handle = (os_log_t)log;
    switch (level) {
    case 0:
        os_log_with_type(handle, OS_LOG_TYPE_DEBUG, "%{public}s", message);
        break;
    case 1:
        os_log_with_type(handle, OS_LOG_TYPE_INFO, "%{public}s", message);
        break;
    case 3:
        os_log_with_type(handle, OS_LOG_TYPE_ERROR, "%{public}s", message);
        break;
    default:
        os_log_with_type(handle, OS_LOG_TYPE_DEFAULT, "%{public}s", message);
        break;
    }
}

// Names must remain compile-time literals for Instruments. The numeric key
// follows the Rust Feature enum; no terminal content enters these intervals.
uint64_t chau7_signpost_begin(void *opaque, unsigned int feature) {
    os_log_t log = (os_log_t)opaque;
    if (!log || !os_signpost_enabled(log)) return 0;
    os_signpost_id_t id = os_signpost_id_generate(log);
    switch (feature) {
    case 0: os_signpost_interval_begin(log, id, "OutputProcessing"); break;
    case 1: os_signpost_interval_begin(log, id, "TerminalRender"); break;
    case 2: os_signpost_interval_begin(log, id, "HighlightDraw"); break;
    case 3: os_signpost_interval_begin(log, id, "DangerScan"); break;
    case 4: os_signpost_interval_begin(log, id, "AnsiParse"); break;
    case 5: os_signpost_interval_begin(log, id, "LocalEcho"); break;
    case 6: os_signpost_interval_begin(log, id, "Semantic"); break;
    case 7: os_signpost_interval_begin(log, id, "AIDetect"); break;
    case 8: os_signpost_interval_begin(log, id, "RemoteOutput"); break;
    case 9: os_signpost_interval_begin(log, id, "MetalRender"); break;
    case 10: os_signpost_interval_begin(log, id, "OutputMainThread"); break;
    case 11: os_signpost_interval_begin(log, id, "PromptUpdate"); break;
    case 12: os_signpost_interval_begin(log, id, "DevServerDetect"); break;
    case 13: os_signpost_interval_begin(log, id, "TerminalPoll"); break;
    case 14: os_signpost_interval_begin(log, id, "MetalDrawStage"); break;
    case 15: os_signpost_interval_begin(log, id, "TripleBufferSync"); break;
    case 16: os_signpost_interval_begin(log, id, "TripleBufferCommit"); break;
    case 17: os_signpost_interval_begin(log, id, "MetalInstanceBuffer"); break;
    case 18: os_signpost_interval_begin(log, id, "MetalGlyphLookup"); break;
    case 19: os_signpost_interval_begin(log, id, "DangerousHighlightRefresh"); break;
    case 20: os_signpost_interval_begin(log, id, "DebugRefresh"); break;
    case 21: os_signpost_interval_begin(log, id, "DebugAnalyticsRefresh"); break;
    case 22: os_signpost_interval_begin(log, id, "RestorePipeline"); break;
    case 23: os_signpost_interval_begin(log, id, "HistoryAdoption"); break;
    case 24: os_signpost_interval_begin(log, id, "RoutingRebuild"); break;
    case 25: os_signpost_interval_begin(log, id, "MainThreadStall"); break;
    default: return 0;
    }
    return (uint64_t)id;
}
void chau7_signpost_end(void *opaque, unsigned int feature, uint64_t token) {
    os_log_t log = (os_log_t)opaque;
    if (!log || !token) return;
    os_signpost_id_t id = (os_signpost_id_t)token;
    switch (feature) {
    case 0: os_signpost_interval_end(log, id, "OutputProcessing"); break;
    case 1: os_signpost_interval_end(log, id, "TerminalRender"); break;
    case 2: os_signpost_interval_end(log, id, "HighlightDraw"); break;
    case 3: os_signpost_interval_end(log, id, "DangerScan"); break;
    case 4: os_signpost_interval_end(log, id, "AnsiParse"); break;
    case 5: os_signpost_interval_end(log, id, "LocalEcho"); break;
    case 6: os_signpost_interval_end(log, id, "Semantic"); break;
    case 7: os_signpost_interval_end(log, id, "AIDetect"); break;
    case 8: os_signpost_interval_end(log, id, "RemoteOutput"); break;
    case 9: os_signpost_interval_end(log, id, "MetalRender"); break;
    case 10: os_signpost_interval_end(log, id, "OutputMainThread"); break;
    case 11: os_signpost_interval_end(log, id, "PromptUpdate"); break;
    case 12: os_signpost_interval_end(log, id, "DevServerDetect"); break;
    case 13: os_signpost_interval_end(log, id, "TerminalPoll"); break;
    case 14: os_signpost_interval_end(log, id, "MetalDrawStage"); break;
    case 15: os_signpost_interval_end(log, id, "TripleBufferSync"); break;
    case 16: os_signpost_interval_end(log, id, "TripleBufferCommit"); break;
    case 17: os_signpost_interval_end(log, id, "MetalInstanceBuffer"); break;
    case 18: os_signpost_interval_end(log, id, "MetalGlyphLookup"); break;
    case 19: os_signpost_interval_end(log, id, "DangerousHighlightRefresh"); break;
    case 20: os_signpost_interval_end(log, id, "DebugRefresh"); break;
    case 21: os_signpost_interval_end(log, id, "DebugAnalyticsRefresh"); break;
    case 22: os_signpost_interval_end(log, id, "RestorePipeline"); break;
    case 23: os_signpost_interval_end(log, id, "HistoryAdoption"); break;
    case 24: os_signpost_interval_end(log, id, "RoutingRebuild"); break;
    case 25: os_signpost_interval_end(log, id, "MainThreadStall"); break;
    default: break;
    }
}

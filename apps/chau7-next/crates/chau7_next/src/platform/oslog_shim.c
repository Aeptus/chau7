// C side of platform/oslog.rs: os_log_with_type is a macro that needs the
// format string at compile time, so Rust calls these two functions instead.

#include <os/log.h>

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

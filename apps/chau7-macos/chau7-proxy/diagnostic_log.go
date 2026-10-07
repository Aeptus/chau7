package main

import (
	"fmt"
	"log"
	"strconv"
)

// diagnosticLogLine preserves the message layout while escaping control bytes,
// invalid UTF-8, and Unicode line separators from request/provider/error data.
func diagnosticLogLine(message string) string {
	quoted := strconv.Quote(message)
	return quoted[1 : len(quoted)-1]
}

func diagnosticLogf(format string, args ...any) {
	// #nosec G706 -- the complete rendered message is escaped before logging; regressions cover line/control injection
	log.Print(diagnosticLogLine(fmt.Sprintf(format, args...)))
}

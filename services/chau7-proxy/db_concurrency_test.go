package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestIsBusyError(t *testing.T) {
	cases := []struct {
		name  string
		err   error
		build bool
	}{
		{"nil", nil, false},
		{"sqlite busy code", errors.New("SQLITE_BUSY (5)"), true},
		{"locked text", errors.New("database is locked (5) (SQLITE_BUSY)"), true},
		{"table locked", errors.New("database table is locked"), true},
		{"constraint violation", errors.New("UNIQUE constraint failed: api_calls.id"), false},
		{"disk full", errors.New("database or disk is full"), false},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := isBusyError(testCase.err); got != testCase.build {
				t.Errorf("isBusyError(%v) = %v, want %v", testCase.err, got, testCase.build)
			}
		})
	}
}

// TestRetryOnBusyRecoversTransientLock is the behaviour that matters: a write
// that loses the lock once must still land, because the previous code logged
// the error and dropped the API call.
func TestRetryOnBusyRecoversTransientLock(t *testing.T) {
	attempts := 0
	err := retryOnBusy(func() error {
		attempts++
		if attempts < 3 {
			return errors.New("database is locked (5) (SQLITE_BUSY)")
		}
		return nil
	})
	if err != nil {
		t.Fatalf("retryOnBusy returned %v, want nil", err)
	}
	if attempts != 3 {
		t.Errorf("made %d attempts, want 3", attempts)
	}
}

// TestRetryOnBusyGivesUpAndReportsTheError bounds the retry so a permanently
// locked database surfaces rather than blocking forever.
func TestRetryOnBusyGivesUpAndReportsTheError(t *testing.T) {
	attempts := 0
	busy := errors.New("database is locked (5) (SQLITE_BUSY)")

	err := retryOnBusy(func() error {
		attempts++
		return busy
	})

	if !errors.Is(err, busy) {
		t.Fatalf("retryOnBusy returned %v, want the busy error", err)
	}
	if want := sqliteBusyRetries + 1; attempts != want {
		t.Errorf("made %d attempts, want %d", attempts, want)
	}
}

// TestRetryOnBusyDoesNotRetryOtherErrors keeps a genuine failure fast: retrying
// a constraint violation only delays the caller.
func TestRetryOnBusyDoesNotRetryOtherErrors(t *testing.T) {
	attempts := 0
	fatal := errors.New("UNIQUE constraint failed")

	err := retryOnBusy(func() error {
		attempts++
		return fatal
	})

	if !errors.Is(err, fatal) {
		t.Fatalf("retryOnBusy returned %v, want the original error", err)
	}
	if attempts != 1 {
		t.Errorf("made %d attempts, want 1", attempts)
	}
}

// TestConcurrentAPICallInsertsAllPersist covers the real mixed traffic: many
// handlers inserting while stats reads run. Note this passes with or without
// the retry on an uncontended test database -- it guards the insert path, and
// the retry semantics are pinned by the unit tests above.
func TestConcurrentAPICallInsertsAllPersist(t *testing.T) {
	db, err := NewDatabase(filepath.Join(t.TempDir(), "analytics.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer func() { _ = db.Close() }()

	const writers = 16
	const perWriter = 8

	var wg sync.WaitGroup
	errCh := make(chan error, writers*perWriter)

	for w := range writers {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := range perWriter {
				record := &APICallRecord{
					Provider:     "anthropic",
					Model:        "claude-opus-5",
					Endpoint:     "/v1/messages",
					InputTokens:  IntPointer(10),
					OutputTokens: IntPointer(20),
					Timestamp:    time.Now(),
				}
				if _, err := db.InsertAPICallWithTask(
					record,
					fmt.Sprintf("task-%d", worker),
					fmt.Sprintf("tab-%d", worker),
					"/tmp/project",
				); err != nil {
					errCh <- fmt.Errorf("worker %d insert %d: %w", worker, i, err)
					return
				}
			}
		}(w)
	}

	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 8 {
				if _, err := db.GetDailyStats(); err != nil {
					errCh <- fmt.Errorf("reader: %w", err)
					return
				}
			}
		}()
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		t.Fatalf("mixed read/write traffic failed: %v", err)
	}

	var count int
	if err := db.db.QueryRow("SELECT COUNT(*) FROM api_calls").Scan(&count); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if want := writers * perWriter; count != want {
		t.Errorf("persisted %d rows, want %d -- API calls were dropped", count, want)
	}
}

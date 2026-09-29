// Package vmsession is an in-memory relay for VM-provisioning progress,
// ported from p3dx-aaa/src/services/vmProvisioning.service.js. Backs both
// the auto-provision SSE stream and the legacy deploy.sh-driven flow (a
// participant's own local `terraform/participant-vm/deploy.sh` run, reporting
// status back over POST /events with a token instead of a JWT).
package vmsession

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

const tokenTTL = 2 * time.Hour // comfortably covers init+plan+apply

// Event is one reported provisioning step.
type Event struct {
	Step    string `json:"step"`
	Command string `json:"command,omitempty"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
	At      string `json:"at"`
}

// Session tracks one provisioning run.
type Session struct {
	Username  string
	Role      string
	Status    string
	VMReady   bool
	Events    []Event
	CreatedAt time.Time
}

// Store is a thread-safe token -> Session map.
type Store struct {
	mu       sync.Mutex
	sessions map[string]*Session
}

func NewStore() *Store {
	return &Store{sessions: make(map[string]*Session)}
}

func (s *Store) dropExpiredLocked() {
	cutoff := time.Now().Add(-tokenTTL)
	for token, session := range s.sessions {
		if session.CreatedAt.Before(cutoff) {
			delete(s.sessions, token)
		}
	}
}

// CreateToken mints a token identifying which logged-in user a later
// provisioning run (or deploy.sh invocation) belongs to.
func (s *Store) CreateToken(username, role string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropExpiredLocked()

	buf := make([]byte, 24)
	_, _ = rand.Read(buf)
	token := hex.EncodeToString(buf)

	s.sessions[token] = &Session{
		Username:  username,
		Role:      role,
		Status:    "idle",
		VMReady:   false,
		Events:    []Event{},
		CreatedAt: time.Now(),
	}
	return token
}

// AppendEvent records one provisioning step. VMReady latches true the first
// time a run reaches "done" or "error" and never reverts, mirroring the Node
// version — flauto keeps appending further events (waiting for clients,
// starting the FL session) onto this same token afterward, and Status alone
// would flip back to "running" for those, hiding the SSH-key download button
// again; VMReady is what the panel keys that button's visibility on instead.
// Returns false if the token is unknown (e.g. expired).
func (s *Store) AppendEvent(token, step, command, status, message string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, ok := s.sessions[token]
	if !ok {
		return false
	}
	session.Events = append(session.Events, Event{
		Step: step, Command: command, Status: status, Message: message,
		At: time.Now().UTC().Format("2006-01-02T15:04:05.000Z07:00"),
	})
	switch status {
	case "error":
		session.Status = "error"
	case "done":
		session.Status = "done"
	default:
		session.Status = "running"
	}
	if status == "done" || status == "error" {
		session.VMReady = true
	}
	return true
}

// Snapshot is a read-only copy of a session's current state, safe to hold
// after the lock is released.
type Snapshot struct {
	Status  string
	VMReady bool
	Events  []Event
}

// Get returns a snapshot of one specific run's session, identified by token.
func (s *Store) Get(token string) (Snapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, ok := s.sessions[token]
	if !ok {
		return Snapshot{}, false
	}
	return snapshotLocked(session), true
}

// GetLatestForUser returns the most recent session for a username+role, if
// any — kept for the manual deploy.sh flow, which never has a run token.
func (s *Store) GetLatestForUser(username, role string) (Snapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var latest *Session
	for _, session := range s.sessions {
		if session.Username == username && session.Role == role {
			if latest == nil || session.CreatedAt.After(latest.CreatedAt) {
				latest = session
			}
		}
	}
	if latest == nil {
		return Snapshot{}, false
	}
	return snapshotLocked(latest), true
}

func snapshotLocked(s *Session) Snapshot {
	events := make([]Event, len(s.Events))
	copy(events, s.Events)
	return Snapshot{Status: s.Status, VMReady: s.VMReady, Events: events}
}

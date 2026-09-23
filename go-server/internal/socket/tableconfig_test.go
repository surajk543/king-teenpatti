package socket

import (
	"encoding/json"
	"sort"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// sessionConfig connects a fresh player to st and returns session:ready.config.
func sessionConfig(t *testing.T, st *stack, name string) json.RawMessage {
	t.Helper()
	_, tok := st.login(name)
	c := st.dial(tok)
	ready, err := c.Wait(EvSessionReady, nil, eventTimeout)
	if err != nil {
		t.Fatalf("no session:ready: %v", err)
	}
	var body struct {
		Config json.RawMessage `json:"config"`
	}
	if err := json.Unmarshal(ready, &body); err != nil {
		t.Fatal(err)
	}
	return body.Config
}

// TestSessionReadyNamesTheTableCatalogue: session:ready.config gains exactly
// one key, tableConfigVersion — the version of the catalogue the RoomManager
// enforces, the one GET /api/tables serves under the same string — so a client
// holding that catalogue keeps it and one holding another fetches it again.
// Every other key is what it was, and a server with another menu names
// another version.
func TestSessionReadyNamesTheTableCatalogue(t *testing.T) {
	st := newStack(t, nil)
	cfg := sessionConfig(t, st, "Version")
	got := str(cfg, "tableConfigVersion")
	if len(got) != 64 || got != st.rooms.TableConfigVersion() || got != st.rooms.TableConfig().Version {
		t.Fatalf("tableConfigVersion %q, the manager's %q", got, st.rooms.TableConfigVersion())
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(cfg, &m); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"bootAmount", "categories", "entryCapBoot", "entryCapCategory", "entryCapMaxChips", "maxBetRounds",
		"maxPlayers", "minClientBuild", "minPlayers", "privateBoot", "privateMaxPot", "sideshowMinPlayers", "sideshowTimeoutMs",
		"stakes", "tableConfigVersion", "tables", "turnTimeoutMs", "welcomeChips"}
	if strings.Join(keys, ",") != strings.Join(want, ",") {
		t.Fatalf("session:ready.config keys\n got %v\nwant %v", keys, want)
	}
	// The same version on every session of this server.
	if again := str(sessionConfig(t, st, "Again"), "tableConfigVersion"); again != got {
		t.Fatalf("a second session was told %q, the first %q", again, got)
	}

	other := newStack(t, func(c *config.Config) {
		c.Game.LobbyTables = []config.LobbyTable{{Category: "seen", BootAmount: 200}}
	})
	if v := str(sessionConfig(t, other, "Other"), "tableConfigVersion"); v == got || v != other.rooms.TableConfigVersion() {
		t.Fatalf("another menu was named %q (this one %q)", v, got)
	}
}

package auth

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// nodeModules is the Node server's dependency tree (jsonwebtoken lives there).
var nodeModules = filepath.Join("..", "..", "..", "server", "node_modules")

// runNode evaluates a script with Node 22 against the Node server's
// node_modules and returns stdout. Skips the test when Node or the modules
// are unavailable so the package still tests on a bare machine.
func runNode(t *testing.T, script string, env ...string) string {
	t.Helper()
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node is not installed")
	}
	if _, err := os.Stat(filepath.Join(nodeModules, "jsonwebtoken")); err != nil {
		t.Skipf("no server/node_modules: %v", err)
	}
	cmd := exec.Command("node", "-e", script)
	cmd.Env = append(os.Environ(), "NODE_PATH="+nodeModules)
	cmd.Env = append(cmd.Env, env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("node failed: %v\n%s", err, out)
	}
	return strings.TrimSpace(string(out))
}

// nodeJSON runs a script that prints one JSON value and decodes it.
func nodeJSON(t *testing.T, script string, v any, env ...string) {
	t.Helper()
	out := runNode(t, script, env...)
	if err := json.Unmarshal([]byte(out), v); err != nil {
		t.Fatalf("node output %q is not JSON: %v", out, err)
	}
}

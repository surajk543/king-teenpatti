package game

// Parity checks against the Node reference implementation. They run the real
// server/src/game/*.js under `node` and compare every hand ranking and every
// single-code-point sanitising result with the Go port. They skip when node
// or the Node tree is not present (CI without the reference checkout).

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"unicode/utf8"
)

// nodeServerDir locates the Node reference server (the original
// implementation these differential tests compare against). It was removed
// from the repository once the port had matched it; to re-run the
// comparison, check it out from history (`git show <commit>:server/…` or a
// worktree of a pre-removal commit) and point NODE_REFERENCE_DIR at that
// server/ directory with its node_modules installed. Without it the
// differential tests skip.
func nodeServerDir(t *testing.T) string {
	t.Helper()
	dir := os.Getenv("NODE_REFERENCE_DIR")
	if dir == "" {
		var err error
		if dir, err = filepath.Abs(filepath.Join("..", "..", "..", "server")); err != nil {
			t.Skip("cannot resolve the Node server dir")
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "src", "game", "handRank.js")); err != nil {
		t.Skip("Node reference tree not present (set NODE_REFERENCE_DIR to a checkout of the removed server/ tree)")
	}
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not installed")
	}
	return dir
}

func runNode(t *testing.T, dir, script string, into any) {
	t.Helper()
	cmd := exec.Command("node", "--input-type=module", "-e", script)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("node failed: %v\n%s", err, stderr.String())
	}
	if err := json.Unmarshal(stdout.Bytes(), into); err != nil {
		t.Fatalf("bad JSON from node: %v", err)
	}
}

func TestInteropEvaluateMatchesNodeForEveryHand(t *testing.T) {
	dir := nodeServerDir(t)
	const script = `
import { evaluate } from './src/game/handRank.js';
import { newDeck, cardCode } from './src/game/deck.js';
const deck = newDeck();
const out = [];
for (let i = 0; i < 52; i++) for (let j = i + 1; j < 52; j++) for (let k = j + 1; k < 52; k++) {
  const cards = [deck[i], deck[j], deck[k]];
  const e = evaluate(cards);
  const v = evaluate(cards, { aceLowIsLowest: true });
  out.push({ codes: cards.map(cardCode), name: e.name, score: e.score, variant: v.score });
}
process.stdout.write(JSON.stringify(out));`
	var rows []struct {
		Codes   []string `json:"codes"`
		Name    string   `json:"name"`
		Score   []int    `json:"score"`
		Variant []int    `json:"variant"`
	}
	runNode(t, dir, script, &rows)
	if len(rows) != 22100 {
		t.Fatalf("node produced %d hands, want 22100", len(rows))
	}
	mismatch := 0
	for _, r := range rows {
		e := Evaluate(ParseCards(r.Codes), EvaluateOptions{})
		v := Evaluate(ParseCards(r.Codes), EvaluateOptions{AceLowIsLowest: true})
		if e.Name != r.Name || !equalInts(e.Score, r.Score) || !equalInts(v.Score, r.Variant) {
			mismatch++
			if mismatch <= 20 {
				t.Errorf("%v: Node %s %v/%v, Go %s %v/%v", r.Codes, r.Name, r.Score, r.Variant, e.Name, e.Score, v.Score)
			}
		}
	}
	if mismatch > 0 {
		t.Fatalf("%d of %d hands differ from Node", mismatch, len(rows))
	}
}

func TestInteropSanitizeMatchesNodeForEveryCodePoint(t *testing.T) {
	dir := nodeServerDir(t)
	// Every code point of planes 0-2 embedded between letters, plus the
	// shapes the unit tests use. Lone surrogates cannot reach Go as such
	// (encoding/json turns them into U+FFFD) and are skipped.
	const script = `
import { RoomChat } from './src/game/chat.js';
const out = [];
for (let cp = 1; cp < 0x30000; cp++) {
  if (cp >= 0xd800 && cp <= 0xdfff) continue;
  const s = 'a' + String.fromCodePoint(cp) + 'b';
  out.push([s, RoomChat.sanitize(s, 140)]);
}
const extra = ['hi [31m there', 'one\ntwo\r\nthree', '  spaced   out  ', 'x'.repeat(200),
  '\u{1F0CF}'.repeat(80), 'ab\u{1F0CF}', 'a\u200D\u200Db', 'one  two', ' \u3000hello\uFEFF',
  'नमस्ते 123 !?'];
for (const s of extra) out.push([s, RoomChat.sanitize(s, 140)]);
process.stdout.write(JSON.stringify(out));`
	var cases [][2]string
	runNode(t, dir, script, &cases)
	mismatch := 0
	for _, c := range cases {
		if got := SanitizeChat(c[0], 140); got != c[1] {
			mismatch++
			if mismatch <= 40 {
				r, _ := utf8.DecodeRuneInString(c[0][1:])
				t.Errorf("U+%04X (%q): Node %q, Go %q", r, c[0], c[1], got)
			}
		}
	}
	if mismatch > 0 {
		t.Fatalf("%d of %d inputs differ from Node", mismatch, len(cases))
	}
	t.Logf("%d inputs identical to Node", len(cases))
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

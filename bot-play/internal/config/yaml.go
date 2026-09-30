package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"slices"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// The YAML file is read by walking its node tree against an explicit schema
// rather than by yaml.Unmarshal into tagged structs, so that every refusal
// can name the dotted key and its line ("session.min_duration (line 7): …"),
// which struct decoding cannot: it reports an unknown field by the Go type
// it was decoding into.
//
// The rules, all strict:
//
//   - every key must be one the schema knows, and appear once;
//   - a value must have the right YAML type: a whole number where a count
//     is read (3.5 and "3" are both refused), true/false where a switch is
//     read (yes/no are text in YAML 1.2 and are refused), text where a word
//     is read;
//   - a duration is either a Go duration string ("20m", "1.5s", "700ms"; a
//     bare 0 is also accepted) under the plain key, or a whole number under
//     the key that names its unit (min_duration_minutes: 20) — the two
//     spellings of one setting may not both be given;
//   - an empty value (`ws_url:`) is empty text, an empty list or an empty
//     mapping where one of those is read, and an error anywhere else;
//   - the file holds one YAML document.
//
// Names inside the free-form mappings (personality_mix, ranges,
// probabilities, tuning, category_weights) are normalised here — personality
// families to upper case, everything else to lower case — and checked
// against their vocabularies in Validate.

// handler reads one value into the configuration.
type handler func(n *yaml.Node, path string) error

// field is one key of a section: a value (handle) or a nested section (sub).
type field struct {
	handle handler
	sub    section
}

// section is a mapping's known keys.
type section map[string]field

func leaf(h handler) field  { return field{handle: h} }
func group(s section) field { return field{sub: s} }

// decoder carries what the walk has seen, for the checks that span keys.
type decoder struct {
	c    *Config
	seen map[string]int // dotted path → line, of every key given
	alts [][2]string    // pairs of dotted paths that spell the same setting
}

// decodeYAML lays the file's settings over c.
func decodeYAML(c *Config, data []byte) error {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil {
		if errors.Is(err, io.EOF) {
			return nil // an empty file (or only comments): nothing to lay over the defaults
		}
		return err
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err != nil {
			return err
		}
		return fmt.Errorf("line %d: a second YAML document; the file holds exactly one", extra.Line)
	}
	root := &doc
	if root.Kind == yaml.DocumentNode {
		if len(root.Content) == 0 {
			return nil
		}
		root = root.Content[0]
	}
	d := newDecoder(c)
	if err := d.mapping(root, "", d.schema()); err != nil {
		return err
	}
	return d.checkAlternates()
}

func newDecoder(c *Config) *decoder {
	return &decoder{c: c, seen: map[string]int{}}
}

// either registers two spellings of one setting in s.
func (d *decoder) either(s section, prefix, a string, ha handler, b string, hb handler) {
	s[a] = leaf(ha)
	s[b] = leaf(hb)
	d.alts = append(d.alts, [2]string{join(prefix, a), join(prefix, b)})
}

// schema is every key the file may hold, bound to c's fields.
func (d *decoder) schema() section {
	c := d.c

	bots := section{
		"count":           leaf(whole(&c.Bots.Count)),
		"device_prefix":   leaf(text(&c.Bots.DevicePrefix)),
		"start_index":     leaf(whole(&c.Bots.StartIndex)),
		"personality_mix": leaf(weights(&c.Bots.PersonalityMix, strings.ToUpper)),
	}
	d.either(bots, "bots",
		"start_stagger", durationPair(&c.Bots.StartStagger),
		"start_stagger_ms", unitPair(&c.Bots.StartStagger, time.Millisecond, "milliseconds"))

	session := section{}
	d.either(session, "session",
		"min_duration", goDuration(&c.Session.MinDuration),
		"min_duration_minutes", unitCount(&c.Session.MinDuration, time.Minute, "minutes"))
	d.either(session, "session",
		"max_duration", goDuration(&c.Session.MaxDuration),
		"max_duration_minutes", unitCount(&c.Session.MaxDuration, time.Minute, "minutes"))
	d.either(session, "session",
		"rest_min", goDuration(&c.Session.RestMin),
		"rest_min_minutes", unitCount(&c.Session.RestMin, time.Minute, "minutes"))
	d.either(session, "session",
		"rest_max", goDuration(&c.Session.RestMax),
		"rest_max_minutes", unitCount(&c.Session.RestMax, time.Minute, "minutes"))

	table := section{
		"min_hands":          leaf(whole(&c.Table.MinHands)),
		"max_hands":          leaf(whole(&c.Table.MaxHands)),
		"categories":         leaf(textList(&c.Table.Categories)),
		"category_weights":   leaf(weights(&c.Table.CategoryWeights, strings.ToLower)),
		"boots_to_sit":       leaf(number(&c.Table.BootsToSit)),
		"max_bots_per_table": leaf(whole(&c.Table.MaxBotsPerTable)),
		"lobby_tables":       leaf(lobbyTables(&c.Table.LobbyTables, &c.Table.FleetByTable)),
		"fleet_per_table":    leaf(wholePair(&c.Table.FleetPerTable)),
	}
	d.either(table, "table",
		"search_delay", durationPair(&c.Table.SearchDelay),
		"search_delay_ms", unitPair(&c.Table.SearchDelay, time.Millisecond, "milliseconds"))
	d.either(table, "table",
		"no_human_patience", goDuration(&c.Table.NoHumanPatience),
		"no_human_patience_seconds", unitCount(&c.Table.NoHumanPatience, time.Second, "seconds"))

	timing := section{
		"ranges": leaf(msRanges(&c.Timing.Ranges)),
	}
	d.either(timing, "timing",
		"min_reaction", goDuration(&c.Timing.MinReaction),
		"min_reaction_ms", unitCount(&c.Timing.MinReaction, time.Millisecond, "milliseconds"))
	d.either(timing, "timing",
		"max_reaction", goDuration(&c.Timing.MaxReaction),
		"max_reaction_ms", unitCount(&c.Timing.MaxReaction, time.Millisecond, "milliseconds"))
	d.either(timing, "timing",
		"safety_margin", goDuration(&c.Timing.SafetyMargin),
		"safety_margin_ms", unitCount(&c.Timing.SafetyMargin, time.Millisecond, "milliseconds"))

	strategy := section{
		"enable_blind": leaf(flag(&c.Strategy.EnableBlind)),
		"enable_seen":  leaf(flag(&c.Strategy.EnableSeen)),
		"tuning":       leaf(tuning(&c.Strategy.Tuning)),
	}

	interaction := section{
		"enable_chat":   leaf(flag(&c.Interaction.EnableChat)),
		"enable_emotes": leaf(flag(&c.Interaction.EnableEmotes)),
		"probabilities": leaf(probabilities(&c.Interaction.Probabilities)),
		"table_per_min": leaf(whole(&c.Interaction.TablePerMin)),
		"language":      leaf(text(&c.Interaction.Language)),
	}
	d.either(interaction, "interaction",
		"cooldown", goDuration(&c.Interaction.Cooldown),
		"cooldown_seconds", unitCount(&c.Interaction.Cooldown, time.Second, "seconds"))
	d.either(interaction, "interaction",
		"table_gap", goDuration(&c.Interaction.TableGap),
		"table_gap_seconds", unitCount(&c.Interaction.TableGap, time.Second, "seconds"))

	reconnect := section{
		"max_attempts": leaf(whole(&c.Reconnect.MaxAttempts)),
	}
	d.either(reconnect, "reconnect",
		"base_delay", goDuration(&c.Reconnect.BaseDelay),
		"base_delay_ms", unitCount(&c.Reconnect.BaseDelay, time.Millisecond, "milliseconds"))
	d.either(reconnect, "reconnect",
		"max_delay", goDuration(&c.Reconnect.MaxDelay),
		"max_delay_seconds", unitCount(&c.Reconnect.MaxDelay, time.Second, "seconds"))

	return section{
		"mode":        leaf(text(&c.Mode)),
		"server_url":  leaf(text(&c.ServerURL)),
		"ws_url":      leaf(text(&c.WSURL)),
		"seed":        leaf(unsigned(&c.Seed)),
		"bots":        group(bots),
		"session":     group(session),
		"table":       group(table),
		"timing":      group(timing),
		"strategy":    group(strategy),
		"interaction": group(interaction),
		"reconnect":   group(reconnect),
		"bankroll": group(section{
			"dev_replenish": leaf(flag(&c.Bankroll.DevReplenish)),
		}),
		"debug": group(section{
			"addr":       leaf(text(&c.Debug.Addr)),
			"show_cards": leaf(flag(&c.Debug.ShowCards)),
		}),
		"metrics": group(section{
			"addr": leaf(text(&c.Metrics.Addr)),
		}),
		"log": group(section{
			"level":  leaf(text(&c.Log.Level)),
			"format": leaf(text(&c.Log.Format)),
		}),
	}
}

// mapping reads a mapping node against s. An empty value (`bots:` with
// nothing under it) leaves every key of the section at what it was.
func (d *decoder) mapping(n *yaml.Node, path string, s section) error {
	n = deref(n)
	if isNull(n) {
		return nil
	}
	if n.Kind != yaml.MappingNode {
		where := path
		if where == "" {
			where = "the file"
		}
		return errAt(where, n, "must be a mapping of keys, not %s", describe(n))
	}
	given := map[string]bool{}
	for i := 0; i+1 < len(n.Content); i += 2 {
		k, v := n.Content[i], n.Content[i+1]
		p := join(path, k.Value)
		if k.Kind != yaml.ScalarNode || k.ShortTag() != "!!str" {
			return errAt(join(path, "?"), k, "a key must be a name, not %s", describe(k))
		}
		if given[k.Value] {
			return errAt(p, k, "is given twice")
		}
		given[k.Value] = true
		f, ok := s[k.Value]
		if !ok {
			return errAt(p, k, "unknown key (%s takes: %s)", orTop(path), strings.Join(keysOf(s), ", "))
		}
		d.seen[p] = k.Line
		var err error
		if f.sub != nil {
			err = d.mapping(v, p, f.sub)
		} else {
			err = f.handle(v, p)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// checkAlternates refuses a setting given under both of its spellings.
func (d *decoder) checkAlternates() error {
	for _, pair := range d.alts {
		la, a := d.seen[pair[0]]
		lb, b := d.seen[pair[1]]
		if a && b {
			return fmt.Errorf("%s (line %d) and %s (line %d) are the same setting: give one of them",
				pair[0], la, pair[1], lb)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Values.

// text reads a word or a URL. An empty value is "".
func text(dst *string) handler {
	return func(n *yaml.Node, path string) error {
		n = deref(n)
		if isNull(n) {
			*dst = ""
			return nil
		}
		if n.Kind != yaml.ScalarNode || n.ShortTag() != "!!str" {
			return errAt(path, n, "must be text, not %s", describe(n))
		}
		*dst = n.Value
		return nil
	}
}

// whole reads a count: a YAML integer, nothing else.
func whole(dst *int) handler {
	return func(n *yaml.Node, path string) error {
		v, err := wholeValue(n, path)
		if err != nil {
			return err
		}
		*dst = v
		return nil
	}
}

func wholeValue(n *yaml.Node, path string) (int, error) {
	n = deref(n)
	if n.Kind != yaml.ScalarNode || n.ShortTag() != "!!int" {
		return 0, errAt(path, n, "must be a whole number, not %s", describe(n))
	}
	var v int
	if err := n.Decode(&v); err != nil {
		return 0, errAt(path, n, "%q is out of range", n.Value)
	}
	return v, nil
}

// unsigned reads the seed: a whole number from 0 up.
func unsigned(dst *uint64) handler {
	return func(n *yaml.Node, path string) error {
		n = deref(n)
		if n.Kind != yaml.ScalarNode || n.ShortTag() != "!!int" {
			return errAt(path, n, "must be a whole number, not %s", describe(n))
		}
		var v uint64
		if err := n.Decode(&v); err != nil {
			return errAt(path, n, "%q must be a whole number from 0 to %d", n.Value, uint64(math.MaxUint64))
		}
		*dst = v
		return nil
	}
}

// number reads a quantity that may have a fraction; it must be finite.
func number(dst *float64) handler {
	return func(n *yaml.Node, path string) error {
		v, err := numberValue(n, path)
		if err != nil {
			return err
		}
		*dst = v
		return nil
	}
}

func numberValue(n *yaml.Node, path string) (float64, error) {
	n = deref(n)
	if n.Kind != yaml.ScalarNode || (n.ShortTag() != "!!int" && n.ShortTag() != "!!float") {
		return 0, errAt(path, n, "must be a number, not %s", describe(n))
	}
	var v float64
	if err := n.Decode(&v); err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, errAt(path, n, "%q must be a finite number", n.Value)
	}
	return v, nil
}

// flag reads a switch: true or false, nothing else.
func flag(dst *bool) handler {
	return func(n *yaml.Node, path string) error {
		n = deref(n)
		if n.Kind != yaml.ScalarNode || n.ShortTag() != "!!bool" {
			return errAt(path, n, "must be true or false, not %s", describe(n))
		}
		var v bool
		if err := n.Decode(&v); err != nil {
			return errAt(path, n, "must be true or false")
		}
		*dst = v
		return nil
	}
}

// goDuration reads a Go duration string ("20m", "1.5s", "700ms"); a bare 0
// is zero. A bare number with no unit is refused: it would be read as
// nanoseconds.
func goDuration(dst *time.Duration) handler {
	return func(n *yaml.Node, path string) error {
		v, err := goDurationValue(n, path)
		if err != nil {
			return err
		}
		*dst = v
		return nil
	}
}

func goDurationValue(n *yaml.Node, path string) (time.Duration, error) {
	n = deref(n)
	if n.Kind != yaml.ScalarNode {
		return 0, errAt(path, n, "must be a duration such as \"20m\", not %s", describe(n))
	}
	switch n.ShortTag() {
	case "!!str":
		v, err := time.ParseDuration(strings.TrimSpace(n.Value))
		if err != nil {
			return 0, errAt(path, n, "%q is not a duration (write it with a unit: \"20m\", \"1.5s\", \"700ms\")", n.Value)
		}
		return v, nil
	case "!!int", "!!float":
		if v, err := numberValue(n, path); err == nil && v == 0 {
			return 0, nil
		}
		return 0, errAt(path, n, "%s has no unit (write \"%ss\", \"%sm\" …, or use the key that names its unit)",
			n.Value, n.Value, n.Value)
	}
	return 0, errAt(path, n, "must be a duration such as \"20m\", not %s", describe(n))
}

// unitCount reads a whole number of unit ("min_duration_minutes: 20").
func unitCount(dst *time.Duration, unit time.Duration, unitName string) handler {
	return func(n *yaml.Node, path string) error {
		v, err := unitCountValue(n, path, unit, unitName)
		if err != nil {
			return err
		}
		*dst = v
		return nil
	}
}

func unitCountValue(n *yaml.Node, path string, unit time.Duration, unitName string) (time.Duration, error) {
	n = deref(n)
	if n.Kind != yaml.ScalarNode || n.ShortTag() != "!!int" {
		return 0, errAt(path, n, "must be a whole number of %s, not %s", unitName, describe(n))
	}
	var v int64
	if err := n.Decode(&v); err != nil || v < 0 || v > math.MaxInt64/int64(unit) {
		return 0, errAt(path, n, "%q must be a whole number of %s from 0 to %d", n.Value, unitName, math.MaxInt64/int64(unit))
	}
	return time.Duration(v) * unit, nil
}

// durationPair reads [lo, hi] as two Go duration strings.
func durationPair(dst *[2]time.Duration) handler {
	return func(n *yaml.Node, path string) error {
		items, err := pairOf(n, path)
		if err != nil {
			return err
		}
		var out [2]time.Duration
		for i, item := range items {
			if out[i], err = goDurationValue(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
		*dst = out
		return nil
	}
}

// unitPair reads [lo, hi] as two whole numbers of unit.
func unitPair(dst *[2]time.Duration, unit time.Duration, unitName string) handler {
	return func(n *yaml.Node, path string) error {
		items, err := pairOf(n, path)
		if err != nil {
			return err
		}
		var out [2]time.Duration
		for i, item := range items {
			if out[i], err = unitCountValue(item, fmt.Sprintf("%s[%d]", path, i), unit, unitName); err != nil {
				return err
			}
		}
		*dst = out
		return nil
	}
}

// pairOf is a list of exactly two items.
func pairOf(n *yaml.Node, path string) ([]*yaml.Node, error) {
	n = deref(n)
	if n.Kind != yaml.SequenceNode || len(n.Content) != 2 {
		return nil, errAt(path, n, "must be a list of two values [low, high], not %s", describe(n))
	}
	return n.Content, nil
}

// wholePair reads a list of two whole numbers, [low, high].
func wholePair(dst *[2]int) handler {
	return func(n *yaml.Node, path string) error {
		items, err := pairOf(n, path)
		if err != nil {
			return err
		}
		var v [2]int
		for i, item := range items {
			if v[i], err = wholeValue(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
		*dst = v
		return nil
	}
}

// textList reads a list of words. An empty value is an empty list.
func textList(dst *[]string) handler {
	return func(n *yaml.Node, path string) error {
		n = deref(n)
		if isNull(n) {
			*dst = []string{}
			return nil
		}
		if n.Kind != yaml.SequenceNode {
			return errAt(path, n, "must be a list, not %s", describe(n))
		}
		out := make([]string, 0, len(n.Content))
		for i, item := range n.Content {
			var s string
			if err := text(&s)(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
			out = append(out, s)
		}
		*dst = out
		return nil
	}
}

// lobbyTables reads table.lobby_tables: a list of entries, each a key with
// an optional fleet= option (ParseLobbyTable) — the keys into *keys, each
// entry's own fleet size into *fleet. A bad option is refused at its line.
func lobbyTables(keys *[]string, fleet *map[string][2]int) handler {
	return func(n *yaml.Node, path string) error {
		var entries []string
		if err := textList(&entries)(n, path); err != nil {
			return err
		}
		n = deref(n)
		k, f, err := readLobbyTables(entries, func(i int, err error) error {
			return errAt(fmt.Sprintf("%s[%d]", path, i), n.Content[i], "%v", err)
		})
		if err != nil {
			return err
		}
		*keys, *fleet = k, f
		return nil
	}
}

// namedMap walks a mapping of names to values, normalising each name with
// norm and refusing one given twice (after normalising).
func namedMap(n *yaml.Node, path string, norm func(string) string, each func(name string, v *yaml.Node, path string) error) error {
	n = deref(n)
	if isNull(n) {
		return nil
	}
	if n.Kind != yaml.MappingNode {
		return errAt(path, n, "must be a mapping of names to values, not %s", describe(n))
	}
	given := map[string]bool{}
	for i := 0; i+1 < len(n.Content); i += 2 {
		k, v := n.Content[i], n.Content[i+1]
		if k.Kind != yaml.ScalarNode || k.ShortTag() != "!!str" || strings.TrimSpace(k.Value) == "" {
			return errAt(join(path, "?"), k, "a key must be a name, not %s", describe(k))
		}
		name := norm(strings.TrimSpace(k.Value))
		p := join(path, name)
		if given[name] {
			return errAt(p, k, "is given twice")
		}
		given[name] = true
		if err := each(name, v, p); err != nil {
			return err
		}
	}
	return nil
}

// weights reads name → weight.
func weights(dst *map[string]float64, norm func(string) string) handler {
	return func(n *yaml.Node, path string) error {
		out := map[string]float64{}
		err := namedMap(n, path, norm, func(name string, v *yaml.Node, p string) error {
			w, err := numberValue(v, p)
			out[name] = w
			return err
		})
		if err != nil {
			return err
		}
		*dst = out
		return nil
	}
}

// msRanges reads timing kind → [min_ms, max_ms].
func msRanges(dst *map[string][2]int) handler {
	return func(n *yaml.Node, path string) error {
		out := map[string][2]int{}
		err := namedMap(n, path, strings.ToLower, func(name string, v *yaml.Node, p string) error {
			items, err := pairOf(v, p)
			if err != nil {
				return err
			}
			var r [2]int
			for i, item := range items {
				if r[i], err = wholeValue(item, fmt.Sprintf("%s[%d]", p, i)); err != nil {
					return err
				}
			}
			out[name] = r
			return nil
		})
		if err != nil {
			return err
		}
		*dst = out
		return nil
	}
}

// floatPair reads [lo, hi] as two numbers.
func floatPair(n *yaml.Node, path string) ([2]float64, error) {
	var r [2]float64
	items, err := pairOf(n, path)
	if err != nil {
		return r, err
	}
	for i, item := range items {
		if r[i], err = numberValue(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
			return r, err
		}
	}
	return r, nil
}

// probabilities reads chat moment → [lo, hi].
func probabilities(dst *map[string][2]float64) handler {
	return func(n *yaml.Node, path string) error {
		out := map[string][2]float64{}
		err := namedMap(n, path, strings.ToLower, func(name string, v *yaml.Node, p string) error {
			r, err := floatPair(v, p)
			out[name] = r
			return err
		})
		if err != nil {
			return err
		}
		*dst = out
		return nil
	}
}

// tuning reads personality family → trait → [lo, hi].
func tuning(dst *map[string]map[string][2]float64) handler {
	return func(n *yaml.Node, path string) error {
		out := map[string]map[string][2]float64{}
		err := namedMap(n, path, strings.ToUpper, func(kind string, v *yaml.Node, p string) error {
			traits := map[string][2]float64{}
			out[kind] = traits
			return namedMap(v, p, strings.ToLower, func(trait string, tv *yaml.Node, tp string) error {
				r, err := floatPair(tv, tp)
				traits[trait] = r
				return err
			})
		})
		if err != nil {
			return err
		}
		*dst = out
		return nil
	}
}

// ---------------------------------------------------------------------------
// Helpers.

func deref(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode && n.Alias != nil {
		n = n.Alias
	}
	return n
}

func isNull(n *yaml.Node) bool {
	return n == nil || (n.Kind == yaml.ScalarNode && n.ShortTag() == "!!null")
}

// describe names what a node is, for "must be X, not Y".
func describe(n *yaml.Node) string {
	n = deref(n)
	if n == nil {
		return "nothing"
	}
	switch n.Kind {
	case yaml.MappingNode:
		return "a mapping"
	case yaml.SequenceNode:
		if len(n.Content) == 1 {
			return "a list of one value"
		}
		return fmt.Sprintf("a list of %d values", len(n.Content))
	case yaml.ScalarNode:
		switch n.ShortTag() {
		case "!!null":
			return "nothing"
		case "!!str":
			return fmt.Sprintf("the text %q", n.Value)
		case "!!int":
			return "the whole number " + n.Value
		case "!!float":
			return "the number " + n.Value
		case "!!bool":
			return "the switch " + n.Value
		}
		return fmt.Sprintf("%q (%s)", n.Value, n.ShortTag())
	}
	return "an unexpected YAML node"
}

func errAt(path string, n *yaml.Node, format string, args ...any) error {
	line := 0
	if n != nil {
		line = n.Line
	}
	return fmt.Errorf("%s (line %d): %s", path, line, fmt.Sprintf(format, args...))
}

func join(prefix, key string) string {
	if prefix == "" {
		return key
	}
	return prefix + "." + key
}

func orTop(path string) string {
	if path == "" {
		return "the top level"
	}
	return path
}

func keysOf(s section) []string {
	keys := make([]string, 0, len(s))
	for k := range s {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// schemaKeys lists every dotted key the file may hold and the pairs of keys
// that spell one setting (for the test that holds configs/bot.yaml complete).
func schemaKeys() (keys []string, alternates [][2]string) {
	var c Config
	d := newDecoder(&c)
	var walk func(prefix string, s section)
	walk = func(prefix string, s section) {
		for _, k := range keysOf(s) {
			p := join(prefix, k)
			keys = append(keys, p)
			if s[k].sub != nil {
				walk(p, s[k].sub)
			}
		}
	}
	walk("", d.schema())
	return keys, d.alts
}

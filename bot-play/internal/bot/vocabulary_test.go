package bot

import (
	"slices"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/interaction"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/timing"
	"github.com/surajk543/king-teenpatti/bot-play/internal/config"
)

// config validates names against its own copies of these lists, because it
// imports none of the packages that own them; this pins the copies to the
// originals so a new personality, timing kind or chat moment cannot be
// refused by the config reader (or an old one accepted after removal).
func TestConfigKnowsExactlyTheNamesThePackagesUse(t *testing.T) {
	kinds := make([]string, 0, len(strategy.Kinds))
	for _, k := range strategy.Kinds {
		kinds = append(kinds, string(k))
	}
	sameSet(t, "personality kinds", config.PersonalityKinds, kinds)

	var tk []string
	for _, k := range timing.Kinds() {
		tk = append(tk, string(k))
	}
	sameSet(t, "timing kinds", config.TimingKinds, tk)

	var moments []string
	for _, m := range interaction.Moments() {
		moments = append(moments, string(m))
	}
	sameSet(t, "chat moments", config.ChatMoments, moments)
}

func sameSet(t *testing.T, what string, got, want []string) {
	t.Helper()
	a, b := slices.Clone(got), slices.Clone(want)
	slices.Sort(a)
	slices.Sort(b)
	if !slices.Equal(a, b) {
		t.Errorf("%s: config has %v, the package has %v", what, a, b)
	}
}

package table

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// liveCatalogue is GET /api/tables as production served it on 27 Sep 2026
// (the bands and order of the Teen Patti tables, the four poker rooms), plus
// a private template and two entries no bot may pick.
func liveCatalogue() protocol.Catalogue {
	tp := protocol.EngineTeenPatti
	return protocol.Catalogue{
		Version:       "v-live",
		TurnTimeoutMs: 25000,
		MaxPlayers:    5,
		Tables: []protocol.TableEntry{
			{Key: "seen:200", Engine: tp, Category: "seen", BootAmount: 200, SortOrder: 10},
			{Key: "blind:200", Engine: tp, Category: "blind", BootAmount: 200, MaxChips: 2_000_000, SortOrder: 20},
			{Key: "blind:5000", Engine: tp, Category: "blind", BootAmount: 5000, MaxChips: 200_000_000, SortOrder: 30},
			{Key: "blind:50000", Engine: tp, Category: "blind", BootAmount: 50000, MaxChips: 2_000_000_000, SortOrder: 40},
			{Key: "blind:2000000", Engine: tp, Category: "blind", BootAmount: 2_000_000, MinChips: 500_000_000, SortOrder: 50},
			{Key: "variation:50000", Engine: tp, Category: "variation", BootAmount: 50000, MaxChips: 2_000_000_000, SortOrder: 60},
			{Key: "variation:2000000", Engine: tp, Category: "variation", BootAmount: 2_000_000, MinChips: 500_000_000, SortOrder: 70},
			{Key: "seen:50000", Engine: tp, Category: "seen", BootAmount: 50000, SortOrder: 80, TurnTimeoutMs: 30000},
			{Key: "three_card_poker:50000", Engine: "poker", Category: "three_card_poker", BootAmount: 50000, MinChips: 500000, SortOrder: 90},
			{Key: "five_card_draw:50000", Engine: "poker", Category: "five_card_draw", BootAmount: 50000, MinChips: 500000, SortOrder: 100},
			{Key: "texas_holdem:50000", Engine: "poker", Category: "texas_holdem", BootAmount: 50000, MinChips: 500000, SortOrder: 110},
			{Key: "omaha:50000", Engine: "poker", Category: "omaha", BootAmount: 50000, MinChips: 500000, SortOrder: 120},
			{Key: "private:seen", Engine: tp, Category: "seen", BootAmount: 200, IsPrivate: true, SortOrder: 1010},
			{Key: "seen:777", Engine: "poker", Category: "seen", BootAmount: 777, SortOrder: 130}, // filed under the wrong engine
			{Key: "blind:0", Engine: tp, Category: "blind", BootAmount: 0, SortOrder: 140},        // no boot
		},
	}
}

var liveKeys = []string{
	"seen:200", "blind:200", "blind:5000", "blind:50000", "blind:2000000",
	"variation:50000", "variation:2000000", "seen:50000",
}

// sessionOf is session:ready.config carrying the same lobby tables the way a
// session does: no engine, no key, no sort order.
func sessionOf(cat protocol.Catalogue, version string) protocol.SessionConfig {
	cfg := protocol.SessionConfig{TurnTimeoutMs: cat.TurnTimeoutMs, TableConfigVersion: version}
	for _, e := range cat.Tables {
		if e.IsPrivate {
			continue
		}
		cfg.Tables = append(cfg.Tables, protocol.TableEntry{
			Category: e.Category, BootAmount: e.BootAmount, MinChips: e.MinChips, MaxChips: e.MaxChips,
		})
	}
	return cfg
}

func TestFromCatalogueKeepsThePublicTeenPattiTablesInTheServersOrderWithTheirBands(t *testing.T) {
	m := FromCatalogue(liveCatalogue(), nil)
	if m.Version != "v-live" {
		t.Fatalf("version %q", m.Version)
	}
	if got := m.Keys(); !reflect.DeepEqual(got, liveKeys) {
		t.Fatalf("keys %v, want %v", got, liveKeys)
	}
	c, _ := m.Lookup("blind:200")
	if c.MinChips != 0 || c.MaxChips != 2_000_000 || c.Boot != 200 || c.Category != "blind" {
		t.Fatalf("blind:200 = %+v", c)
	}
	c, _ = m.Lookup("variation:2000000")
	if c.MinChips != 500_000_000 || c.MaxChips != 0 {
		t.Fatalf("variation:2000000 = %+v", c)
	}
	if c.TurnTimeoutMs != 25000 {
		t.Fatalf("a table with no clock of its own takes the catalogue's, got %d", c.TurnTimeoutMs)
	}
	if c, _ := m.Lookup("seen:50000"); c.TurnTimeoutMs != 30000 {
		t.Fatalf("a table's own clock is kept, got %d", c.TurnTimeoutMs)
	}
	for _, c := range m.Tables {
		if !IsTeenPatti(c.Category) {
			t.Fatalf("non-Teen-Patti table on the menu: %+v", c)
		}
	}
	for _, k := range []string{"texas_holdem:50000", "omaha:50000", "private:seen", "seen:777", "blind:0"} {
		if m.Offered(k) {
			t.Fatalf("%s must not be on the menu", k)
		}
	}
}

func TestFromCatalogueKeepsOnlyTheAllowedTeenPattiCategories(t *testing.T) {
	m := FromCatalogue(liveCatalogue(), []string{"blind"})
	want := []string{"blind:200", "blind:5000", "blind:50000", "blind:2000000"}
	if got := m.Keys(); !reflect.DeepEqual(got, want) {
		t.Fatalf("keys %v, want %v", got, want)
	}
	// A poker category in the configuration lets no poker table in.
	m = FromCatalogue(liveCatalogue(), []string{"seen", "texas_holdem", "omaha"})
	if got := m.Keys(); !reflect.DeepEqual(got, []string{"seen:200", "seen:50000"}) {
		t.Fatalf("keys %v", got)
	}
	m = FromCatalogue(liveCatalogue(), []string{"texas_holdem"})
	if len(m.Tables) != 0 {
		t.Fatalf("a configuration naming only poker leaves nothing, got %v", m.Keys())
	}
}

func TestFromCatalogueFillsAMissingKeyAndReadsAMissingEngineByName(t *testing.T) {
	cat := protocol.Catalogue{Tables: []protocol.TableEntry{
		{Category: "blind", BootAmount: 5000, SortOrder: 2},
		{Category: "texas_holdem", BootAmount: 50000, SortOrder: 3},
		{Category: "seen", BootAmount: 200, SortOrder: 1, MinChips: -5, MaxChips: -1},
		{Category: "seen", BootAmount: 200, SortOrder: 4, MaxChips: 99}, // same key again
	}}
	m := FromCatalogue(cat, nil)
	if got := m.Keys(); !reflect.DeepEqual(got, []string{"seen:200", "blind:5000"}) {
		t.Fatalf("keys %v (sorted by sortOrder, poker dropped, first of a key kept)", got)
	}
	if c := m.Tables[0]; c.MinChips != 0 || c.MaxChips != 0 {
		t.Fatalf("a negative band reads as no limit: %+v", c)
	}
}

func TestFromSessionRecognisesTheTeenPattiCategoriesByName(t *testing.T) {
	m := FromSession(sessionOf(liveCatalogue(), "v-sess"), nil)
	if m.Version != "v-sess" {
		t.Fatalf("version %q", m.Version)
	}
	// seen:777 carried the poker engine in the catalogue; a session has no
	// engine to say so, so by name it is a seen table.
	want := append(append([]string(nil), liveKeys...), "seen:777")
	if got := m.Keys(); !reflect.DeepEqual(got, want) {
		t.Fatalf("keys %v, want %v", got, want)
	}
	c, _ := m.Lookup("blind:5000")
	if c.MaxChips != 200_000_000 || c.TurnTimeoutMs != 25000 {
		t.Fatalf("blind:5000 = %+v", c)
	}
	for i, c := range m.Tables {
		if c.SortOrder != 0 && i > 0 && c.SortOrder <= m.Tables[i-1].SortOrder {
			t.Fatalf("session order not kept at %d: %+v", i, m.Tables)
		}
	}
}

func TestAdmitsAllowsExactlyTheBandLimitsAndOneBoot(t *testing.T) {
	m := FromCatalogue(liveCatalogue(), nil)
	cases := []struct {
		key   string
		chips int64
		want  bool
	}{
		{"seen:200", 199, false},
		{"seen:200", 200, true},
		{"seen:200", 5_000_000_000_000, true},
		{"blind:200", 2_000_000, true},
		{"blind:200", 2_000_001, false},
		{"blind:5000", 200_000_000, true},
		{"blind:5000", 200_000_001, false},
		{"blind:2000000", 499_999_999, false},
		{"blind:2000000", 500_000_000, true},
		{"variation:2000000", 500_000_000, true},
		{"seen:50000", 49_999, false},
		{"seen:50000", 50_000, true},
	}
	for _, tc := range cases {
		c, ok := m.Lookup(tc.key)
		if !ok {
			t.Fatalf("%s not on the menu", tc.key)
		}
		if got := m.Admits(c, tc.chips); got != tc.want {
			t.Errorf("Admits(%s, %d) = %v, want %v", tc.key, tc.chips, got, tc.want)
		}
	}
	if m.Admits(Choice{Key: "x", Category: "seen"}, 1_000_000) {
		t.Error("a table with no boot admits nobody")
	}
	// A band whose floor is under the boot still needs the boot.
	if m.Admits(Choice{Boot: 1000, MinChips: 10}, 500) {
		t.Error("a stack under the boot is never admitted")
	}
}

// fakeAPI serves a catalogue; only Tables is used.
type fakeAPI struct {
	mu    sync.Mutex
	cat   protocol.Catalogue
	err   error
	calls int
}

func (f *fakeAPI) set(cat protocol.Catalogue, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cat, f.err = cat, err
}

func (f *fakeAPI) Tables(context.Context) (protocol.Catalogue, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.cat, f.err
}

func (f *fakeAPI) Login(context.Context, string, string) (protocol.LoginResult, error) {
	return protocol.LoginResult{}, errors.New("unused")
}
func (f *fakeAPI) Me(context.Context, string) (protocol.User, error) {
	return protocol.User{}, errors.New("unused")
}
func (f *fakeAPI) CollectBonus(context.Context, string) (protocol.User, error) {
	return protocol.User{}, errors.New("unused")
}
func (f *fakeAPI) FreePictureIDs(context.Context) ([]int64, error)  { return nil, errors.New("unused") }
func (f *fakeAPI) WearPicture(context.Context, string, int64) error { return errors.New("unused") }

var _ protocol.API = (*fakeAPI)(nil)

func TestFinderRefreshRetireAndAge(t *testing.T) {
	api := &fakeAPI{cat: liveCatalogue()}
	now := time.Unix(1_000_000, 0)
	f := NewFinder(api, nil, func() time.Time { return now })
	if f.Known() || len(f.Menu().Tables) != 0 || f.Age() != 0 {
		t.Fatal("a new finder holds no menu")
	}
	if err := f.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !f.Known() || f.Version() != "v-live" || !reflect.DeepEqual(f.Menu().Keys(), liveKeys) {
		t.Fatalf("after refresh: %v %q", f.Menu().Keys(), f.Version())
	}
	now = now.Add(90 * time.Second)
	if f.Age() != 90*time.Second {
		t.Fatalf("age %v", f.Age())
	}

	f.Retire("blind:5000")
	f.Retire("blind:5000")
	if f.Menu().Offered("blind:5000") || len(f.Menu().Tables) != len(liveKeys)-1 {
		t.Fatalf("retired table still offered: %v", f.Menu().Keys())
	}
	// The menu handed out is the caller's own.
	m := f.Menu()
	m.Tables[0].Boot = 1
	if c, _ := f.Menu().Lookup("seen:200"); c.Boot != 200 {
		t.Fatal("Menu shares its slice with the finder")
	}

	// A failed refresh keeps the menu (and the retirement).
	api.set(protocol.Catalogue{}, errors.New("boom"))
	if err := f.Refresh(context.Background()); err == nil {
		t.Fatal("want the error")
	}
	if f.Menu().Offered("blind:5000") || !f.Menu().Offered("seen:200") {
		t.Fatal("a failed refresh changed the menu")
	}
	// A catalogue listing nothing is not a menu.
	api.set(protocol.Catalogue{Version: "v-empty"}, nil)
	if err := f.Refresh(context.Background()); !errors.Is(err, ErrNoTables) {
		t.Fatalf("err %v, want ErrNoTables", err)
	}
	if f.Version() != "v-live" {
		t.Fatal("an empty catalogue replaced the menu")
	}
	// The next good refresh brings the retired table back.
	api.set(liveCatalogue(), nil)
	if err := f.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !f.Menu().Offered("blind:5000") {
		t.Fatal("a refresh should clear retirements")
	}
	if f.Age() != 0 {
		t.Fatalf("age after refresh %v", f.Age())
	}
}

func TestFinderNoticeSessionReplacesTheMenuOnceForANewVersion(t *testing.T) {
	api := &fakeAPI{cat: liveCatalogue()}
	f := NewFinder(api, nil, nil)
	if err := f.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.NoticeSession(sessionOf(liveCatalogue(), "v-live")) {
		t.Fatal("the version held is not stale")
	}
	f.Retire("seen:200")

	// A new catalogue: blind:5000 gone.
	changed := liveCatalogue()
	changed.Tables = append(changed.Tables[:2:2], changed.Tables[3:]...)
	if !f.NoticeSession(sessionOf(changed, "v2")) {
		t.Fatal("a new version is stale")
	}
	if f.Version() != "v2" || f.Menu().Offered("blind:5000") {
		t.Fatalf("session list not applied: %q %v", f.Version(), f.Menu().Keys())
	}
	if !f.Menu().Offered("seen:200") {
		t.Fatal("a new menu clears retirements")
	}
	// Every later bot naming the same version asks for nothing.
	for range 5 {
		if f.NoticeSession(sessionOf(changed, "v2")) {
			t.Fatal("one refresh for the fleet, not one per bot")
		}
	}
	// No version: an older server; changes nothing once a menu is known.
	if f.NoticeSession(protocol.SessionConfig{Tables: []protocol.TableEntry{{Category: "seen", BootAmount: 1}}}) {
		t.Fatal("no version is never stale")
	}
	if f.Version() != "v2" || f.Menu().Offered("seen:1") {
		t.Fatal("a versionless session replaced a known menu")
	}
	// A new version whose list is empty keeps the menu and is stale once.
	if !f.NoticeSession(protocol.SessionConfig{TableConfigVersion: "v3"}) {
		t.Fatal("new version, empty list: stale")
	}
	if f.NoticeSession(protocol.SessionConfig{TableConfigVersion: "v3"}) {
		t.Fatal("reported stale twice for one version")
	}
	if f.Version() != "v2" || len(f.Menu().Tables) == 0 {
		t.Fatal("an empty session list replaced the menu")
	}
}

func TestFinderTakesItsFirstMenuFromASessionWhenRestFailed(t *testing.T) {
	api := &fakeAPI{err: errors.New("down")}
	f := NewFinder(api, []string{"seen", "blind"}, nil)
	if err := f.Refresh(context.Background()); err == nil {
		t.Fatal("want the error")
	}
	// An older server: no version, but its list is the menu while none is known.
	if f.NoticeSession(sessionOf(liveCatalogue(), "")) {
		t.Fatal("no version: never stale")
	}
	if !f.Known() || f.Menu().Offered("variation:50000") || !f.Menu().Offered("blind:200") {
		t.Fatalf("menu %v", f.Menu().Keys())
	}
}

func TestFinderIsSafeForConcurrentUse(t *testing.T) {
	api := &fakeAPI{cat: liveCatalogue()}
	f := NewFinder(api, nil, nil)
	var wg sync.WaitGroup
	for i := range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range 50 {
				switch (i + j) % 4 {
				case 0:
					_ = f.Refresh(context.Background())
				case 1:
					f.NoticeSession(sessionOf(liveCatalogue(), fmt.Sprintf("v%d", j%3)))
				case 2:
					f.Retire(liveKeys[j%len(liveKeys)])
				default:
					m := f.Menu()
					for _, c := range m.Tables {
						_ = m.Admits(c, 1_000_000)
					}
					_ = f.Age()
				}
			}
		}()
	}
	wg.Wait()
}

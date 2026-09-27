package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

// Pagination end to end (owner, 27 Sep 2026: "All apis should be pagination
// and default page size is 20" — "reported user should be fetched using
// pagination, and same with friend list, as user scroll, then it will fetch
// more"): a player with 25 requests, 25 friends and 25 reports reads each a
// page of 20 and then the other 5, every item once, and a page the server did
// not write is 400 invalid_page.
func TestTheListsComeTwentyAtATimeAndThePagesTogetherAreTheList(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	tokA, idA := login(t, ts.URL, "paging-device-mira-000", "Mira")
	others := make([]string, 25)
	for i := range others {
		tok, id := login(t, ts.URL, fmt.Sprintf("paging-device-other-%03d", i), fmt.Sprintf("Other%02d", i))
		others[i] = id
		status, raw := friendsCall(t, ts.URL, tok, http.MethodPost, "/api/friends/requests",
			fmt.Sprintf(`{"userId":%q}`, idA))
		mustStatus(t, "a request to Mira", status, http.StatusCreated, raw)
	}

	type requestsPage struct {
		Incoming      []struct{ RequestID int64 } `json:"incoming"`
		IncomingTotal int                         `json:"incomingTotal"`
		NextIncoming  *string                     `json:"nextIncoming"`
		Requests      []struct{ RequestID int64 } `json:"requests"`
		Total         int                         `json:"total"`
		NextCursor    *string                     `json:"nextCursor"`
	}
	read := func(path string, into any) {
		t.Helper()
		status, raw := friendsCall(t, ts.URL, tokA, http.MethodGet, path, "")
		mustStatus(t, path, status, http.StatusOK, raw)
		if err := json.Unmarshal(raw, into); err != nil {
			t.Fatalf("%s: %v in %s", path, err, raw)
		}
	}

	// ---- the requests: 20, then the other 5 from the incoming box.
	var first requestsPage
	read("/api/friends/requests", &first)
	if len(first.Incoming) != 20 || first.IncomingTotal != 25 || first.NextIncoming == nil {
		t.Fatalf("the first page of requests: %d, total %d, next %v", len(first.Incoming), first.IncomingTotal, first.NextIncoming)
	}
	var rest requestsPage
	read("/api/friends/requests?box=incoming&cursor="+url.QueryEscape(*first.NextIncoming), &rest)
	if len(rest.Requests) != 5 || rest.Total != 25 || rest.NextCursor != nil {
		t.Fatalf("the second page of requests: %d, total %d, next %v", len(rest.Requests), rest.Total, rest.NextCursor)
	}
	ids := map[int64]bool{}
	for _, r := range append(first.Incoming, rest.Requests...) {
		if ids[r.RequestID] {
			t.Fatalf("request %d listed twice", r.RequestID)
		}
		ids[r.RequestID] = true
	}
	if len(ids) != 25 {
		t.Fatalf("%d requests across the pages", len(ids))
	}
	for path, why := range map[string]string{
		"/api/friends/requests?cursor=" + url.QueryEscape(*first.NextIncoming): "a cursor with no box",
		"/api/friends/requests?box=sideways":                                   "an unknown box",
		"/api/friends/requests?limit=0":                                        "a limit of 0",
		"/api/friends?limit=abc":                                               "a limit that is no number",
		"/api/friends?cursor=nonsense":                                         "a cursor it never wrote",
		"/api/reports/mine?cursor=" + url.QueryEscape(*first.NextIncoming)[:5]: "a cursor cut short",
	} {
		status, raw := friendsCall(t, ts.URL, tokA, http.MethodGet, path, "")
		mustStatus(t, why, status, http.StatusBadRequest, raw)
		mustBody(t, why, raw, `{"error":"invalid_page","message":"That page does not exist."}`)
	}

	// ---- the friends: every request accepted, then 20 and the other 5.
	for id := range ids {
		status, raw := friendsCall(t, ts.URL, tokA, http.MethodPost, fmt.Sprintf("/api/friends/requests/%d/accept", id), "")
		mustStatus(t, "accept", status, http.StatusOK, raw)
	}
	type friendsPage struct {
		Friends    []struct{ UserID string } `json:"friends"`
		Total      int                       `json:"total"`
		NextCursor *string                   `json:"nextCursor"`
	}
	var one, two, all friendsPage
	read("/api/friends", &one)
	if len(one.Friends) != 20 || one.Total != 25 || one.NextCursor == nil {
		t.Fatalf("the first page of friends: %d, total %d, next %v", len(one.Friends), one.Total, one.NextCursor)
	}
	read("/api/friends?cursor="+url.QueryEscape(*one.NextCursor), &two)
	if len(two.Friends) != 5 || two.Total != 25 || two.NextCursor != nil {
		t.Fatalf("the second page of friends: %d, total %d, next %v", len(two.Friends), two.Total, two.NextCursor)
	}
	seen := map[string]bool{}
	for _, f := range append(one.Friends, two.Friends...) {
		if seen[f.UserID] {
			t.Fatalf("friend %s listed twice", f.UserID)
		}
		seen[f.UserID] = true
	}
	for _, id := range others {
		if !seen[id] {
			t.Fatalf("friend %s on no page", id)
		}
	}
	read("/api/friends?limit=500", &all)
	if len(all.Friends) != 25 || all.NextCursor != nil {
		t.Fatalf("a limit over the most: %d friends, next %v", len(all.Friends), all.NextCursor)
	}
	read("/api/friends?limit=7", &all)
	if len(all.Friends) != 7 || all.NextCursor == nil {
		t.Fatalf("a page of 7: %d friends, next %v", len(all.Friends), all.NextCursor)
	}

	// ---- the reports: 25 of Mira's, 20 and then the other 5.
	for i, id := range others {
		if _, err := database.Pool.Exec(ctx,
			`INSERT INTO player_reports (reporter_user_id, reported_user_id, reason, game, category, table_id,
			                             status, created_at, updated_at)
			 VALUES ($1, $2, 'SPAM', 'teen_patti', 'seen', 'room-x', 'PENDING', $3, $3)`,
			idA, id, int64(1_790_000_000_000+i*1000)); err != nil {
			t.Fatal(err)
		}
	}
	type reportsPage struct {
		Reports []struct {
			Player    struct{ DisplayName string } `json:"player"`
			CreatedAt int64                        `json:"createdAt"`
		} `json:"reports"`
		Total      int     `json:"total"`
		NextCursor *string `json:"nextCursor"`
	}
	var r1, r2 reportsPage
	read("/api/reports/mine", &r1)
	if len(r1.Reports) != 20 || r1.Total != 25 || r1.NextCursor == nil || r1.Reports[0].Player.DisplayName != "Other24" {
		t.Fatalf("the first page of reports: %d, total %d, next %v, first %+v", len(r1.Reports), r1.Total, r1.NextCursor, r1.Reports[0])
	}
	read("/api/reports/mine?cursor="+url.QueryEscape(*r1.NextCursor), &r2)
	if len(r2.Reports) != 5 || r2.NextCursor != nil || r2.Reports[4].Player.DisplayName != "Other00" {
		t.Fatalf("the second page of reports: %d, next %v", len(r2.Reports), r2.NextCursor)
	}
	joined := append(r1.Reports, r2.Reports...)
	for i := 1; i < len(joined); i++ {
		if joined[i].CreatedAt >= joined[i-1].CreatedAt {
			t.Fatalf("reports not newest first at %d", i)
		}
	}
}

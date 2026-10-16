package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// statusReport is the body of the "Ready for testing" issue: what waits for a decision, what is on
// its way to stable, and what is held, yanked or a pre-release. Empty when nothing is pending
// (every build in its final channel). waiting lists the builds that need a decision, so the issue
// can be notified when one is new.
func statusReport(all []placed, repo string, now time.Time) (body string, waiting []string) {
	sorted := append([]placed(nil), all...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].key() < sorted[j].key() })
	promote := fmt.Sprintf("https://github.com/%s/actions/workflows/promote.yml", repo)
	date := func(t time.Time) string { return t.UTC().Format("2006-01-02 15:04 UTC") }

	var decide, toStable, held, yanked, pre []string
	for _, p := range sorted {
		k := p.key()
		switch {
		case p.Yanked != "":
			yanked = append(yanked, fmt.Sprintf("| `%s` | %s |", k, p.Yanked))
			continue
		case strings.HasPrefix(p.Why, "held: ") || strings.Contains(p.Why, "; held: "):
			held = append(held, fmt.Sprintf("| `%s` | %s | %s |", k, channelNames[p.Level], p.Why[strings.Index(p.Why, "held: ")+6:]))
		}
		switch {
		case p.NeedsDecision && p.Level == experimental:
			without := "stays in experimental (held)"
			if p.Next == beta {
				without = "moves to beta on " + date(p.NextAt) + ", then waits for you"
			}
			decide = append(decide, fmt.Sprintf("| `%s` | experimental | %s | `promote-beta` |", k, without))
			waiting = append(waiting, k)
		case p.NeedsDecision && p.Level == beta:
			decide = append(decide, fmt.Sprintf("| `%s` | beta | stays in beta (it got there without a decision) | `promote-stable` |", k))
			waiting = append(waiting, k)
		case p.Next == stable:
			toStable = append(toStable, fmt.Sprintf("| `%s` | %s | %s |", k, p.Kind, date(p.NextAt)))
		case p.Prerelease && p.Level == beta:
			pre = append(pre, fmt.Sprintf("| `%s` |", k))
		}
	}
	if len(decide)+len(toStable)+len(held)+len(yanked)+len(pre) == 0 {
		return "", nil
	}

	var b strings.Builder
	fmt.Fprintf(&b, "Builds that aren't in their final channel yet. Decide with the [Promote workflow](%s) "+
		"(action and target as below; a target can also be a version, e.g. `postgres-19.0`, or `all-pending`). "+
		"Updated by the Manifest workflow, %s.\n", promote, date(now))
	section := func(title, header string, rows []string) {
		if len(rows) == 0 {
			return
		}
		fmt.Fprintf(&b, "\n### %s\n\n%s\n", title, header)
		for _, r := range rows {
			b.WriteString(r + "\n")
		}
	}
	section("Waiting for you", "| Build | Channel | Without a decision | Action |\n|---|---|---|---|", decide)
	section("On their way to stable", "| Build | Kind | Stable at |\n|---|---|---|", toStable)
	section("Held", "| Build | Channel | Reason |\n|---|---|---|", held)
	section("Pre-releases (beta only)", "| Build |\n|---|", pre)
	section("Yanked", "| Build | Reason |\n|---|---|", yanked)
	return b.String(), waiting
}

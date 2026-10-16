package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// runDecide records a decision in channels.json (the Promote workflow commits it):
//
//	flockrel decide -action promote-beta|promote-stable|hold|unhold|yank|unyank -target <target> [-reason <text>]
//
// Targets: a build (postgres-18.7-build1-macos-arm64), a build on every platform
// (postgres-18.7-build1), a version on one platform (postgres-18.7-macos-arm64) or on every
// platform (postgres-18.7), which mean its newest build there; or all-pending, which promotes
// everything waiting for that step. Yanks need a build number, so the build that is withdrawn is
// never a guess. Hold and yank need a reason.
func runDecide(args []string) error {
	fs := flag.NewFlagSet("decide", flag.ExitOnError)
	versionsPath := fs.String("versions", "versions.json", "versions file")
	channelsPath := fs.String("channels", "channels.json", "channel decisions to update")
	repo := fs.String("repo", os.Getenv("GITHUB_REPOSITORY"), "owner/name of the binaries repository")
	action := fs.String("action", "", "promote-beta, promote-stable, hold, unhold, yank or unyank")
	target := fs.String("target", "", "what the decision is about (see flockrel decide)")
	reason := fs.String("reason", "", "why (required for hold and yank)")
	fs.Parse(args)

	v, err := loadVersions(*versionsPath)
	if err != nil {
		return err
	}
	d, err := loadDecisions(*channelsPath)
	if err != nil {
		return err
	}
	builds, err := publishedBuilds(*repo, v)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Truncate(time.Second)
	all := place(builds, d, v.patchWait(), v.betaWait(), now)
	changes, err := decide(d, all, *action, strings.TrimSpace(*target), strings.TrimSpace(*reason), now)
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(*channelsPath, append(data, '\n'), 0o644); err != nil {
		return err
	}
	for _, c := range changes {
		fmt.Println(c)
	}
	return nil
}

// decide applies one decision to d and describes what changed. It refuses decisions that
// would do nothing or break the rules (a pre-release to stable, a yank without a build number).
func decide(d *channelDecisions, all []placed, action, target, reason string, now time.Time) ([]string, error) {
	if (action == "hold" || action == "yank") && reason == "" {
		return nil, fmt.Errorf("%s needs a reason", action)
	}
	var builds []placed
	var err error
	if target == "all-pending" {
		switch action {
		case "promote-beta":
			builds = filter(all, func(p placed) bool { return p.Level == experimental && p.NeedsDecision && d.Hold[p.key()] == "" })
		case "promote-stable":
			builds = filter(all, func(p placed) bool { return p.Level == beta && !p.Prerelease && d.Hold[p.key()] == "" })
		default:
			return nil, fmt.Errorf("all-pending only works with promote-beta and promote-stable")
		}
		if len(builds) == 0 {
			return nil, fmt.Errorf("nothing is waiting for %s", action)
		}
	} else if builds, err = resolveTarget(all, target, action == "yank" || action == "unyank"); err != nil {
		return nil, err
	}

	if d.Approved == nil {
		d.Approved = map[string]approval{}
	}
	if d.Hold == nil {
		d.Hold = map[string]string{}
	}
	if d.Yanked == nil {
		d.Yanked = map[string]string{}
	}
	var changes []string
	changed := false
	for _, p := range builds {
		k := p.key()
		switch action {
		case "promote-beta", "promote-stable":
			want := map[string]level{"promote-beta": beta, "promote-stable": stable}[action]
			if want == stable && p.Prerelease {
				return nil, fmt.Errorf("%s is a pre-release: pre-releases never go to stable", k)
			}
			if p.Level >= want {
				changes = append(changes, fmt.Sprintf("%s: already %s", k, channelNames[p.Level]))
				continue
			}
			a := d.Approved[k]
			t := now
			if want == beta {
				a.Beta = &t
			} else {
				a.Stable = &t
			}
			d.Approved[k] = a
			changed = true
			changes = append(changes, fmt.Sprintf("%s: approved for %s (was %s)", k, channelNames[want], channelNames[p.Level]))
		case "hold":
			if p.Level == stable {
				changes = append(changes, k+": already stable, a hold has no effect")
				continue
			}
			d.Hold[k] = reason
			changed = true
			changes = append(changes, fmt.Sprintf("%s: held (%s)", k, reason))
		case "unhold":
			if _, ok := d.Hold[k]; !ok {
				changes = append(changes, k+": not held")
				continue
			}
			delete(d.Hold, k)
			changed = true
			changes = append(changes, k+": no longer held")
		case "yank":
			d.Yanked[k] = reason
			changed = true
			changes = append(changes, fmt.Sprintf("%s: yanked (%s)", k, reason))
		case "unyank":
			if _, ok := d.Yanked[k]; !ok {
				changes = append(changes, k+": not yanked")
				continue
			}
			delete(d.Yanked, k)
			changed = true
			changes = append(changes, k+": no longer yanked")
		default:
			return nil, fmt.Errorf("unknown action %q", action)
		}
	}
	if !changed {
		return nil, errors.New("nothing to change: " + strings.Join(changes, "; "))
	}
	return changes, nil
}

// resolveTarget finds the builds a target names; see runDecide. exact demands a build number.
func resolveTarget(all []placed, target string, exact bool) ([]placed, error) {
	var hits []placed
	var unnamed []string          // builds a version target means, when a build number is required
	newest := map[string]placed{} // platform → newest build of the version
	for _, p := range all {
		pv := p.Package + "-" + p.Version
		build := fmt.Sprintf("%s-build%d", pv, p.Build)
		switch target {
		case p.key(), build:
			hits = append(hits, p)
		case pv, pv + "-" + p.Platform:
			if exact {
				unnamed = append(unnamed, p.key())
				continue
			}
			if n, ok := newest[p.Platform]; !ok || p.Build > n.Build {
				newest[p.Platform] = p
			}
		}
	}
	for _, p := range newest {
		hits = append(hits, p)
	}
	if len(hits) == 0 {
		if len(unnamed) > 0 {
			sort.Strings(unnamed)
			return nil, fmt.Errorf("give the build number: %q is %s", target, strings.Join(unnamed, ", "))
		}
		return nil, fmt.Errorf("%q names no published build", target)
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].key() < hits[j].key() })
	return hits, nil
}

func filter(all []placed, keep func(placed) bool) []placed {
	var out []placed
	for _, p := range all {
		if keep(p) {
			out = append(out, p)
		}
	}
	return out
}

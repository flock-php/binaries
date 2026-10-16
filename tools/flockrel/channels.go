package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// Channels: every published build is in one of three, and each channel's manifest lists the
// builds at its level or above (beta includes stable, experimental includes everything).
//
//	patch       a new version of a line that is already stable on that platform:
//	            beta at once, stable after channels.patch_hours
//	new         a new line, package or platform, or a rebuild (a higher build of a version):
//	            experimental; beta once approved (or after channels.beta_after_days); stable
//	            channels.patch_hours after a manual beta approval, or when approved for stable
//	prerelease  an RC, beta or alpha: beta, never stable
//	baseline    published before channels.json's baseline: stable
//
// A hold stops every timer of a build; approvals still apply. A yanked build stays listed with
// the reason, so Flock can warn whoever installed it. Timers aren't stored anywhere: they're
// worked out from the publish time on every run, so the result only depends on the releases,
// channels.json and the clock.
type level int

const (
	experimental level = iota + 1
	beta
	stable
)

var channelNames = map[level]string{experimental: "experimental", beta: "beta", stable: "stable"}

// channelDecisions mirrors channels.json: only what a person decided, keyed by build
// (<package>-<version>-build<N>-<platform>).
type channelDecisions struct {
	Baseline time.Time           `json:"baseline"`
	Approved map[string]approval `json:"approved"`
	Hold     map[string]string   `json:"hold"`
	Yanked   map[string]string   `json:"yanked"`
}

type approval struct {
	Beta   *time.Time `json:"beta,omitempty"`
	Stable *time.Time `json:"stable,omitempty"`
}

func loadDecisions(path string) (*channelDecisions, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var d channelDecisions
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if d.Baseline.IsZero() {
		return nil, fmt.Errorf("%s: baseline is required", path)
	}
	return &d, nil
}

// published is one build of a package version for one platform, as found on the releases.
type published struct {
	Package, Version, Platform string
	Build                      int
	Line                       string
	Asset                      asset
}

func (p published) key() string {
	return fmt.Sprintf("%s-%s-build%d-%s", p.Package, p.Version, p.Build, p.Platform)
}

// placed is a build with its channel and why it's there.
type placed struct {
	published
	Kind       string // baseline, patch, new, prerelease
	Level      level
	Why        string // what got it there, or what moves it on
	Prerelease bool
	Yanked     string
	// Next is the channel a timer moves the build to at NextAt (0: none running). NeedsDecision:
	// it only goes further with an approval (a new line in experimental, or in beta by its timer).
	Next          level
	NextAt        time.Time
	NeedsDecision bool
}

// place works out the channel of every build at time now.
func place(builds []published, d *channelDecisions, patch, betaAfter time.Duration, now time.Time) []placed {
	sorted := append([]published(nil), builds...)
	sort.Slice(sorted, func(i, j int) bool {
		a, b := sorted[i], sorted[j]
		if a.Package+a.Platform+a.Line != b.Package+b.Platform+b.Line {
			return a.Package+a.Platform+a.Line < b.Package+b.Platform+b.Line
		}
		if c := cmpVersion(a.Version, b.Version); c != 0 {
			return c < 0
		}
		return a.Build < b.Build
	})

	type group struct{ pkg, platform, line string }
	stableVersions := map[group][]string{} // versions with a stable build, per line and platform
	seenBuild := map[string]bool{}         // "<package> <platform> <version>": an earlier build exists
	out := make([]placed, 0, len(sorted))
	for _, b := range sorted {
		g := group{b.Package, b.Platform, b.Line}
		k := b.key()
		hold, held := d.Hold[k]
		ap := d.Approved[k]
		p := placed{published: b, Prerelease: !stableVersion.MatchString(b.Version), Yanked: d.Yanked[k]}
		published := b.Asset.CreatedAt
		rebuild := seenBuild[b.Package+" "+b.Platform+" "+b.Version]
		seenBuild[b.Package+" "+b.Platform+" "+b.Version] = true
		olderStable := false
		for _, v := range stableVersions[g] {
			if cmpVersion(v, b.Version) < 0 {
				olderStable = true
			}
		}
		timer := func(at time.Time, to string) (bool, string) {
			if held {
				return false, "held: " + hold
			}
			if !now.Before(at) {
				return true, ""
			}
			return false, fmt.Sprintf("%s at %s", to, at.Format(time.RFC3339))
		}

		switch {
		case published.Before(d.Baseline):
			p.Kind, p.Level, p.Why = "baseline", stable, "published before the baseline"
		case p.Prerelease:
			p.Kind = "prerelease"
			if held {
				p.Level, p.Why = experimental, "held: "+hold
			} else {
				p.Level, p.Why = beta, "pre-releases stay in beta"
			}
		case olderStable && !rebuild:
			p.Kind, p.Level = "patch", beta
			if ap.Stable != nil {
				p.Level, p.Why = stable, "approved for stable"
			} else if ok, why := timer(published.Add(patch), "stable"); ok {
				p.Level, p.Why = stable, "patch, stable after "+patch.String()
			} else {
				p.Why = why
				if !held {
					p.Next, p.NextAt = stable, published.Add(patch)
				}
			}
		default:
			p.Kind, p.Level = "new", experimental
			if ap.Beta != nil {
				p.Level, p.Why = beta, "approved for beta"
			} else if ok, why := timer(published.Add(betaAfter), "beta"); ok {
				p.Level, p.Why = beta, "beta after "+betaAfter.String()+" without a decision; stable only when approved"
				p.NeedsDecision = true
			} else {
				p.Why = "waiting for approval; " + why
				p.NeedsDecision = true
				if !held {
					p.Next, p.NextAt = beta, published.Add(betaAfter)
				}
			}
			switch {
			case ap.Stable != nil:
				p.Level, p.Why, p.NeedsDecision = stable, "approved for stable", false
				p.Next, p.NextAt = 0, time.Time{}
			case ap.Beta != nil:
				if ok, why := timer(ap.Beta.Add(patch), "stable"); ok {
					p.Level, p.Why = stable, "approved for beta, stable after "+patch.String()
				} else {
					p.Why = "approved for beta; " + why
					if !held {
						p.Next, p.NextAt = stable, ap.Beta.Add(patch)
					}
				}
			}
		}
		if p.Level == stable {
			stableVersions[g] = append(stableVersions[g], b.Version)
		}
		out = append(out, p)
	}
	return out
}

// lineOf is the release line a version belongs to, for telling patches from new lines:
// the PHP minor for php and frankenphp, the pack itself for php-exts, the configured line
// (the longest that matches) for services, otherwise the version without its last part.
func lineOf(v *versions, pkg, version string) string {
	switch pkg {
	case "php", "frankenphp":
		return minorOf(version)
	case "php-exts":
		return version
	}
	best := ""
	if p, ok := v.Packages[pkg]; ok {
		for _, l := range p.Lines {
			if inLine(version, l) && len(l) > len(best) {
				best = l
			}
		}
	}
	if best != "" {
		return best
	}
	if i := strings.LastIndex(version, "."); i > 0 {
		return version[:i]
	}
	return version
}

// minorOf returns major.minor of a version: 8.4.26 → 8.4, 8.6.0RC1 → 8.6.
func minorOf(version string) string {
	parts := strings.SplitN(version, ".", 3)
	if len(parts) < 2 {
		return version
	}
	return parts[0] + "." + parts[1]
}

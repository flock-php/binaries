package main

import (
	"strings"
	"testing"
	"time"
)

// decideFixture: a stable baseline, a patch in its waiting time, a new line, a held new line,
// a rebuild, a pre-release and php-exts (whose name starts like php's).
func decideFixture() (*channelDecisions, []published, time.Time) {
	base := time.Date(2026, 10, 16, 19, 0, 0, 0, time.UTC)
	at := func(h int) time.Time { return base.Add(time.Duration(h) * time.Hour) }
	lines := &versions{Packages: map[string]pkgConfig{"postgres": {Lines: []string{"18", "19"}}, "valkey": {Lines: []string{"9.1", "9.2"}}}}
	b := func(pkg, ver, platform string, build, h int) published {
		return published{Package: pkg, Version: ver, Platform: platform, Build: build, Line: lineOf(lines, pkg, ver), Asset: asset{CreatedAt: at(h)}}
	}
	builds := []published{
		b("postgres", "18.6", "macos-arm64", 1, -24),
		b("postgres", "18.6", "windows-x64", 1, -24),
		b("postgres", "18.7", "macos-arm64", 1, 1),
		b("postgres", "19.0", "macos-arm64", 1, 1),
		b("postgres", "19.0", "windows-x64", 1, 1),
		b("valkey", "9.2.0", "macos-arm64", 1, 1),
		b("php", "8.4.26", "macos-arm64", 1, -24),
		b("php", "8.4.26", "macos-arm64", 2, 1),
		b("php", "8.6.0RC1", "macos-arm64", 1, 1),
		b("php-exts", "8.4", "windows-x64", 1, -24),
	}
	d := &channelDecisions{Baseline: base, Hold: map[string]string{"valkey-9.2.0-build1-macos-arm64": "testing"}}
	return d, builds, at(5)
}

func TestDecide(t *testing.T) {
	cases := []struct {
		action, target, reason string
		wantErr                string // part of the error, or "" for success
		check                  func(*channelDecisions) bool
	}{
		{"promote-beta", "postgres-19.0", "", "", func(d *channelDecisions) bool {
			return d.Approved["postgres-19.0-build1-macos-arm64"].Beta != nil && d.Approved["postgres-19.0-build1-windows-x64"].Beta != nil
		}},
		{"promote-beta", "postgres-19.0-windows-x64", "", "", func(d *channelDecisions) bool {
			return d.Approved["postgres-19.0-build1-windows-x64"].Beta != nil && d.Approved["postgres-19.0-build1-macos-arm64"].Beta == nil
		}},
		{"promote-stable", "postgres-18.7", "", "", func(d *channelDecisions) bool {
			return d.Approved["postgres-18.7-build1-macos-arm64"].Stable != nil
		}},
		// The version means its newest build: the rebuild, not the stable build 1.
		{"promote-beta", "php-8.4.26", "", "", func(d *channelDecisions) bool {
			return d.Approved["php-8.4.26-build2-macos-arm64"].Beta != nil && d.Approved["php-8.4.26-build1-macos-arm64"].Beta == nil
		}},
		// all-pending skips the held valkey 9.2.0.
		{"promote-beta", "all-pending", "", "", func(d *channelDecisions) bool {
			return d.Approved["postgres-19.0-build1-macos-arm64"].Beta != nil && d.Approved["php-8.4.26-build2-macos-arm64"].Beta != nil &&
				d.Approved["valkey-9.2.0-build1-macos-arm64"].Beta == nil
		}},
		{"yank", "postgres-18.6-build1", "broken", "", func(d *channelDecisions) bool {
			return d.Yanked["postgres-18.6-build1-macos-arm64"] == "broken" && d.Yanked["postgres-18.6-build1-windows-x64"] == "broken"
		}},
		{"hold", "postgres-18.7", "waiting for a fix", "", func(d *channelDecisions) bool {
			return d.Hold["postgres-18.7-build1-macos-arm64"] == "waiting for a fix"
		}},
		{"unhold", "valkey-9.2.0", "", "", func(d *channelDecisions) bool { return d.Hold["valkey-9.2.0-build1-macos-arm64"] == "" }},
		// php-exts-8.4 is the pack, not a php version "exts-8.4".
		{"yank", "php-exts-8.4-build1", "broken", "", func(d *channelDecisions) bool {
			return d.Yanked["php-exts-8.4-build1-windows-x64"] == "broken" && len(d.Yanked) == 1
		}},
		{"promote-stable", "php-8.6.0RC1", "", "never go to stable", nil},
		{"yank", "postgres-18.6", "broken", "give the build number: \"postgres-18.6\" is postgres-18.6-build1-macos-arm64, postgres-18.6-build1-windows-x64", nil},
		{"hold", "postgres-18.6", "x", "nothing to change: postgres-18.6-build1-macos-arm64: already stable, a hold has no effect", nil},
		{"hold", "postgres-18.7", "", "needs a reason", nil},
		{"promote-stable", "postgres-18.6", "", "nothing to change", nil},
		{"unhold", "postgres-18.7", "", "nothing to change", nil},
		{"promote-beta", "postgres-17.1", "", "names no published build", nil},
		{"hold", "all-pending", "x", "only works with promote", nil},
	}
	for _, c := range cases {
		d, builds, now := decideFixture()
		all := place(builds, d, 48*time.Hour, 7*24*time.Hour, now)
		_, err := decide(d, all, c.action, c.target, c.reason, now)
		name := c.action + " " + c.target
		switch {
		case c.wantErr != "" && (err == nil || !strings.Contains(err.Error(), c.wantErr)):
			t.Errorf("%s: error %v, want %q", name, err, c.wantErr)
		case c.wantErr == "" && err != nil:
			t.Errorf("%s: %v", name, err)
		case c.check != nil && !c.check(d):
			t.Errorf("%s: decisions %+v", name, d)
		}
	}
}

func TestStatusReport(t *testing.T) {
	d, builds, now := decideFixture()
	d.Yanked = map[string]string{"postgres-18.6-build1-windows-x64": "broken"}
	body, waiting := statusReport(place(builds, d, 48*time.Hour, 7*24*time.Hour, now), "flock-php/binaries", now)
	for _, want := range []string{
		"### Waiting for you", "`postgres-19.0-build1-macos-arm64` | experimental | moves to beta on 2026-10-23 20:00 UTC",
		"### On their way to stable", "`postgres-18.7-build1-macos-arm64` | patch | 2026-10-18 20:00 UTC",
		"### Held", "`valkey-9.2.0-build1-macos-arm64` | experimental | testing",
		"### Pre-releases (beta only)", "`php-8.6.0RC1-build1-macos-arm64`",
		"### Yanked", "`postgres-18.6-build1-windows-x64` | broken",
		"actions/workflows/promote.yml",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("report lacks %q:\n%s", want, body)
		}
	}
	if strings.Join(waiting, " ") != "php-8.4.26-build2-macos-arm64 postgres-19.0-build1-macos-arm64 postgres-19.0-build1-windows-x64 valkey-9.2.0-build1-macos-arm64" {
		t.Errorf("waiting: %v", waiting)
	}

	// Only stable builds: nothing to report.
	d.Yanked = nil
	if body, _ := statusReport(place(builds[:2], d, 48*time.Hour, 7*24*time.Hour, now), "r", now); body != "" {
		t.Errorf("report for stable builds only: %q", body)
	}
}

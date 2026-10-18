package main

import (
	"encoding/json"
	"testing"
	"time"
)

func TestPlace(t *testing.T) {
	base := time.Date(2026, 10, 16, 19, 0, 0, 0, time.UTC)
	at := func(hours int) time.Time { return base.Add(time.Duration(hours) * time.Hour) }
	ptr := func(t time.Time) *time.Time { return &t }
	lines := &versions{Packages: map[string]pkgConfig{
		"postgres": {Lines: []string{"18", "19"}}, "node": {Lines: []string{"28"}},
		"valkey": {Lines: []string{"9.1", "9.2"}}, "mysql": {Lines: []string{"9.7"}},
	}}
	b := func(pkg, ver, platform string, build, publishedHour int) published {
		return published{Package: pkg, Version: ver, Platform: platform, Build: build, Line: lineOf(lines, pkg, ver),
			Asset: asset{CreatedAt: at(publishedHour)}}
	}
	const mac = "macos-arm64"
	builds := []published{
		b("postgres", "18.6", mac, 1, -24), // before the baseline
		b("postgres", "18.7", mac, 1, 10),  // patch, 48 h passed at hour 60
		b("postgres", "18.8", mac, 1, 50),  // patch, 10 h old at hour 60
		b("postgres", "18.9", mac, 1, 20),  // patch, held
		b("postgres", "19.0", mac, 1, 0),   // new line, approved for beta at hour 5 → stable at 53
		b("postgres", "19.1", mac, 1, 30),  // patch of 19, once 19.0 is stable
		b("node", "28.0.0", mac, 1, 0),     // new line, no decision: beta after 7 days (168 h)
		b("php", "8.6.0RC1", mac, 1, 0),    // pre-release, approved for stable anyway
		b("php", "8.6.0RC2", mac, 1, 5),
		b("php", "8.6.0", mac, 1, 10),   // the release after its RCs: a new line
		b("php", "8.4.26", mac, 1, -24), // baseline
		b("php", "8.4.26", mac, 2, 1),   // rebuild: new
		b("valkey", "9.1.2", "windows-x64", 1, -24),
		b("valkey", "9.2.0", "windows-x64", 1, 2), // new line, approved for beta, held
		b("mysql", "9.7.2", mac, 1, -24),
		b("mysql", "9.7.3", mac, 1, 1), // patch, approved for stable early
	}
	d := &channelDecisions{
		Baseline: base,
		Approved: map[string]approval{
			"postgres-19.0-build1-macos-arm64": {Beta: ptr(at(5))},
			"php-8.6.0RC1-build1-macos-arm64":  {Stable: ptr(at(1))},
			"valkey-9.2.0-build1-windows-x64":  {Beta: ptr(at(3))},
			"mysql-9.7.3-build1-macos-arm64":   {Stable: ptr(at(2))},
		},
		Hold: map[string]string{
			"postgres-18.9-build1-macos-arm64": "waiting for a fix",
			"valkey-9.2.0-build1-windows-x64":  "needs more testing",
		},
		Yanked: map[string]string{"php-8.4.26-build2-macos-arm64": "broken"},
	}

	cases := []struct {
		now  int
		key  string
		kind string
		want level
	}{
		{60, "postgres-18.6-build1-macos-arm64", "baseline", stable},
		{60, "postgres-18.7-build1-macos-arm64", "patch", stable},
		{60, "postgres-18.8-build1-macos-arm64", "patch", beta},
		{60, "postgres-18.9-build1-macos-arm64", "patch", beta},
		{20, "postgres-19.0-build1-macos-arm64", "new", beta},
		{60, "postgres-19.0-build1-macos-arm64", "new", stable},
		{20, "postgres-19.1-build1-macos-arm64", "new", experimental}, // 19.0 not stable yet: a new line still
		{100, "postgres-19.1-build1-macos-arm64", "patch", stable},    // 19.0 stable, 19.1 older than 48 h
		{100, "node-28.0.0-build1-macos-arm64", "new", experimental},
		{168, "node-28.0.0-build1-macos-arm64", "new", beta},
		{1000, "node-28.0.0-build1-macos-arm64", "new", beta}, // automatic beta never becomes stable
		{1000, "php-8.6.0RC1-build1-macos-arm64", "prerelease", beta},
		{1000, "php-8.6.0RC2-build1-macos-arm64", "prerelease", beta},
		{20, "php-8.6.0-build1-macos-arm64", "new", experimental},
		{1000, "php-8.4.26-build1-macos-arm64", "baseline", stable},
		{10, "php-8.4.26-build2-macos-arm64", "new", experimental},
		{1000, "valkey-9.2.0-build1-windows-x64", "new", beta}, // approved, but held before stable
		{3, "mysql-9.7.3-build1-macos-arm64", "patch", stable},
	}
	for _, c := range cases {
		var got *placed
		for _, p := range place(builds, d, 48*time.Hour, 7*24*time.Hour, at(c.now)) {
			if p.key() == c.key {
				p := p
				got = &p
			}
		}
		if got == nil {
			t.Fatalf("%s: not placed", c.key)
		}
		if got.Kind != c.kind || got.Level != c.want {
			t.Errorf("hour %d %s: %s/%s (%s), want %s/%s", c.now, c.key, got.Kind, channelNames[got.Level], got.Why, c.kind, channelNames[c.want])
		}
	}
}

func TestChannelManifest(t *testing.T) {
	now := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	p := func(build int, l level, yanked string) placed {
		return placed{published: published{Package: "php", Version: "8.4.26", Platform: "macos-arm64", Build: build,
			Asset: asset{Name: "a" + string(rune('0'+build)), BrowserDownloadURL: "u"}}, Level: l, Yanked: yanked}
	}
	v := &versions{}
	v.Manifest.ExpiresDays = 30
	get := func(all []placed, l level) (entry, bool) {
		e, ok := channelManifest(all, l, now, v).Packages["php"]["8.4.26"]["macos-arm64"]
		return e, ok
	}

	// A rebuild in experimental: stable and beta keep build 1, experimental gets build 2.
	all := []placed{p(1, stable, ""), p(2, experimental, "")}
	if e, _ := get(all, stable); e.Build != 1 {
		t.Errorf("stable: build %d, want 1", e.Build)
	}
	if e, _ := get(all, experimental); e.Build != 2 {
		t.Errorf("experimental: build %d, want 2", e.Build)
	}
	// Build 2 yanked: every channel lists build 1, and experimental notes the yank.
	all = []placed{p(1, stable, ""), p(2, stable, "broken")}
	e, _ := get(all, stable)
	if e.Build != 1 || e.Yanked["2"] != "broken" {
		t.Errorf("yanked build 2: got build %d, yanked %v", e.Build, e.Yanked)
	}
	// The only build yanked: still listed, so whoever installed it gets the warning.
	all = []placed{p(1, stable, "broken")}
	if e, ok := get(all, stable); !ok || e.Build != 1 || e.Yanked["1"] != "broken" {
		t.Errorf("only build yanked: got %+v", e)
	}
	// Not in a channel above its level.
	all = []placed{p(1, beta, "")}
	if _, ok := get(all, stable); ok {
		t.Error("a beta build is in stable")
	}
	if m := channelManifest(all, beta, now, v); m.Channel != "beta" {
		t.Errorf("channel %q", m.Channel)
	}
	// LTS comes from the build's release.
	lts := p(1, stable, "")
	lts.LTS = true
	if e, _ := get([]placed{lts}, stable); !e.LTS {
		t.Error("LTS release: entry not marked LTS")
	}
	if e, _ := get([]placed{p(1, stable, "")}, stable); e.LTS {
		t.Error("release without LTS: entry marked LTS")
	}
}

func TestReleaseInfo(t *testing.T) {
	for data, want := range map[string]bool{
		`{"lts":"Krypton"}`: true,
		`{"lts":false}`:     false,
		`{"lts":""}`:        false,
		`{}`:                false,
	} {
		var info releaseInfo
		if err := json.Unmarshal([]byte(data), &info); err != nil {
			t.Fatal(err)
		}
		if got := info.isLTS(); got != want {
			t.Errorf("%s: LTS %v, want %v", data, got, want)
		}
	}
}

func TestLineOf(t *testing.T) {
	v := &versions{Packages: map[string]pkgConfig{"redis": {Lines: []string{"8.4", "8.10"}}, "node": {Lines: []string{"22"}}}}
	for _, c := range [][3]string{
		{"php", "8.6.0RC1", "8.6"}, {"frankenphp", "8.4.26", "8.4"}, {"php-exts", "8.4", "8.4"},
		{"redis", "8.10.2", "8.10"}, {"redis", "8.4.7", "8.4"}, {"node", "22.23.3", "22"},
		{"redis", "8.12.0", "8.12"}, // not configured yet
	} {
		if got := lineOf(v, c[0], c[1]); got != c[2] {
			t.Errorf("lineOf(%s, %s) = %s, want %s", c[0], c[1], got, c[2])
		}
	}
}

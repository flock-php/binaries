package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

// versions mirrors versions.json, the single place where what we build is pinned.
type versions struct {
	// PHP is configured per platform: which minors, and how each is built or mirrored.
	PHP struct {
		MacOS struct {
			Minors           []string `json:"minors"`
			Build            int      `json:"build"`
			SPC              string   `json:"spc"`
			MinOS            string   `json:"min_os"`
			StaticExtensions string   `json:"static_extensions"`
			SharedExtensions string   `json:"shared_extensions"`
		} `json:"macos"`
		// Linux is built like macOS, for linux-x64 and linux-arm64 (glibc, so ext/ loads).
		Linux struct {
			Minors           []string `json:"minors"`
			Build            int      `json:"build"`
			SPC              string   `json:"spc"`
			StaticExtensions string   `json:"static_extensions"`
			SharedExtensions string   `json:"shared_extensions"`
		} `json:"linux"`
		// Windows mirrors the official thread-safe x64 builds from windows.php.net.
		Windows struct {
			Build  int      `json:"build"`
			Minors []string `json:"minors"`
			// Extensions are one pack per minor (php-exts-<minor>), rebuilt by raising build.
			Extensions struct {
				Build      int `json:"build"`
				FromSource map[string]struct {
					Repo string            `json:"repo"`
					Ref  string            `json:"ref"`
					Refs map[string]string `json:"refs"`
					// MinPHP leaves the extension out of the packs of older minors (opentelemetry: 8.0).
					MinPHP string `json:"min_php"`
				} `json:"from_source"`
				MongoDB string `json:"mongodb"`
			} `json:"extensions"`
		} `json:"windows"`
	} `json:"php"`
	// FrankenPHP is built per PHP version, like PHP: frankenphp-<php version>.
	FrankenPHP struct {
		Version string   `json:"version"`
		Minors  []string `json:"minors"`
		MacOS   struct {
			Build int `json:"build"`
		} `json:"macos"`
		Windows struct {
			Build int `json:"build"`
		} `json:"windows"`
		Linux struct {
			Build int `json:"build"`
		} `json:"linux"`
	} `json:"frankenphp"`
	// Packages are the services next to PHP: for each release line, the newest upstream
	// version is built from source or mirrored, per platform.
	Packages map[string]pkgConfig `json:"packages"`
	Manifest struct {
		ExpiresDays int `json:"expires_days"`
	} `json:"manifest"`
	// Channels holds the timers of the channel rules (channels.go).
	Channels struct {
		PatchHours    int `json:"patch_hours"`
		BetaAfterDays int `json:"beta_after_days"`
	} `json:"channels"`
}

type pkgConfig struct {
	Lines     []string                  `json:"lines"`
	Platforms map[string]platformConfig `json:"platforms"`
	Env       map[string]string         `json:"env"`
	// PublishSource also uploads the upstream source tarball to the release (GPL, SSPL, AGPL).
	PublishSource bool `json:"publish_source"`
	// Postgres makes the package a PostgreSQL extension: the majors it is built for, each a
	// package of its own (<name>-pg<major>, e.g. postgis-pg18), built against the postgres
	// package of that major (build-pg-extension.yml).
	Postgres []string `json:"postgres"`
}

type platformConfig struct {
	How   string `json:"how"` // "build" from source, or "mirror" the upstream binaries
	Build int    `json:"build"`
	// Postgres replaces the extension's majors on this platform, where upstream has fewer.
	Postgres []string `json:"postgres"`
}

// majors are the PostgreSQL majors an extension is built for on a platform.
func (p pkgConfig) majors(platform string) []string {
	if c, ok := p.Platforms[platform]; ok && c.Postgres != nil {
		return c.Postgres
	}
	return p.Postgres
}

// extensionPackage splits an extension's package name: postgis-pg18 → postgis, 18.
var extensionPackage = regexp.MustCompile(`^(.+)-pg(\d+)$`)

// configOf returns the versions.json entry a published package comes from: its own, or for an
// extension's package (postgis-pg18) the extension's (postgis).
func (v *versions) configOf(pkg string) (name string, p pkgConfig, ok bool) {
	if p, ok := v.Packages[pkg]; ok {
		return pkg, p, true
	}
	if m := extensionPackage.FindStringSubmatch(pkg); m != nil {
		if p, ok := v.Packages[m[1]]; ok && len(p.Postgres) > 0 {
			return m[1], p, true
		}
	}
	return "", pkgConfig{}, false
}

// platforms are the platforms packages are published for, in the order they are planned.
var platforms = []string{"macos-arm64", "windows-x64", "linux-x64", "linux-arm64"}

// linuxPlatforms are the platforms PHP and FrankenPHP are built for on Linux.
var linuxPlatforms = []string{"linux-x64", "linux-arm64"}

var platformExt = map[string]string{"macos-arm64": "tar.gz", "windows-x64": "zip", "linux-x64": "tar.gz", "linux-arm64": "tar.gz"}

func loadVersions(path string) (*versions, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var v versions
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, err
	}
	return &v, v.check()
}

func (v *versions) check() error {
	if v.Channels.PatchHours < 1 || v.Channels.BetaAfterDays < 1 {
		return fmt.Errorf("versions.json: channels.patch_hours and channels.beta_after_days must be set")
	}
	for name, p := range v.Packages {
		if _, ok := latestFuncs[name]; !ok {
			return fmt.Errorf("versions.json: no version lookup for package %q", name)
		}
		if len(p.Lines) == 0 {
			return fmt.Errorf("versions.json: %s has no lines", name)
		}
		for platform, c := range p.Platforms {
			if platformExt[platform] == "" {
				return fmt.Errorf("versions.json: %s: unknown platform %q", name, platform)
			}
			if c.How != "build" && c.How != "mirror" {
				return fmt.Errorf("versions.json: %s %s: how must be build or mirror", name, platform)
			}
			if c.Build < 1 {
				return fmt.Errorf("versions.json: %s %s: build must be >= 1", name, platform)
			}
			if len(p.majors(platform)) > 0 && c.How != "build" {
				return fmt.Errorf("versions.json: %s %s: an extension is built (or repackaged) against Flock's postgres, how must be build", name, platform)
			}
		}
	}
	return nil
}

// packageNames returns the configured packages, sorted.
func (v *versions) packageNames() []string {
	names := make([]string, 0, len(v.Packages))
	for name := range v.Packages {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// inLine reports whether version belongs to a release line: 8.4.6 to 8.4, 22.23.3 to 22.
func inLine(version, line string) bool {
	return version == line || strings.HasPrefix(version, line+".")
}

func (v *versions) patchWait() time.Duration { return time.Duration(v.Channels.PatchHours) * time.Hour }
func (v *versions) betaWait() time.Duration {
	return time.Duration(v.Channels.BetaAfterDays) * 24 * time.Hour
}

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// versions mirrors versions.json, the single place where what we build is pinned.
type versions struct {
	PHP struct {
		Minors []string `json:"minors"`
		MacOS  struct {
			Build            int    `json:"build"`
			SPC              string `json:"spc"`
			MinOS            string `json:"min_os"`
			StaticExtensions string `json:"static_extensions"`
			SharedExtensions string `json:"shared_extensions"`
		} `json:"macos"`
	} `json:"php"`
	// Packages are the services next to PHP: for each release line, the newest upstream
	// version is built from source or mirrored, per platform.
	Packages map[string]pkgConfig `json:"packages"`
	Manifest struct {
		ExpiresDays int `json:"expires_days"`
	} `json:"manifest"`
}

type pkgConfig struct {
	Lines     []string                  `json:"lines"`
	Platforms map[string]platformConfig `json:"platforms"`
	Env       map[string]string         `json:"env"`
	// PublishSource also uploads the upstream source tarball to the release (GPL, SSPL, AGPL).
	PublishSource bool `json:"publish_source"`
}

type platformConfig struct {
	How   string `json:"how"` // "build" from source, or "mirror" the upstream binaries
	Build int    `json:"build"`
}

var platformExt = map[string]string{"macos-arm64": "tar.gz", "windows-x64": "zip"}

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

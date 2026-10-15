package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
)

// build is one package version to build (or mirror) for one platform.
type build struct {
	Package  string `json:"package"`
	Version  string `json:"version"`
	Platform string `json:"platform"`
	Build    int    `json:"build"`
}

// runPlan prints, and writes to $GITHUB_OUTPUT, the builds whose release asset doesn't exist yet:
//
//	php_macos=[{"package":"php","version":"8.4.26","platform":"macos-arm64","build":1}, ...]
//	builds=[{"package":"postgres","version":"18.6","platform":"windows-x64","build":1}, ...]
//	mirrors=[{"package":"mysql","version":"8.4.11","platform":"macos-arm64","build":1}, ...]
//	any=true|false
//
// A package whose upstream versions can't be looked up is reported (a workflow warning) and
// skipped; the other packages are still planned.
func runPlan(args []string) error {
	fs := flag.NewFlagSet("plan", flag.ExitOnError)
	versionsPath := fs.String("versions", "versions.json", "versions file")
	repo := fs.String("repo", os.Getenv("GITHUB_REPOSITORY"), "owner/name of the binaries repository")
	only := fs.String("php", "", "comma-separated PHP versions to plan instead of the newest of each minor")
	pkgs := fs.String("packages", "", "comma-separated packages to plan (default all; \"php\" is PHP)")
	fs.Parse(args)

	v, err := loadVersions(*versionsPath)
	if err != nil {
		return err
	}
	selected := func(name string) bool {
		return *pkgs == "" || strings.Contains(","+*pkgs+",", ","+name+",")
	}
	releases, err := listReleases(*repo)
	if err != nil {
		return err
	}
	newest := map[string]int{} // "<tag> <platform>" → highest published build
	for _, r := range releases {
		for _, a := range r.Assets {
			if n, platform, ok := parseAsset(r.TagName, a.Name); ok {
				key := r.TagName + " " + platform
				newest[key] = max(newest[key], n)
			}
		}
	}
	// needed reports whether b isn't published yet, and logs the decision.
	needed := func(b build) bool {
		name := assetName(b.Package, b.Version, b.Build, b.Platform, platformExt[b.Platform])
		if newest[b.Package+"-"+b.Version+" "+b.Platform] >= b.Build {
			fmt.Fprintf(os.Stderr, "published  %s\n", name)
			return false
		}
		fmt.Fprintf(os.Stderr, "to build   %s\n", name)
		return true
	}

	phpMacOS := []build{}
	if selected("php") {
		var phpVersions []string
		if *only != "" {
			phpVersions = strings.Split(*only, ",")
		} else {
			for _, minor := range v.PHP.Minors {
				latest, err := latestPHP(minor)
				if err != nil {
					return err
				}
				phpVersions = append(phpVersions, latest)
			}
		}
		for _, ver := range phpVersions {
			b := build{Package: "php", Version: strings.TrimSpace(ver), Platform: "macos-arm64", Build: v.PHP.MacOS.Build}
			if needed(b) {
				phpMacOS = append(phpMacOS, b)
			}
		}
	}

	builds, mirrors := []build{}, []build{}
	for _, name := range v.packageNames() {
		if !selected(name) {
			continue
		}
		p := v.Packages[name]
		vers, problems := latestVersions(name, p)
		for _, msg := range problems {
			fmt.Fprintf(os.Stderr, "::warning::%s\n", msg)
		}
		for _, ver := range vers {
			for _, platform := range []string{"macos-arm64", "windows-x64"} {
				c, ok := p.Platforms[platform]
				if !ok {
					continue
				}
				b := build{Package: name, Version: ver, Platform: platform, Build: c.Build}
				if !needed(b) {
					continue
				}
				if c.How == "build" {
					builds = append(builds, b)
				} else {
					mirrors = append(mirrors, b)
				}
			}
		}
	}

	var out strings.Builder
	for _, o := range []struct {
		name string
		list []build
	}{{"php_macos", phpMacOS}, {"builds", builds}, {"mirrors", mirrors}} {
		j, _ := json.Marshal(o.list)
		fmt.Fprintf(&out, "%s=%s\n", o.name, j)
	}
	fmt.Fprintf(&out, "any=%t\n", len(phpMacOS)+len(builds)+len(mirrors) > 0)
	fmt.Print(out.String())
	if path := os.Getenv("GITHUB_OUTPUT"); path != "" {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = f.WriteString(out.String())
		return err
	}
	return nil
}

// latestPHP returns the newest release of a PHP minor according to php.net.
func latestPHP(minor string) (string, error) {
	var r struct {
		Version string `json:"version"`
	}
	if err := getJSON("https://www.php.net/releases/index.php?json&version="+minor, &r); err != nil {
		return "", err
	}
	if !strings.HasPrefix(r.Version, minor+".") {
		return "", fmt.Errorf("php.net returned %q for PHP %s", r.Version, minor)
	}
	return r.Version, nil
}

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
//	php_macos=[{"package":"php","version":"8.4.26","platform":"macos-arm64","build":1}, ...]   (php and frankenphp)
//	php_exts_windows=[{"package":"php-exts","version":"8.4","platform":"windows-x64","build":1}, ...]
//	frankenphp_windows=[{"package":"frankenphp","version":"8.4.26","platform":"windows-x64","build":1}, ...]
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
	pkgs := fs.String("packages", "", "comma-separated packages to plan (default all; also \"php\", \"php-exts\" and \"frankenphp\")")
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

	phpMacOS, phpExtsWindows, frankenWindows := []build{}, []build{}, []build{}
	builds, mirrors := []build{}, []build{}

	// PHP versions per minor: php.net for macOS (built from source), windows.php.net for Windows
	// (mirrored, and the base of the extension packs and FrankenPHP), which can trail by a day.
	macOSPHP := map[string]string{}
	macOSVersion := func(minor string) (string, error) {
		if v, ok := macOSPHP[minor]; ok {
			return v, nil
		}
		latest, err := latestPHP(minor)
		macOSPHP[minor] = latest
		return latest, err
	}
	var windowsPHP map[string]string
	if selected("php") || selected("php-exts") || selected("frankenphp") {
		var minors []string
		minors = append(minors, v.PHP.Windows.Minors...)
		minors = append(minors, v.FrankenPHP.Minors...)
		if windowsPHP, err = latestWindowsPHP(minors); err != nil {
			fmt.Fprintf(os.Stderr, "::warning::php windows: %v\n", err)
		}
	}
	windowsVersion := func(minor string) (string, bool) {
		ver, ok := windowsPHP[minor]
		if !ok && windowsPHP != nil {
			fmt.Fprintf(os.Stderr, "::warning::php windows: no build of PHP %s on windows.php.net\n", minor)
		}
		return ver, ok
	}

	if selected("php") {
		var phpVersions []string
		if *only != "" {
			phpVersions = strings.Split(*only, ",")
		} else {
			for _, minor := range v.PHP.MacOS.Minors {
				latest, err := macOSVersion(minor)
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
		if *only == "" {
			for _, minor := range v.PHP.Windows.Minors {
				if ver, ok := windowsVersion(minor); ok {
					if b := (build{Package: "php", Version: ver, Platform: "windows-x64", Build: v.PHP.Windows.Build}); needed(b) {
						mirrors = append(mirrors, b)
					}
				}
			}
		}
	}

	// Extension packs for Windows PHP: one per minor, independent of the patch release.
	if selected("php-exts") {
		for _, minor := range v.PHP.Windows.Minors {
			if b := (build{Package: "php-exts", Version: minor, Platform: "windows-x64", Build: v.PHP.Windows.Extensions.Build}); needed(b) {
				phpExtsWindows = append(phpExtsWindows, b)
			}
		}
	}

	// FrankenPHP embeds PHP, so it is built per PHP version on both platforms.
	if selected("frankenphp") && *only == "" {
		for _, minor := range v.FrankenPHP.Minors {
			latest, err := macOSVersion(minor)
			if err != nil {
				return err
			}
			if b := (build{Package: "frankenphp", Version: latest, Platform: "macos-arm64", Build: v.FrankenPHP.MacOS.Build}); needed(b) {
				phpMacOS = append(phpMacOS, b)
			}
			if ver, ok := windowsVersion(minor); ok {
				if b := (build{Package: "frankenphp", Version: ver, Platform: "windows-x64", Build: v.FrankenPHP.Windows.Build}); needed(b) {
					frankenWindows = append(frankenWindows, b)
				}
			}
		}
	}

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
	}{{"php_macos", phpMacOS}, {"php_exts_windows", phpExtsWindows}, {"frankenphp_windows", frankenWindows}, {"builds", builds}, {"mirrors", mirrors}} {
		j, _ := json.Marshal(o.list)
		fmt.Fprintf(&out, "%s=%s\n", o.name, j)
	}
	fmt.Fprintf(&out, "any=%t\n", len(phpMacOS)+len(phpExtsWindows)+len(frankenWindows)+len(builds)+len(mirrors) > 0)
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

// latestWindowsPHP returns the version of each minor that windows.php.net's releases.json lists
// a build for.
func latestWindowsPHP(minors []string) (map[string]string, error) {
	var r map[string]struct {
		Version string `json:"version"`
	}
	if err := getJSON("https://downloads.php.net/~windows/releases/releases.json", &r); err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, minor := range minors {
		if e, ok := r[minor]; ok && inLine(e.Version, minor) {
			out[minor] = e.Version
		}
	}
	return out, nil
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

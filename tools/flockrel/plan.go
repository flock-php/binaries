package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
)

// build is one package version to build for one platform.
type build struct {
	Package  string `json:"package"`
	Version  string `json:"version"`
	Platform string `json:"platform"`
	Build    int    `json:"build"`
}

// runPlan prints, and writes to $GITHUB_OUTPUT, the builds whose release asset doesn't exist yet:
//
//	php_macos=[{"package":"php","version":"8.4.26","platform":"macos-arm64","build":1}, ...]
//	any=true|false
func runPlan(args []string) error {
	fs := flag.NewFlagSet("plan", flag.ExitOnError)
	versionsPath := fs.String("versions", "versions.json", "versions file")
	repo := fs.String("repo", os.Getenv("GITHUB_REPOSITORY"), "owner/name of the binaries repository")
	only := fs.String("php", "", "comma-separated PHP versions to plan instead of the newest of each minor")
	fs.Parse(args)

	v, err := loadVersions(*versionsPath)
	if err != nil {
		return err
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

	phpMacOS := []build{}
	for _, ver := range phpVersions {
		b := build{Package: "php", Version: strings.TrimSpace(ver), Platform: "macos-arm64", Build: v.PHP.MacOS.Build}
		name := assetName(b.Package, b.Version, b.Build, b.Platform, "tar.gz")
		if newest[b.Package+"-"+b.Version+" "+b.Platform] >= b.Build {
			fmt.Fprintf(os.Stderr, "published  %s\n", name)
			continue
		}
		fmt.Fprintf(os.Stderr, "to build   %s\n", name)
		phpMacOS = append(phpMacOS, b)
	}

	matrix, _ := json.Marshal(phpMacOS)
	out := fmt.Sprintf("php_macos=%s\nany=%t\n", matrix, len(phpMacOS) > 0)
	fmt.Print(out)
	if path := os.Getenv("GITHUB_OUTPUT"); path != "" {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = f.WriteString(out)
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

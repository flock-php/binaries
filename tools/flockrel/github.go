package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 5 * time.Minute}

type release struct {
	TagName     string    `json:"tag_name"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	PublishedAt time.Time `json:"published_at"`
	Assets      []asset   `json:"assets"`
}

type asset struct {
	Name               string `json:"name"`
	Size               int64  `json:"size"`
	Digest             string `json:"digest"` // "sha256:<hex>"
	BrowserDownloadURL string `json:"browser_download_url"`
}

// listReleases returns every published release of repo.
func listReleases(repo string) ([]release, error) {
	var all []release
	for page := 1; ; page++ {
		var batch []release
		url := fmt.Sprintf("https://api.github.com/repos/%s/releases?per_page=100&page=%d", repo, page)
		if err := getJSON(url, &batch); err != nil {
			return nil, err
		}
		for _, r := range batch {
			if !r.Draft {
				all = append(all, r)
			}
		}
		if len(batch) < 100 {
			return all, nil
		}
	}
}

func getJSON(url string, v any) error {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if tok := os.Getenv("GITHUB_TOKEN"); tok != "" && strings.HasPrefix(url, "https://api.github.com/") {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("GET %s: %s: %s", url, resp.Status, body)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// sha256Of returns the asset's SHA-256, from GitHub's digest when present, otherwise by downloading it.
func sha256Of(a asset) (string, error) {
	if d, ok := strings.CutPrefix(a.Digest, "sha256:"); ok && len(d) == 64 {
		return d, nil
	}
	resp, err := httpClient.Get(a.BrowserDownloadURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GET %s: %s", a.BrowserDownloadURL, resp.Status)
	}
	h := sha256.New()
	if _, err := io.Copy(h, resp.Body); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// tagPattern splits a release tag into package and version: php-8.4.26 → php, 8.4.26.
var tagPattern = regexp.MustCompile(`^([a-z][a-z0-9]*(?:-[a-z][a-z0-9]*)*)-(\d[0-9A-Za-z.+]*)$`)

// assetPlatform returns the platform part of <tag>-<platform>.<ext>, or "" for other files.
func assetPlatform(tag, name string) string {
	rest, ok := strings.CutPrefix(name, tag+"-")
	if !ok {
		return ""
	}
	for _, ext := range []string{".tar.gz", ".zip"} {
		if p, ok := strings.CutSuffix(rest, ext); ok && p != "" {
			return p
		}
	}
	return ""
}

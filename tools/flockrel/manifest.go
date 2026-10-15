package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// manifest is what Flock downloads: every published package, signed as a whole.
// Flock rejects a manifest whose signature doesn't verify, that has expired, or whose serial
// is lower than the last one it accepted (so an old manifest can't be replayed).
type manifest struct {
	Schema    int                                    `json:"schema"`
	Serial    int64                                  `json:"serial"`
	Generated time.Time                              `json:"generated"`
	Expires   time.Time                              `json:"expires"`
	Packages  map[string]map[string]map[string]entry `json:"packages"` // package → version → platform
}

type entry struct {
	URL       string    `json:"url"`
	SHA256    string    `json:"sha256"`
	Size      int64     `json:"size"`
	Published time.Time `json:"published"`
}

func runManifest(args []string) error {
	fs := flag.NewFlagSet("manifest", flag.ExitOnError)
	versionsPath := fs.String("versions", "versions.json", "versions file")
	repo := fs.String("repo", os.Getenv("GITHUB_REPOSITORY"), "owner/name of the binaries repository")
	outDir := fs.String("out", ".", "directory for manifest.json and manifest.json.sig")
	fs.Parse(args)

	key, err := signingKey()
	if err != nil {
		return err
	}
	v, err := loadVersions(*versionsPath)
	if err != nil {
		return err
	}
	releases, err := listReleases(*repo)
	if err != nil {
		return err
	}

	now := time.Now().UTC().Truncate(time.Second)
	m := manifest{
		Schema:    1,
		Serial:    now.Unix(),
		Generated: now,
		Expires:   now.AddDate(0, 0, v.Manifest.ExpiresDays),
		Packages:  map[string]map[string]map[string]entry{},
	}
	sort.Slice(releases, func(i, j int) bool { return releases[i].TagName < releases[j].TagName })
	for _, r := range releases {
		parts := tagPattern.FindStringSubmatch(r.TagName)
		if parts == nil || r.Prerelease {
			continue
		}
		pkg, ver := parts[1], parts[2]
		for _, a := range r.Assets {
			platform := assetPlatform(r.TagName, a.Name)
			if platform == "" {
				continue
			}
			sum, err := sha256Of(a)
			if err != nil {
				return fmt.Errorf("%s: %w", a.Name, err)
			}
			if m.Packages[pkg] == nil {
				m.Packages[pkg] = map[string]map[string]entry{}
			}
			if m.Packages[pkg][ver] == nil {
				m.Packages[pkg][ver] = map[string]entry{}
			}
			m.Packages[pkg][ver][platform] = entry{URL: a.BrowserDownloadURL, SHA256: sum, Size: a.Size, Published: r.PublishedAt}
			fmt.Fprintf(os.Stderr, "%s %s %s\n", pkg, ver, platform)
		}
	}

	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(key, data)) + "\n"
	if err := os.WriteFile(filepath.Join(*outDir, "manifest.json"), data, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(*outDir, "manifest.json.sig"), []byte(sig), 0o644)
}

// runVerify checks manifest.json against manifest.json.sig with the public key, as Flock does.
func runVerify(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	pubPath := fs.String("pub", "manifest.pub", "base64 ed25519 public key file")
	fs.Parse(args)
	if fs.NArg() != 2 {
		return errors.New("usage: flockrel verify -pub manifest.pub manifest.json manifest.json.sig")
	}
	pub, err := readBase64(*pubPath, ed25519.PublicKeySize)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		return err
	}
	sig, err := readBase64(fs.Arg(1), ed25519.SignatureSize)
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), data, sig) {
		return errors.New("signature does not verify")
	}
	var m manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	if time.Now().After(m.Expires) {
		return fmt.Errorf("manifest expired %s", m.Expires)
	}
	n := 0
	for _, vers := range m.Packages {
		for _, plats := range vers {
			n += len(plats)
		}
	}
	fmt.Printf("ok: serial %d, %d packages, expires %s\n", m.Serial, n, m.Expires.Format(time.DateOnly))
	return nil
}

// runKeygen writes a new public key to -pub (manifest.pub here, and shipped in Flock) and prints
// only the private seed, so it can be piped straight into the MANIFEST_SIGNING_KEY secret:
//
//	flockrel keygen -pub manifest.pub | gh secret set MANIFEST_SIGNING_KEY --env release
func runKeygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	pubPath := fs.String("pub", "manifest.pub", "where to write the base64 public key")
	fs.Parse(args)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err := os.WriteFile(*pubPath, []byte(base64.StdEncoding.EncodeToString(pub)+"\n"), 0o644); err != nil {
		return err
	}
	fmt.Println(base64.StdEncoding.EncodeToString(priv.Seed()))
	return nil
}

func signingKey() (ed25519.PrivateKey, error) {
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(os.Getenv("MANIFEST_SIGNING_KEY")))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("MANIFEST_SIGNING_KEY must be a base64 ed25519 seed (flockrel keygen)")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func readBase64(path string, size int) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(b) != size {
		return nil, fmt.Errorf("%s: expected %d base64-encoded bytes", path, size)
	}
	return b, nil
}

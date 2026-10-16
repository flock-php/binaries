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
	"text/tabwriter"
	"time"
)

// manifest is what Flock downloads for its channel: the published packages of that channel,
// signed as a whole. Flock rejects a manifest whose signature doesn't verify, whose channel isn't
// the one it asked for, that has expired, or whose serial is lower than the last one it accepted
// for that channel (so an old manifest can't be replayed).
type manifest struct {
	Schema    int                                    `json:"schema"`
	Channel   string                                 `json:"channel"`
	Serial    int64                                  `json:"serial"`
	Generated time.Time                              `json:"generated"`
	Expires   time.Time                              `json:"expires"`
	Packages  map[string]map[string]map[string]entry `json:"packages"` // package → version → platform
}

// entry is the newest build of a package version for one platform in the channel. Flock replaces
// an installed package when the manifest has a higher build of the same version. Yanked lists
// builds of this version that were withdrawn (build number → reason): Flock doesn't install them
// and warns whoever has one installed. When every build is yanked, the entry is the newest one.
type entry struct {
	Build      int               `json:"build"`
	URL        string            `json:"url"`
	SHA256     string            `json:"sha256"`
	Size       int64             `json:"size"`
	Published  time.Time         `json:"published"`
	Prerelease bool              `json:"prerelease,omitempty"`
	Yanked     map[string]string `json:"yanked,omitempty"`

	assetName string // which release asset, for filling in SHA256
}

// manifestFiles are the channels' manifests: stable keeps the original name.
var manifestFiles = map[level]string{stable: "manifest.json", beta: "manifest-beta.json", experimental: "manifest-experimental.json"}

func runManifest(args []string) error {
	fs := flag.NewFlagSet("manifest", flag.ExitOnError)
	versionsPath := fs.String("versions", "versions.json", "versions file")
	channelsPath := fs.String("channels", "channels.json", "channel decisions: baseline, approvals, holds, yanks")
	repo := fs.String("repo", os.Getenv("GITHUB_REPOSITORY"), "owner/name of the binaries repository")
	outDir := fs.String("out", ".", "directory for the manifests and their signatures")
	dryRun := fs.Bool("dry-run", false, "print every build's channel instead of writing manifests")
	statusPath := fs.String("status", "", "also write the \"Ready for testing\" report here (empty: nothing pending), and the builds waiting for a decision to <file>.waiting")
	fs.Parse(args)

	var key ed25519.PrivateKey
	if !*dryRun {
		var err error
		if key, err = signingKey(); err != nil {
			return err
		}
	}
	v, err := loadVersions(*versionsPath)
	if err != nil {
		return err
	}
	d, err := loadDecisions(*channelsPath)
	if err != nil {
		return err
	}
	builds, err := publishedBuilds(*repo, v)
	if err != nil {
		return err
	}
	now := time.Now().UTC().Truncate(time.Second)
	all := place(builds, d, v.patchWait(), v.betaWait(), now)
	if *statusPath != "" {
		body, waiting := statusReport(all, *repo, now)
		if err := os.WriteFile(*statusPath, []byte(body), 0o644); err != nil {
			return err
		}
		w := strings.Join(waiting, "\n")
		if w != "" {
			w += "\n"
		}
		if err := os.WriteFile(*statusPath+".waiting", []byte(w), 0o644); err != nil {
			return err
		}
	}

	if *dryRun {
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "BUILD\tKIND\tCHANNEL\tWHY")
		for _, p := range all {
			why := p.Why
			if p.Yanked != "" {
				why += "; yanked: " + p.Yanked
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", p.key(), p.Kind, channelNames[p.Level], why)
		}
		w.Flush()
		for _, l := range []level{stable, beta, experimental} {
			fmt.Printf("%s: %d entries\n", manifestFiles[l], countEntries(channelManifest(all, l, now, v)))
		}
		return nil
	}

	sums := map[string]string{}
	for _, p := range all {
		sum, err := sha256Of(p.Asset)
		if err != nil {
			return fmt.Errorf("%s: %w", p.Asset.Name, err)
		}
		sums[p.Asset.Name] = sum
	}
	for _, l := range []level{stable, beta, experimental} {
		m := channelManifest(all, l, now, v)
		for _, plats := range m.Packages {
			for _, vers := range plats {
				for platform, e := range vers {
					e.SHA256 = sums[e.assetName]
					vers[platform] = e
				}
			}
		}
		data, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			return err
		}
		data = append(data, '\n')
		sig := base64.StdEncoding.EncodeToString(ed25519.Sign(key, data)) + "\n"
		name := filepath.Join(*outDir, manifestFiles[l])
		if err := os.WriteFile(name, data, 0o644); err != nil {
			return err
		}
		if err := os.WriteFile(name+".sig", []byte(sig), 0o644); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "%s: %d entries\n", manifestFiles[l], countEntries(m))
	}
	return nil
}

// channelManifest lists, for every package version and platform, the newest build at level l or
// above that isn't yanked (the newest yanked one when all are), with the yanked builds noted.
// SHA-256 sums are filled in by the caller.
func channelManifest(all []placed, l level, now time.Time, v *versions) manifest {
	m := manifest{
		Schema:    1,
		Channel:   channelNames[l],
		Serial:    now.Unix(),
		Generated: now,
		Expires:   now.AddDate(0, 0, v.Manifest.ExpiresDays),
		Packages:  map[string]map[string]map[string]entry{},
	}
	type slot struct{ pkg, ver, platform string }
	candidates := map[slot][]placed{}
	for _, p := range all {
		if p.Level >= l {
			s := slot{p.Package, p.Version, p.Platform}
			candidates[s] = append(candidates[s], p)
		}
	}
	for s, ps := range candidates {
		sort.Slice(ps, func(i, j int) bool { return ps[i].Build > ps[j].Build })
		chosen := ps[0]
		yanked := map[string]string{}
		for i := len(ps) - 1; i >= 0; i-- {
			if ps[i].Yanked != "" {
				yanked[fmt.Sprint(ps[i].Build)] = ps[i].Yanked
			} else {
				chosen = ps[i] // ends at the newest build that isn't yanked
			}
		}
		if len(yanked) == 0 {
			yanked = nil
		}
		if m.Packages[s.pkg] == nil {
			m.Packages[s.pkg] = map[string]map[string]entry{}
		}
		if m.Packages[s.pkg][s.ver] == nil {
			m.Packages[s.pkg][s.ver] = map[string]entry{}
		}
		a := chosen.Asset
		m.Packages[s.pkg][s.ver][s.platform] = entry{
			Build: chosen.Build, URL: a.BrowserDownloadURL, Size: a.Size, Published: a.CreatedAt,
			Prerelease: chosen.Prerelease, Yanked: yanked, assetName: a.Name,
		}
	}
	return m
}

func countEntries(m manifest) int {
	n := 0
	for _, vers := range m.Packages {
		for _, plats := range vers {
			n += len(plats)
		}
	}
	return n
}

// runVerify checks a manifest against its signature with the public key, as Flock does,
// including that it is the channel Flock asked for.
func runVerify(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	pubPath := fs.String("pub", "manifest.pub", "base64 ed25519 public key file")
	channel := fs.String("channel", "", "the channel the manifest must be (stable, beta, experimental); default any")
	fs.Parse(args)
	if fs.NArg() != 2 {
		return errors.New("usage: flockrel verify -pub manifest.pub [-channel stable] manifest.json manifest.json.sig")
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
	if *channel != "" && m.Channel != *channel {
		return fmt.Errorf("manifest is for channel %q, not %q", m.Channel, *channel)
	}
	if time.Now().After(m.Expires) {
		return fmt.Errorf("manifest expired %s", m.Expires)
	}
	fmt.Printf("ok: %s, serial %d, %d packages, expires %s\n", m.Channel, m.Serial, countEntries(m), m.Expires.Format(time.DateOnly))
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

// publishedBuilds lists every build on the releases: <package>-<version> tags with
// <package>-<version>-build<N>-<platform> assets.
func publishedBuilds(repo string, v *versions) ([]published, error) {
	releases, err := listReleases(repo)
	if err != nil {
		return nil, err
	}
	var builds []published
	for _, r := range releases {
		parts := tagPattern.FindStringSubmatch(r.TagName)
		if parts == nil || r.Prerelease {
			continue
		}
		pkg, ver := parts[1], parts[2]
		for _, a := range r.Assets {
			if n, platform, ok := parseAsset(r.TagName, a.Name); ok {
				builds = append(builds, published{Package: pkg, Version: ver, Platform: platform, Build: n, Line: lineOf(v, pkg, ver), Asset: a})
			}
		}
	}
	return builds, nil
}

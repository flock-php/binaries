package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestTagAndAssetNames(t *testing.T) {
	tags := map[string][2]string{
		"php-8.4.26":        {"php", "8.4.26"},
		"php-exts-8.4.26":   {"php-exts", "8.4.26"},
		"frankenphp-1.13.0": {"frankenphp", "1.13.0"},
		"valkey-9.1.2":      {"valkey", "9.1.2"},
	}
	for tag, want := range tags {
		got := tagPattern.FindStringSubmatch(tag)
		if got == nil || got[1] != want[0] || got[2] != want[1] {
			t.Errorf("%s: got %v, want %v", tag, got, want)
		}
	}
	if tagPattern.MatchString("manifest") {
		t.Error("manifest tag must not look like a package")
	}

	if got := assetName("php", "8.4.26", 2, "macos-arm64", "tar.gz"); got != "php-8.4.26-build2-macos-arm64.tar.gz" {
		t.Errorf("assetName: %s", got)
	}
	type parsed struct {
		build    int
		platform string
		ok       bool
	}
	assets := map[string]parsed{
		"php-8.4.26-build1-macos-arm64.tar.gz":  {1, "macos-arm64", true},
		"php-8.4.26-build12-windows-x64.zip":    {12, "windows-x64", true},
		"php-8.4.26-macos-arm64.tar.gz":         {},
		"php-8.4.26-build0-macos-arm64.tar.gz":  {},
		"php-8.4.26-build1-macos-arm64.tar.xz":  {},
		"php-8.4.2-build1-macos-arm64.tar.gz":   {},
		"php-8.4.266-build1-macos-arm64.tar.gz": {},
		"SHA256SUMS":                            {},
	}
	for name, want := range assets {
		n, platform, ok := parseAsset("php-8.4.26", name)
		if got := (parsed{n, platform, ok}); ok != want.ok || ok && got != want {
			t.Errorf("%s: got %+v, want %+v", name, got, want)
		}
	}
}

func TestSignAndVerify(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	t.Setenv("MANIFEST_SIGNING_KEY", base64.StdEncoding.EncodeToString(priv.Seed()))
	key, err := signingKey()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	data := []byte(`{"schema":1,"serial":1,"expires":"2999-01-01T00:00:00Z","packages":{}}`)
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(content), 0o644)
		return p
	}
	m := write("manifest.json", string(data))
	s := write("manifest.json.sig", base64.StdEncoding.EncodeToString(ed25519.Sign(key, data)))
	p := write("manifest.pub", base64.StdEncoding.EncodeToString(pub))
	if err := runVerify([]string{"-pub", p, m, s}); err != nil {
		t.Fatal(err)
	}
	write("manifest.json", string(data)+" ")
	if err := runVerify([]string{"-pub", p, m, s}); err == nil {
		t.Fatal("tampered manifest verified")
	}
}

// flockrel is the release tooling for Flock's binaries:
//
//	flockrel plan     -versions versions.json -repo owner/name   which packages still need building
//	flockrel manifest -versions versions.json -repo owner/name -out dir
//	                                                             manifest.json + manifest.json.sig from the releases
//	flockrel verify   -pub manifest.pub manifest.json manifest.json.sig
//	flockrel keygen   -pub manifest.pub                          new signing key: public to file, private to stdout
//
// Releases are tagged <package>-<version> and hold assets named <package>-<version>-<platform>.<ext>.
// GITHUB_TOKEN is used for the GitHub API when set; MANIFEST_SIGNING_KEY holds the base64
// ed25519 seed for signing.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch cmd, args := os.Args[1], os.Args[2:]; cmd {
	case "plan":
		err = runPlan(args)
	case "manifest":
		err = runManifest(args)
	case "verify":
		err = runVerify(args)
	case "keygen":
		err = runKeygen(args)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "flockrel:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: flockrel plan|manifest|verify|keygen [flags]")
	os.Exit(2)
}

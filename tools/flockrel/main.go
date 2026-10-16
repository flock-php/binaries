// flockrel is the release tooling for Flock's binaries:
//
//	flockrel plan     -versions versions.json -repo owner/name   which packages still need building
//	flockrel manifest -versions versions.json -channels channels.json -out dir [-status file] [-dry-run]
//	                                                             the three channel manifests (+ .sig) from the releases
//	flockrel decide   -action promote-beta -target postgres-19.0  record a channel decision in channels.json
//	flockrel verify   -pub manifest.pub [-channel stable] manifest.json manifest.json.sig
//	flockrel keygen   -pub manifest.pub                          new signing key: public to file, private to stdout
//
// Releases are tagged <package>-<version> and hold assets named <package>-<version>-build<N>-<platform>.<ext>;
// a higher build number is a rebuild of the same version (e.g. with a library security fix).
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
	case "decide":
		err = runDecide(args)
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
	fmt.Fprintln(os.Stderr, "usage: flockrel plan|manifest|decide|verify|keygen [flags]")
	os.Exit(2)
}

package main

import (
	"archive/zip"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
)

// upstreamFuncs find the version of an extension for one PostgreSQL major on a platform with an
// upstream of its own (platformConfig.Upstream).
var upstreamFuncs = map[string]func(extension, major string) (string, error){
	"osgeo-bundle": osgeoBundleVersion,
}

const osgeoWindows = "https://download.osgeo.org/postgis/windows/"

var osgeoBundle = regexp.MustCompile(`postgis-bundle-pg(\d+)-(\d+\.\d+\.\d+)x64\.zip"`)

// osgeoBundle finds OSGeo's current PostGIS bundle for Windows of a major: its version and URL.
// The folder of a major holds the current one; older ones are in archive/.
func osgeoCurrentBundle(major string) (version, url string, err error) {
	page, err := getText(osgeoWindows + "pg" + major + "/")
	if err != nil {
		return "", "", err
	}
	for _, m := range osgeoBundle.FindAllStringSubmatch(page, -1) {
		if m[1] == major && (version == "" || cmpVersion(m[2], version) > 0) {
			version = m[2]
		}
	}
	if version == "" {
		return "", "", fmt.Errorf("no PostGIS bundle for PostgreSQL %s on download.osgeo.org", major)
	}
	return version, fmt.Sprintf("%spg%s/postgis-bundle-pg%s-%sx64.zip", osgeoWindows, major, major, version), nil
}

var pgroutingSQL = regexp.MustCompile(`(?:^|/)pgrouting--(\d+\.\d+\.\d+)\.sql$`)

// osgeoBundleVersion is the version of PostGIS (the bundle's own) or pgRouting (which comes in the
// bundle, with its version only in its file names) in OSGeo's current bundle of a major. For
// pgRouting it reads the bundle's file list only, with range requests: bundles are ~120 MB.
func osgeoBundleVersion(extension, major string) (string, error) {
	version, url, err := osgeoCurrentBundle(major)
	if err != nil || extension == "postgis" {
		return version, err
	}
	if extension != "pgrouting" {
		return "", fmt.Errorf("OSGeo's bundle has no %s", extension)
	}
	files, err := remoteZipFiles(url)
	if err != nil {
		return "", err
	}
	for _, f := range files {
		if m := pgroutingSQL.FindStringSubmatch(f); m != nil {
			return m[1], nil
		}
	}
	return "", fmt.Errorf("no pgRouting in %s", url)
}

// remoteZipFiles lists the files of a zip archive on a server that answers range requests,
// reading its central directory only.
func remoteZipFiles(url string) ([]string, error) {
	resp, err := httpClient.Head(url)
	if err != nil {
		return nil, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.ContentLength <= 0 {
		return nil, fmt.Errorf("HEAD %s: %s", url, resp.Status)
	}
	r, err := zip.NewReader(rangeReader{url}, resp.ContentLength)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", url, err)
	}
	var names []string
	for _, f := range r.File {
		names = append(names, strings.ReplaceAll(f.Name, "\\", "/"))
	}
	return names, nil
}

// rangeReader reads a remote file with HTTP range requests.
type rangeReader struct{ url string }

func (r rangeReader) ReadAt(p []byte, off int64) (int, error) {
	req, err := http.NewRequest("GET", r.url, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", off, off+int64(len(p))-1))
	resp, err := httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return 0, fmt.Errorf("GET %s (range): %s", r.url, resp.Status)
	}
	n, err := io.ReadFull(resp.Body, p)
	if err == io.ErrUnexpectedEOF {
		err = io.EOF
	}
	return n, err
}

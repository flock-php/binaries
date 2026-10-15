package main

import (
	"encoding/json"
	"os"
)

// versions mirrors versions.json, the single place where what we build is pinned.
type versions struct {
	PHP struct {
		Minors []string `json:"minors"`
		MacOS  struct {
			SPC              string `json:"spc"`
			MinOS            string `json:"min_os"`
			StaticExtensions string `json:"static_extensions"`
			SharedExtensions string `json:"shared_extensions"`
		} `json:"macos"`
	} `json:"php"`
	Manifest struct {
		ExpiresDays int `json:"expires_days"`
	} `json:"manifest"`
}

func loadVersions(path string) (*versions, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var v versions
	return &v, json.Unmarshal(data, &v)
}

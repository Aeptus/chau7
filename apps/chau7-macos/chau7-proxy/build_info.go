package main

import "runtime/debug"

var (
	Version        = "dev"
	BuildSHA       = "unknown"
	BuildTimestamp = "unknown"
)

type ProxyBuildInfo struct {
	Version        string `json:"version"`
	BuildSHA       string `json:"build_sha"`
	BuildTimestamp string `json:"build_timestamp"`
	Modified       bool   `json:"modified"`
}

func currentProxyBuildInfo() ProxyBuildInfo {
	result := ProxyBuildInfo{Version: Version, BuildSHA: BuildSHA, BuildTimestamp: BuildTimestamp}
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return result
	}
	for _, setting := range info.Settings {
		switch setting.Key {
		case "vcs.revision":
			if result.BuildSHA == "unknown" {
				result.BuildSHA = setting.Value
			}
		case "vcs.time":
			if result.BuildTimestamp == "unknown" {
				result.BuildTimestamp = setting.Value
			}
		case "vcs.modified":
			result.Modified = setting.Value == "true"
		}
	}
	return result
}

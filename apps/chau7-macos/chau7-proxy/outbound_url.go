package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
)

type hostLookupFunc func(ctx context.Context, host string) ([]net.IPAddr, error)

var restrictedAddrPrefixes = mustParsePrefixes(
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.168.0.0/16",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
	"::/128",
	"::1/128",
	"fc00::/7",
	"fe80::/10",
	"ff00::/8",
	"2001:db8::/32",
)

// normalizeServiceBaseURL validates and canonicalizes an outbound service base
// URL used by optional integrations. We only allow:
// - absolute http/https URLs
// - no user info, query, or fragment
// - http only for explicit loopback/local development hosts
// - no private/reserved literal IPs
func normalizeServiceBaseURL(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil
	}

	parsed, err := url.Parse(trimmed)
	if err != nil {
		return "", fmt.Errorf("invalid URL: %w", err)
	}
	if !parsed.IsAbs() {
		return "", fmt.Errorf("URL must be absolute")
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("URL must include a host")
	}
	if parsed.User != nil {
		return "", fmt.Errorf("URL must not contain user info")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", fmt.Errorf("URL must not contain query or fragment")
	}

	scheme := strings.ToLower(parsed.Scheme)
	hostname := strings.ToLower(parsed.Hostname())
	if hostname == "" {
		return "", fmt.Errorf("URL must include a hostname")
	}

	switch scheme {
	case "https":
	case "http":
		if !isLoopbackHost(hostname) {
			return "", fmt.Errorf("http is only allowed for loopback hosts")
		}
	default:
		return "", fmt.Errorf("unsupported URL scheme %q", parsed.Scheme)
	}

	if ip := net.ParseIP(hostname); ip != nil {
		if err := validateResolvedHost(hostname, []net.IPAddr{{IP: ip}}); err != nil {
			return "", err
		}
	}

	parsed.Scheme = scheme
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""

	return strings.TrimRight(parsed.String(), "/"), nil
}

func isLoopbackHost(host string) bool {
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func buildServiceURL(baseURL, endpoint string) string {
	base, err := url.Parse(baseURL)
	if err != nil {
		return strings.TrimRight(baseURL, "/") + "/" + strings.TrimLeft(endpoint, "/")
	}
	if endpoint == "" {
		return strings.TrimRight(base.String(), "/")
	}
	if !strings.HasSuffix(base.Path, "/") {
		base.Path += "/"
	}
	ref := &url.URL{Path: strings.TrimLeft(endpoint, "/")}
	return strings.TrimRight(base.ResolveReference(ref).String(), "/")
}

func validateResolvedHost(host string, addrs []net.IPAddr) error {
	if len(addrs) == 0 {
		return fmt.Errorf("no addresses resolved for %s", host)
	}

	loopbackHost := isLoopbackHost(host)
	for _, addr := range addrs {
		if !isAllowedResolvedIP(loopbackHost, addr.IP) {
			return fmt.Errorf("resolved address %s is not allowed for host %s", addr.IP.String(), host)
		}
	}
	return nil
}

func isAllowedResolvedIP(loopbackHost bool, ip net.IP) bool {
	if ip == nil {
		return false
	}
	if loopbackHost {
		return ip.IsLoopback()
	}
	return !isRestrictedIP(ip)
}

func isRestrictedIP(ip net.IP) bool {
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return true
	}
	for _, prefix := range restrictedAddrPrefixes {
		if prefix.Contains(addr.Unmap()) {
			return true
		}
	}
	return false
}

func mustParsePrefixes(prefixes ...string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(prefixes))
	for _, prefix := range prefixes {
		parsed, err := netip.ParsePrefix(prefix)
		if err != nil {
			panic(err)
		}
		out = append(out, parsed)
	}
	return out
}

func newRestrictedHTTPClient(timeout time.Duration) *http.Client {
	return newRestrictedHTTPClientWithLookup(timeout, net.DefaultResolver.LookupIPAddr)
}

func newRestrictedHTTPClientWithLookup(timeout time.Duration, lookup hostLookupFunc) *http.Client {
	dialer := &net.Dialer{Timeout: timeout}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}

		addrs, err := lookup(ctx, host)
		if err != nil {
			return nil, err
		}
		if err := validateResolvedHost(host, addrs); err != nil {
			return nil, err
		}

		var lastErr error
		for _, addr := range addrs {
			if !isAllowedResolvedIP(isLoopbackHost(host), addr.IP) {
				continue
			}
			conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(addr.IP.String(), port))
			if err == nil {
				return conn, nil
			}
			lastErr = err
		}
		if lastErr != nil {
			return nil, lastErr
		}
		return nil, fmt.Errorf("no dialable addresses resolved for %s", host)
	}

	return &http.Client{
		Timeout:   timeout,
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

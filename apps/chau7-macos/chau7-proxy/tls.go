package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"time"
)

// ensureSelfSignedCert generates a self-signed TLS certificate for 127.0.0.1
// if one does not already exist at the given paths. The certificate is valid
// for 10 years and only covers localhost loopback — it exists solely to enable
// WSS (WebSocket Secure) transport for subscription-based Codex through the
// local proxy.
func ensureSelfSignedCert(certPath, keyPath string) error {
	// If both files already exist, nothing to do
	if pathExists(certPath) && pathExists(keyPath) {
		return nil
	}

	// Generate ECDSA P-256 key (fast, small)
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate key: %w", err)
	}

	// Serial number
	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("generate serial: %w", err)
	}

	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			Organization: []string{"Chau7 Local Proxy"},
			CommonName:   "127.0.0.1",
		},
		NotBefore: time.Now().Add(-1 * time.Hour), // backdate slightly
		NotAfter:  time.Now().Add(10 * 365 * 24 * time.Hour),

		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,

		// Only valid for loopback
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
		DNSNames:    []string{"localhost"},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return fmt.Errorf("create certificate: %w", err)
	}

	// Write certificate PEM
	certFile, err := os.Create(certPath)
	if err != nil {
		return fmt.Errorf("create cert file: %w", err)
	}
	defer func() { _ = certFile.Close() }()

	if err := pem.Encode(certFile, &pem.Block{Type: "CERTIFICATE", Bytes: certDER}); err != nil {
		return fmt.Errorf("encode cert: %w", err)
	}

	// Write private key PEM
	keyFile, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("create key file: %w", err)
	}
	defer func() { _ = keyFile.Close() }()

	keyDER, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		return fmt.Errorf("marshal key: %w", err)
	}

	if err := pem.Encode(keyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}); err != nil {
		return fmt.Errorf("encode key: %w", err)
	}

	return nil
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

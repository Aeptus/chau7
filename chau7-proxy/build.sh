#!/bin/bash
# build.sh - Cross-platform build script for chau7-proxy
#
# This script builds the Go proxy binary for multiple platforms.
# The binaries are self-contained with no external dependencies
# thanks to modernc.org/sqlite (pure Go SQLite).
#
# Usage:
#   ./build.sh              # Build for current platform only
#   ./build.sh all          # Build for all platforms
#   ./build.sh darwin       # Build for macOS (arm64 + amd64)
#   ./build.sh linux        # Build for Linux (amd64 + arm64)
#   ./build.sh windows      # Build for Windows (amd64)
#   ./build.sh test         # Run tests
#   ./build.sh clean        # Clean build artifacts

set -e

# Configuration
APP_NAME="chau7-proxy"
VERSION="${VERSION:-dev}"
BUILD_DIR="build"
LDFLAGS="-s -w -X main.Version=${VERSION}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check Go installation
check_go() {
    if ! command -v go &> /dev/null; then
        error "Go is not installed. Please install Go 1.21+ from https://go.dev/dl/"
    fi

    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    info "Using Go ${GO_VERSION}"
}

# Ensure dependencies are downloaded
deps() {
    info "Downloading dependencies..."
    go mod download
    go mod verify
}

# Build for current platform
build_current() {
    info "Building for current platform..."
    mkdir -p "${BUILD_DIR}"
    go build -ldflags "${LDFLAGS}" -o "${BUILD_DIR}/${APP_NAME}" .
    info "Built: ${BUILD_DIR}/${APP_NAME}"
}

# Build for macOS (Universal Binary)
build_darwin() {
    info "Building for macOS..."
    mkdir -p "${BUILD_DIR}/darwin"

    # Build for ARM64 (Apple Silicon)
    info "  Building darwin/arm64..."
    GOOS=darwin GOARCH=arm64 go build -ldflags "${LDFLAGS}" \
        -o "${BUILD_DIR}/darwin/${APP_NAME}-darwin-arm64" .

    # Build for AMD64 (Intel)
    info "  Building darwin/amd64..."
    GOOS=darwin GOARCH=amd64 go build -ldflags "${LDFLAGS}" \
        -o "${BUILD_DIR}/darwin/${APP_NAME}-darwin-amd64" .

    # Create Universal Binary (if lipo is available)
    if command -v lipo &> /dev/null; then
        info "  Creating Universal Binary..."
        lipo -create -output "${BUILD_DIR}/darwin/${APP_NAME}" \
            "${BUILD_DIR}/darwin/${APP_NAME}-darwin-arm64" \
            "${BUILD_DIR}/darwin/${APP_NAME}-darwin-amd64"
        info "Built: ${BUILD_DIR}/darwin/${APP_NAME} (Universal)"
    else
        warn "  lipo not available, skipping Universal Binary"
        # Copy ARM64 as default on macOS
        cp "${BUILD_DIR}/darwin/${APP_NAME}-darwin-arm64" "${BUILD_DIR}/darwin/${APP_NAME}"
    fi
}

# Build for Linux
build_linux() {
    info "Building for Linux..."
    mkdir -p "${BUILD_DIR}/linux"

    # Build for AMD64
    info "  Building linux/amd64..."
    GOOS=linux GOARCH=amd64 go build -ldflags "${LDFLAGS}" \
        -o "${BUILD_DIR}/linux/${APP_NAME}-linux-amd64" .

    # Build for ARM64
    info "  Building linux/arm64..."
    GOOS=linux GOARCH=arm64 go build -ldflags "${LDFLAGS}" \
        -o "${BUILD_DIR}/linux/${APP_NAME}-linux-arm64" .

    info "Built: ${BUILD_DIR}/linux/"
}

# Build for Windows
build_windows() {
    info "Building for Windows..."
    mkdir -p "${BUILD_DIR}/windows"

    # Build for AMD64
    info "  Building windows/amd64..."
    GOOS=windows GOARCH=amd64 go build -ldflags "${LDFLAGS}" \
        -o "${BUILD_DIR}/windows/${APP_NAME}-windows-amd64.exe" .

    info "Built: ${BUILD_DIR}/windows/${APP_NAME}-windows-amd64.exe"
}

# Build for all platforms
build_all() {
    build_darwin
    build_linux
    build_windows

    info "All builds complete!"
    ls -la "${BUILD_DIR}/"*/
}

# Run tests
run_tests() {
    info "Running tests..."
    go test -v -race -cover ./...
}

# Run tests with coverage
run_coverage() {
    info "Running tests with coverage..."
    go test -v -race -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out -o coverage.html
    info "Coverage report: coverage.html"
}

# Clean build artifacts
clean() {
    info "Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -f coverage.out coverage.html
    info "Clean complete"
}

# Install to Chau7 app bundle (development)
install_to_bundle() {
    local BUNDLE_PATH="../Chau7.app/Contents/Resources"

    if [ ! -d "${BUNDLE_PATH}" ]; then
        warn "Chau7.app not found at ${BUNDLE_PATH}"
        warn "Building Chau7 first or specify BUNDLE_PATH"
        return 1
    fi

    build_darwin
    cp "${BUILD_DIR}/darwin/${APP_NAME}" "${BUNDLE_PATH}/"
    chmod +x "${BUNDLE_PATH}/${APP_NAME}"
    info "Installed to ${BUNDLE_PATH}/${APP_NAME}"
}

# Print usage
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)       Build for current platform"
    echo "  all          Build for all platforms"
    echo "  darwin       Build for macOS (arm64 + amd64 + Universal)"
    echo "  linux        Build for Linux (amd64 + arm64)"
    echo "  windows      Build for Windows (amd64)"
    echo "  test         Run tests"
    echo "  coverage     Run tests with coverage report"
    echo "  clean        Clean build artifacts"
    echo "  install      Install to Chau7.app bundle (dev)"
    echo "  help         Show this help"
    echo ""
    echo "Environment variables:"
    echo "  VERSION      Version string (default: dev)"
}

# Main
main() {
    cd "$(dirname "$0")"

    check_go

    case "${1:-}" in
        "")
            deps
            build_current
            ;;
        "all")
            deps
            build_all
            ;;
        "darwin")
            deps
            build_darwin
            ;;
        "linux")
            deps
            build_linux
            ;;
        "windows")
            deps
            build_windows
            ;;
        "test")
            run_tests
            ;;
        "coverage")
            run_coverage
            ;;
        "clean")
            clean
            ;;
        "install")
            deps
            install_to_bundle
            ;;
        "help"|"-h"|"--help")
            usage
            ;;
        *)
            error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"

#!/usr/bin/env bash
# Verify that all required binaries and DLLs are present in the bundle
#
# Usage: ./scripts/verify-bundle.sh [--target TARGET] [--dir BIN_DIR]
#
# This script verifies that all required files are present after building
# the Elixir release and copying to Tauri resources.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Detect script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default directories
DEFAULT_PRIV_BIN="$REPO_ROOT/apps/leaxer_core/priv/bin"
DEFAULT_TAURI_BIN="$REPO_ROOT/apps/leaxer_desktop/src-tauri/resources/leaxer_core/lib/leaxer_core-0.1.0/priv/bin"

# Detect target platform
detect_target() {
    local os
    os="$(uname -s)"

    case "$os" in
        Darwin)
            if [[ "$(uname -m)" == "arm64" ]]; then
                echo "aarch64-apple-darwin"
            else
                echo "x86_64-apple-darwin"
            fi
            ;;
        Linux)
            echo "x86_64-unknown-linux-gnu"
            ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            echo "x86_64-pc-windows-msvc"
            ;;
        *)
            log_error "Unsupported OS: $os"
            exit 1
            ;;
    esac
}

# Get file extension for target
get_ext() {
    local target="$1"
    if [[ "$target" == *"windows"* ]]; then
        echo ".exe"
    else
        echo ""
    fi
}

# Check if file exists and log result
check_file() {
    local path="$1"
    local name="$2"
    local required="${3:-true}"

    if [[ -f "$path" ]]; then
        local size
        size=$(du -h "$path" 2>/dev/null | cut -f1 || echo "?")
        log_success "$name ($size)"
        return 0
    else
        if [[ "$required" == "true" ]]; then
            log_error "$name - MISSING (REQUIRED)"
            return 1
        else
            log_warn "$name - not found (optional)"
            return 0
        fi
    fi
}

# Main verification function
verify_bundle() {
    local target="$1"
    local bin_dir="$2"
    local ext
    ext=$(get_ext "$target")
    local errors=0

    echo ""
    log_info "=========================================="
    log_info "Bundle Verification"
    log_info "=========================================="
    log_info "Target: $target"
    log_info "Directory: $bin_dir"
    echo ""

    if [[ ! -d "$bin_dir" ]]; then
        log_error "Directory does not exist: $bin_dir"
        return 1
    fi

    # Critical executables - platform-specific naming
    # On macOS ARM, Metal versions are the primary binaries (no CPU-only builds)
    # On other platforms, CPU versions are primary with optional GPU variants
    log_info "--- Critical Executables ---"

    case "$target" in
        aarch64-apple-darwin)
            # macOS ARM: Metal binaries are primary (all Apple Silicon supports Metal)
            check_file "$bin_dir/llama-server-${target}-metal" "llama-server-metal" || ((errors++))
            check_file "$bin_dir/llama-cli-${target}-metal" "llama-cli-metal" || ((errors++))
            check_file "$bin_dir/sd-${target}-metal" "sd-metal" || ((errors++))
            ;;
        x86_64-apple-darwin)
            # macOS Intel: CPU binaries are primary
            check_file "$bin_dir/llama-server-${target}${ext}" "llama-server" || ((errors++))
            check_file "$bin_dir/llama-cli-${target}${ext}" "llama-cli" || ((errors++))
            check_file "$bin_dir/sd-${target}${ext}" "sd" || ((errors++))
            ;;
        *)
            # Linux/Windows: CPU binaries are primary
            check_file "$bin_dir/llama-server-${target}${ext}" "llama-server" || ((errors++))
            check_file "$bin_dir/llama-cli-${target}${ext}" "llama-cli" || ((errors++))
            check_file "$bin_dir/sd-${target}${ext}" "sd" || ((errors++))
            ;;
    esac

    # Common binaries (all platforms)
    check_file "$bin_dir/leaxer-grounding-dino${ext}" "leaxer-grounding-dino" || ((errors++))
    check_file "$bin_dir/leaxer-sam${ext}" "leaxer-sam" || ((errors++))
    check_file "$bin_dir/realesrgan-ncnn-vulkan${ext}" "realesrgan-ncnn-vulkan" || ((errors++))
    echo ""

    # GPU executables (optional on platforms with CPU primary)
    log_info "--- GPU Executables (optional) ---"
    case "$target" in
        x86_64-unknown-linux-gnu|x86_64-pc-windows-msvc)
            check_file "$bin_dir/llama-server-${target}-cuda${ext}" "llama-server-cuda" "false"
            check_file "$bin_dir/llama-cli-${target}-cuda${ext}" "llama-cli-cuda" "false"
            check_file "$bin_dir/sd-${target}-cuda${ext}" "sd-cuda" "false"
            check_file "$bin_dir/sd-server-${target}-cuda${ext}" "sd-server-cuda" "false"
            ;;
        aarch64-apple-darwin)
            # Metal server variant (optional)
            check_file "$bin_dir/sd-server-${target}-metal" "sd-server-metal" "false"
            ;;
    esac
    echo ""

    # Windows-specific DLLs
    if [[ "$target" == *"windows"* ]]; then
        log_info "--- Windows DLLs (critical) ---"
        check_file "$bin_dir/llama.dll" "llama.dll" || ((errors++))
        check_file "$bin_dir/ggml.dll" "ggml.dll" || ((errors++))
        check_file "$bin_dir/ggml-base.dll" "ggml-base.dll" || ((errors++))
        check_file "$bin_dir/ggml-cpu.dll" "ggml-cpu.dll" || ((errors++))
        echo ""

        log_info "--- CUDA DLLs (required for GPU) ---"
        check_file "$bin_dir/ggml-cuda.dll" "ggml-cuda.dll" "false"
        check_file "$bin_dir/cublas64_12.dll" "cublas64_12.dll" "false"
        check_file "$bin_dir/cublasLt64_12.dll" "cublasLt64_12.dll" "false"
        check_file "$bin_dir/cudart64_12.dll" "cudart64_12.dll" "false"
        echo ""

        log_info "--- Other Windows DLLs ---"
        check_file "$bin_dir/mtmd.dll" "mtmd.dll" "false"
        echo ""
    fi

    # Summary
    log_info "=========================================="
    if [[ $errors -gt 0 ]]; then
        log_error "Verification FAILED: $errors required file(s) missing"
        return 1
    else
        log_success "Verification PASSED: All required files present"
        return 0
    fi
}

# Calculate total size
calculate_size() {
    local bin_dir="$1"
    local total_size

    if command -v du &>/dev/null; then
        total_size=$(du -sh "$bin_dir" 2>/dev/null | cut -f1 || echo "unknown")
        echo ""
        log_info "Total bundle size: $total_size"
    fi
}

# Parse arguments
TARGET=""
BIN_DIR=""
CHECK_TAURI=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --dir)
            BIN_DIR="$2"
            shift 2
            ;;
        --tauri)
            CHECK_TAURI=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --target TARGET  Target platform (default: auto-detect)"
            echo "  --dir DIR        Directory to verify (default: apps/leaxer_core/priv/bin)"
            echo "  --tauri          Verify Tauri resources directory instead"
            echo ""
            echo "Examples:"
            echo "  $0                              # Verify priv/bin for current platform"
            echo "  $0 --tauri                      # Verify Tauri resources"
            echo "  $0 --target x86_64-pc-windows-msvc"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Auto-detect target if not specified
if [[ -z "$TARGET" ]]; then
    TARGET=$(detect_target)
fi

# Set bin directory
if [[ -z "$BIN_DIR" ]]; then
    if [[ "$CHECK_TAURI" == "true" ]]; then
        BIN_DIR="$DEFAULT_TAURI_BIN"
    else
        BIN_DIR="$DEFAULT_PRIV_BIN"
    fi
fi

# Run verification
verify_bundle "$TARGET" "$BIN_DIR"
EXIT_CODE=$?

# Calculate size
calculate_size "$BIN_DIR"

exit $EXIT_CODE

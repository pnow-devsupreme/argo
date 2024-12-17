#!/bin/bash

# File: scripts/generate-sealed-secrets.sh

# Set strict error handling
set -euo pipefail
IFS=$'\n\t'

# Constants for log levels and colors
readonly LOG_ERROR=1
readonly LOG_WARN=2
readonly LOG_INFO=3
readonly LOG_DEBUG=4

# Color codes for terminal output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default configuration that can be overridden
VERBOSE=${VERBOSE:-false}
LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}
TEMP_DIR=${TEMP_DIR:-/tmp/sealed-secrets}

# Logging functions that provide consistent, color-coded output
log() {
    local level=$1
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$level" -le "${LOG_LEVEL}" ]; then
        case $level in
            ($LOG_ERROR) echo -e "${RED}[ERROR]${NC} ${timestamp} - $msg" >&2 ;;
            ($LOG_WARN)  echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $msg" >&2 ;;
            ($LOG_INFO)  echo -e "${GREEN}[INFO]${NC} ${timestamp} - $msg" ;;
            ($LOG_DEBUG) echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - $msg" ;;
        esac
    fi
}

# Function to clean up temporary files
cleanup() {
    local exit_code=$?
    log $LOG_DEBUG "Cleaning up temporary files in $TEMP_DIR"
    rm -rf "$TEMP_DIR"
    exit $exit_code
}

# Set up error handling and cleanup
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 1' INT TERM

# Function to validate required tools are installed
check_prerequisites() {
    local missing_tools=()
    for tool in openssl kubeseal sed kubectl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log $LOG_ERROR "Missing required tools: ${missing_tools[*]}"
        return 1
    fi
    log $LOG_DEBUG "All prerequisites checked and available"
}

# Function to generate a secure random string with validation
generate_secure_string() {
    local length=$1
    local retries=3
    local attempt=1
    while [ $attempt -le $retries ]; do
        # Generate base string with extra length to account for filtering
        local base_string=$(openssl rand -base64 $(( length * 2 )) | tr -dc 'a-zA-Z0-9')
        # Ensure minimum requirements by injecting required character types
        local upper_char=$(openssl rand -base64 4 | tr -dc 'A-Z' | head -c 1)
        local lower_char=$(openssl rand -base64 4 | tr -dc 'a-z' | head -c 1)
        local number_char=$(openssl rand -base64 4 | tr -dc '0-9' | head -c 1)
        # Combine and shuffle
        local result="${base_string}${upper_char}${lower_char}${number_char}"
        result=$(echo "$result" | fold -w1 | shuf | tr -d '\n' | head -c "$length")
        log $LOG_DEBUG "Attempt $attempt: Generated string didn't meet complexity requirements, retrying..."
        attempt=$((attempt + 1))
    done
    log $LOG_ERROR "Failed to generate a secure string meeting requirements after $retries attempts"
    return 1
}

# Function to create a sealed secret from a template
create_sealed_secret() {
    local template_file=$1
    local output_file=$2
    local app_name=$3
    # Validate inputs
    if [ ! -f "$template_file" ]; then
        log $LOG_ERROR "Template file not found: $template_file"
        return 1
    fi
    # Create temporary directory
    mkdir -p "$TEMP_DIR"
    local temp_secret="$TEMP_DIR/${app_name}_temp_secret.yaml"
    log $LOG_INFO "Generating sealed secret for $app_name"
    # Read placeholder definitions from template comments
    local placeholders=$(grep "# PLACEHOLDER:" "$template_file" | sed 's/# PLACEHOLDER: \(.*\)/\1/')
    if [ -z "$placeholders" ]; then
        log $LOG_ERROR "No placeholder definitions found in template"
        return 1
    fi
    # Create temporary file with substituted values
    cp "$template_file" "$temp_secret"
    # Process each placeholder
    while IFS= read -r placeholder_def; do
        local name=$(echo "$placeholder_def" | cut -d'|' -f1)
        local length=$(echo "$placeholder_def" | cut -d'|' -f2)
        log $LOG_DEBUG "Processing placeholder: $name with length: $length"
        local value
        if ! value=$(generate_secure_string "$length"); then
            log $LOG_ERROR "Failed to generate value for $name"
            return 1
        fi
        sed -i "s/PLACEHOLDER_${name}/${value}/g" "$temp_secret"
        log $LOG_INFO "Generated secure value for: $name"
        echo "${name}: $value" >> "$TEMP_DIR/${app_name}_secrets.txt"
    done <<< "$placeholders"
    # Create sealed secret
    if ! kubeseal --format yaml < "$temp_secret" > "$output_file"; then
        log $LOG_ERROR "Failed to create sealed secret"
        return 1
    fi
    log $LOG_INFO "Successfully created sealed secret in $output_file"
    log $LOG_INFO "Secret values have been saved to $TEMP_DIR/${app_name}_secrets.txt"
}

# Main execution
main() {
    local template_file=$1
    local output_file=$2
    local app_name=$3
    if ! check_prerequisites; then
        exit 1
    fi
    if ! create_sealed_secret "$template_file" "$output_file" "$app_name"; then
        log $LOG_ERROR "Failed to create sealed secret"
        exit 1
    fi
    log $LOG_INFO "Sealed secret creation completed successfully"
}

# Show usage if no arguments provided
if [ $# -lt 3 ]; then
    echo "Usage: $0 <template_file> <output_file> <app_name>"
    echo "Example: $0 auth/templates/secrets.yaml auth/sealed-secrets.yaml authentik"
    exit 1
fi

main "$@"
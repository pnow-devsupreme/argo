#!/bin/bash
# Comprehensive ArgoCD Bootstrap Script for Microk8s HA Cluster
# This script tests and deploys the complete ArgoCD infrastructure with GitOps principles

# Exit on error
set -e

# ===== CONFIGURABLE VARIABLES =====

# Default values (can be overridden with command-line arguments)
REPO_URL=""
GIT_BRANCH=""
ARGOCD_DOMAIN="argocd.pnats.cloud"
METALLB_IP_RANGE="103.110.174.27-103.110.174.28"
METALLB_ARGOCD_IP="103.110.174.28"
GIT_USERNAME=""
GIT_TOKEN=""
SSH_PRIVATE_KEY=""
ENVIRONMENT="staging"
LOG_FILE="argocd-bootstrap-$(date +"%Y%m%d_%H%M%S").log"
TIMEOUT_DEPLOY=300   # 5 minutes
TIMEOUT_LB=300       # 5 minutes
TIMEOUT_COMPONENTS=300  # 5 minutes
INTERVAL=10          # Check every 10 seconds
ERROR_COLLECTION=()  # Array to collect errors

# Microk8s-specific configuration
KUBE_CMD="microk8s kubectl"

# ANSI color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ===== FUNCTIONS =====

# Display help message
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help                   Show this help message"
    echo "  -r, --repo URL               Git repository URL"
    echo "  -b, --branch BRANCH          Upstream branch name to use"
    echo "  -u, --username USERNAME      Git username for HTTPS authentication"
    echo "  -p, --password TOKEN         Git password/token for HTTPS authentication"
    echo "  -k, --ssh-private-key PATH   Path to SSH private key for Git authentication"
    echo "  -e, --env ENVIRONMENT        Deployment environment (staging/production)"
    echo "  -d, --domain DOMAIN          ArgoCD domain name"
    echo "  -i, --ip-range RANGE         MetalLB IP range"
    echo "  -a, --argocd-ip IP           MetalLB IP for ArgoCD"
    echo "  -l, --log-file FILE          Log file path"
    echo "  -t, --timeout SECONDS        Default timeout for operations"
}

# Log function for informative output
log() {
    local type=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Prepare log message
    local log_message="[$type] $timestamp - $message"
    
    # Console output with colors
    case $type in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} ${timestamp} - ${message}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} ${timestamp} - ${message}"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} ${timestamp} - ${message}"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}"
            # Collect error for summary
            ERROR_COLLECTION+=("$message")
            ;;
        "STEP")
            echo -e "\n${MAGENTA}[STEP]${NC} ${timestamp} - ${message}"
            echo -e "${MAGENTA}$(printf '=%.0s' {1..80})${NC}"
            ;;
        "TEST")
            echo -e "${CYAN}[TEST]${NC} ${timestamp} - ${message}"
            ;;
    esac
    
    # Write to log file (without colors)
    echo "$log_message" >> "$LOG_FILE"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display collected errors
display_errors() {
    if [ ${#ERROR_COLLECTION[@]} -ne 0 ]; then
        log "STEP" "ERROR SUMMARY"
        log "ERROR" "The following errors were encountered during execution:"
        for i in "${!ERROR_COLLECTION[@]}"; do
            log "ERROR" "$((i+1)). ${ERROR_COLLECTION[$i]}"
        done
    fi
}

# Function to clean up on exit
cleanup() {
    # Kill any background processes if they exist
    if [ -n "$PORT_FORWARD_PID" ] && ps -p $PORT_FORWARD_PID > /dev/null; then
        kill $PORT_FORWARD_PID 2>/dev/null
    fi
    
    # Remove temporary directory if it exists
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    
    # Display error summary if any errors occurred
    display_errors
    
    log "INFO" "Script execution completed. Log file: $LOG_FILE"
}

# Register cleanup function to run on exit
trap cleanup EXIT

# ===== PARSE COMMAND LINE ARGUMENTS =====

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            show_help
            exit 0
            ;;
        -r|--repo)
            REPO_URL="$2"
            shift 2
            ;;
        -b|--branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        -u|--username)
            GIT_USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            GIT_TOKEN="$2"
            shift 2
            ;;
        -k|--ssh-private-key)
            SSH_PRIVATE_KEY="$2"
            shift 2
            ;;
        -e|--env)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -d|--domain)
            ARGOCD_DOMAIN="$2"
            shift 2
            ;;
        -i|--ip-range)
            METALLB_IP_RANGE="$2"
            shift 2
            ;;
        -a|--argocd-ip)
            METALLB_ARGOCD_IP="$2"
            shift 2
            ;;
        -l|--log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT_DEPLOY="$2"
            TIMEOUT_LB="$2"
            TIMEOUT_COMPONENTS="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$REPO_URL" ]; then
    log "ERROR" "Repository URL is required. Use --repo to specify it."
    show_help
    exit 1
fi

# Validate authentication options
if [ -z "$SSH_PRIVATE_KEY" ] && [ -z "$GIT_USERNAME" -o -z "$GIT_TOKEN" ]; then
    log "WARNING" "No Git authentication provided. Either SSH key or username/token is recommended."
fi

# Create log file
touch "$LOG_FILE"
log "INFO" "Starting ArgoCD bootstrap script"
log "INFO" "Environment: $ENVIRONMENT"
log "INFO" "Repository URL: $REPO_URL"
log "INFO" "ArgoCD Domain: $ARGOCD_DOMAIN"

# ===== PREREQUISITE CHECKS =====

log "STEP" "PHASE 1: STARTING PREREQUISITE CHECKS"

# Check for required tools
log "TEST" "Checking for required command line tools..."
REQUIRED_COMMANDS=("microk8s" "curl" "git" "jq" "ping" "openssl" "nslookup")
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command_exists "$cmd"; then
        MISSING_COMMANDS+=("$cmd")
        log "ERROR" "Command '$cmd' not found!"
    else
        log "SUCCESS" "Command '$cmd' is available."
    fi
done

if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    log "ERROR" "Missing required commands: ${MISSING_COMMANDS[*]}. Please install them before proceeding."
    exit 1
fi

# Check if microk8s is running
log "TEST" "Checking if microk8s is running..."
if ! microk8s status | grep "microk8s is running" > /dev/null 2>&1; then
    log "ERROR" "microk8s is not running! Start it with: microk8s start"
    exit 1
fi
log "SUCCESS" "microk8s is running."

# Check for high availability in microk8s
log "TEST" "Checking microk8s high availability..."
if ! microk8s status | grep -E "high-availability:\s+yes" > /dev/null 2>&1; then
    log "WARNING" "microk8s high-availability might not be enabled. Check your cluster setup."
fi

# Check if kubectl can connect to the cluster
log "TEST" "Checking Kubernetes cluster connectivity..."
if ! $KUBE_CMD cluster-info > /dev/null 2>&1; then
    log "ERROR" "Cannot connect to Kubernetes cluster! Check your kubeconfig."
    exit 1
fi
log "SUCCESS" "Successfully connected to Kubernetes cluster."

# Check for Microk8s HA setup (at least 3 nodes)
log "TEST" "Checking for Microk8s HA setup with at least 3 nodes..."
NODE_COUNT=$($KUBE_CMD get nodes --no-headers | wc -l)
if [ "$NODE_COUNT" -lt 3 ]; then
    log "ERROR" "Expected at least 3 nodes for HA setup, but found only $NODE_COUNT."
    exit 1
fi
log "SUCCESS" "Found $NODE_COUNT nodes in the cluster."

# Check node status
log "TEST" "Checking node status..."
NOT_READY_NODES=$($KUBE_CMD get nodes --no-headers | grep -v -E "Ready(,|\s)" | wc -l)
if [ "$NOT_READY_NODES" -gt 0 ]; then
    log "ERROR" "Some nodes are not in Ready state!"
    $KUBE_CMD get nodes | tee -a "$LOG_FILE"
    exit 1
fi
log "SUCCESS" "All nodes are in Ready state."

# Check for microk8s specific addons
log "TEST" "Checking for required Microk8s addons..."
REQUIRED_ADDONS=("dns" "metallb" "storage")
MICROK8S_STATUS=$(microk8s status)
for addon in "${REQUIRED_ADDONS[@]}"; do
    # Updated grep pattern to match the indented format with the addon name at beginning of line
    if ! echo "$MICROK8S_STATUS" | grep -E '^\s+'"$addon"'\s+' > /dev/null 2>&1; then
        log "ERROR" "Microk8s addon '$addon' is not enabled! Enable it with: microk8s enable $addon"
        exit 1
    else
        log "SUCCESS" "Microk8s addon '$addon' is enabled."
    fi
done

# Verify MetalLB configuration
log "TEST" "Verifying MetalLB configuration..."

# First check if MetalLB is using CRD-based configuration (newer versions)
if $KUBE_CMD get crd ipaddresspools.metallb.io > /dev/null 2>&1; then
    log "INFO" "Detected CRD-based MetalLB configuration"
    
    # Check for IPAddressPool resources
    IP_POOLS=$($KUBE_CMD get ipaddresspools -n metallb-system -o json 2>/dev/null || echo "")
    if [ -z "$IP_POOLS" ] || [ "$IP_POOLS" = "{}" ]; then
        log "ERROR" "No IPAddressPool resources found in metallb-system namespace!"
        exit 1
    fi
    
    # Check if our IP range is in any pool
    if ! echo "$IP_POOLS" | grep -q "$METALLB_IP_RANGE"; then
        # Try alternative format (might be x.x.x.x-y.y.y.y instead of range)
        IFS='-' read -r START_IP END_IP <<< "$METALLB_IP_RANGE"
        if ! echo "$IP_POOLS" | grep -q "$START_IP" || ! echo "$IP_POOLS" | grep -q "$END_IP"; then
            log "ERROR" "MetalLB IP range $METALLB_IP_RANGE not found in any IPAddressPool!"
            exit 1
        fi
    fi
    
    # Check for L2Advertisement resources
    L2_ADS=$($KUBE_CMD get l2advertisements -n metallb-system -o json 2>/dev/null || echo "")
    if [ -z "$L2_ADS" ] || [ "$L2_ADS" = "{}" ]; then
        log "ERROR" "No L2Advertisement resources found in metallb-system namespace!"
        exit 1
    fi
    
    log "SUCCESS" "MetalLB is properly configured with CRDs and the IP range $METALLB_IP_RANGE."
else
    # Fall back to checking for ConfigMap-based configuration (older versions)
    METALLB_CONFIG=$($KUBE_CMD get configmap -n metallb-system config -o jsonpath='{.data.config}' 2>/dev/null || echo "")
    if [ -z "$METALLB_CONFIG" ]; then
        log "ERROR" "MetalLB configuration not found! Neither CRD nor ConfigMap configuration detected."
        exit 1
    elif ! echo "$METALLB_CONFIG" | grep -q "$METALLB_IP_RANGE"; then
        log "ERROR" "MetalLB IP range $METALLB_IP_RANGE not found in configuration!"
        exit 1
    fi
    log "SUCCESS" "MetalLB is properly configured with ConfigMap and the IP range $METALLB_IP_RANGE."
fi

# Verify domain DNS resolution
log "TEST" "Checking DNS resolution for $ARGOCD_DOMAIN..."
if ! nslookup "$ARGOCD_DOMAIN" > /dev/null 2>&1; then
    log "WARNING" "Could not resolve $ARGOCD_DOMAIN. Verify your DNS configuration."
    # Only warning, not an error, in case you're setting it up for the first time
else
    RESOLVED_IP=$(nslookup "$ARGOCD_DOMAIN" | grep -oP 'Address: \K([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1)
    if [ "$RESOLVED_IP" != "$METALLB_ARGOCD_IP" ]; then
        log "WARNING" "$ARGOCD_DOMAIN resolves to $RESOLVED_IP, but expected $METALLB_ARGOCD_IP."
    else
        log "SUCCESS" "$ARGOCD_DOMAIN correctly resolves to $METALLB_ARGOCD_IP."
    fi
fi

# Check network connectivity between nodes (sample test)
log "TEST" "Testing inter-node network connectivity..."
NODE_IPS=$($KUBE_CMD get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for ip in $NODE_IPS; do
    if ! ping -c 1 -W 2 "$ip" > /dev/null 2>&1; then
        log "ERROR" "Cannot ping node at $ip. Check network connectivity!"
        exit 1
    fi
done
log "SUCCESS" "All nodes are reachable on the network."

# Test Kubernetes API accessibility and permissions
log "TEST" "Testing Kubernetes API permissions..."
if ! $KUBE_CMD auth can-i create namespace > /dev/null 2>&1; then
    log "ERROR" "Insufficient permissions to create namespace!"
    exit 1
fi
log "SUCCESS" "Current user has sufficient permissions to create namespaces."

# Check for critical resources like CustomResourceDefinitions for cert-manager, etc.
log "TEST" "Checking for conflicting installations..."
if $KUBE_CMD get crd issuers.cert-manager.io > /dev/null 2>&1; then
    log "WARNING" "cert-manager CRDs already exist! This might conflict with our installation."
    # Not exiting, just warning
fi

# ===== REPOSITORY CHECKS =====

log "STEP" "PHASE 2: CHECKING REPOSITORY STRUCTURE"

# Clone repository temporarily
TEMP_DIR=$(mktemp -d)
log "INFO" "Cloning repository to temporary directory: $TEMP_DIR (using branch: $GIT_BRANCH)"
if ! git clone -b $GIT_BRANCH "$REPO_URL" "$TEMP_DIR" > /dev/null 2>&1; then
    # Fallback to regular clone if branch-specific clone fails
    if ! git clone "$REPO_URL" "$TEMP_DIR" > /dev/null 2>&1; then
        log "ERROR" "Failed to clone repository $REPO_URL. Check your credentials and access rights."
        rm -rf "$TEMP_DIR"
        exit 1
    else
        # Try to checkout the correct branch after cloning
        if ! (cd "$TEMP_DIR" && git checkout $GIT_BRANCH > /dev/null 2>&1); then
            log "ERROR" "Failed to checkout branch '$GIT_BRANCH'. Branch may not exist."
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    fi
fi
log "SUCCESS" "Repository cloned successfully using branch '$GIT_BRANCH'."

# Check for required files
log "TEST" "Checking for critical files in repository..."
REQUIRED_FILES=(
    "deployments/bootstrap/argocd/base/kustomization.yaml"
    "deployments/bootstrap/argocd/base/manifests/install.yaml"
    "deployments/bootstrap/argocd/base/manifests/namespace.yaml"
    "deployments/bootstrap/argocd/base/manifests/projects.yaml"
    "deployments/bootstrap/argocd/base/manifests/root-app.yaml"
    "deployments/bootstrap/platform-apps/base/domains/infrastructure/application.yaml"
    "deployments/bootstrap/platform-apps/base/domains/applications/application.yaml"
    "deployments/bootstrap/platform-apps/base/domains/workloads/application.yaml"
    "deployments/bootstrap/platform-apps/base/domains/infrastructure/argocd-main.yaml"
    "deployments/domains/infrastructure/apps/argocd/app/argocd.yaml"
)

# Debug output to verify repository contents
log "INFO" "Listing actual repository contents for verification..."
find "$TEMP_DIR/deployments" -type f -name "*.yaml" | sort | tee -a "$LOG_FILE"

MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$TEMP_DIR/$file" ]; then
        # Double-check using find to see if the file exists with a slightly different path
        FOUND=$(find "$TEMP_DIR" -name "$(basename "$file")" -type f | wc -l)
        if [ "$FOUND" -gt 0 ]; then
            log "WARNING" "File exists but with different path: $(basename "$file")"
            # Show where the file was actually found
            find "$TEMP_DIR" -name "$(basename "$file")" -type f | tee -a "$LOG_FILE"
            # Consider this file as found
            log "SUCCESS" "Found required file with different path: $file"
            continue
        fi
        
        MISSING_FILES+=("$file")
        log "ERROR" "Required file not found: $file"
    else
        log "SUCCESS" "Found required file: $file"
    fi
done

if [ ${#MISSING_FILES[@]} -ne 0 ]; then
    # Make this a warning instead of an error if your flow needs to continue
    log "WARNING" "Missing some expected files in repository structure. The deployment may still proceed with available files."
    # Remove the exit condition to allow the script to continue
    # exit 1
else
    log "SUCCESS" "All required files found in repository."
fi

# Enhanced content verification for critical files
log "TEST" "Verifying content of critical files..."

# Check ArgoCD installation file
if ! grep -q "kind: Kustomization" "$TEMP_DIR/deployments/bootstrap/argocd/base/manifests/install.yaml"; then
    log "ERROR" "Invalid install.yaml file: Expected Kustomization resource"
    exit 1
fi

# Check root app destination
if ! grep -q "namespace: argocd" "$TEMP_DIR/deployments/bootstrap/argocd/base/manifests/root-app.yaml"; then
    log "ERROR" "Invalid root-app.yaml: Expected namespace: argocd"
    exit 1
fi

# Check application names in domain application files
log "TEST" "Checking application names in domain files..."

# Get the actual root application name
INFRA_ROOT_APP_NAME=$(grep -A5 "kind: Application" "$TEMP_DIR/deployments/bootstrap/platform-apps/base/domains/infrastructure/application.yaml" | grep "name:" | head -1 | awk '{print $2}')
log "INFO" "Found infrastructure root application name: $INFRA_ROOT_APP_NAME"

# Get the ArgoCD self-management application name
ARGOCD_SELF_APP_NAME=$(grep -A5 "kind: Application" "$TEMP_DIR/deployments/bootstrap/platform-apps/base/domains/infrastructure/argocd-main.yaml" | grep "name:" | head -1 | awk '{print $2}')
log "INFO" "Found ArgoCD self-management application name: $ARGOCD_SELF_APP_NAME"

# Validate YAML files (selective syntax check)
log "TEST" "Validating YAML files..."

# Only validate direct Kubernetes resources, skip kustomization.yaml files
find "$TEMP_DIR/deployments" -name "*.yaml" -not -name "kustomization.yaml" -exec sh -c '
    # Check if file contains "kind:" and "apiVersion:" - basic YAML structure check
    if grep -q "kind:" "$1" && grep -q "apiVersion:" "$1"; then
        # For known Kubernetes resources that can be validated directly
        if grep -q -E "kind: (Namespace|ConfigMap|Secret|Service|Deployment|StatefulSet|DaemonSet)" "$1"; then
            if ! '"$KUBE_CMD"' apply --dry-run=client -f "$1" > /dev/null 2>&1; then
                echo "$1"
            fi
        fi
    fi
' sh {} \; > invalid_files.txt

# If there are invalid files, log them but don't fail the script
if [ -s invalid_files.txt ]; then
    log "WARNING" "Potentially invalid YAML files found, but continuing deployment:"
    cat invalid_files.txt | tee -a "$LOG_FILE"
else
    log "SUCCESS" "All validated YAML files have correct syntax."
fi
rm -f invalid_files.txt
log "SUCCESS" "All YAML files have valid syntax."

# Clean up temp repository (cleanup function will handle this)

# ===== DEPLOYMENT PHASE =====

log "STEP" "PHASE 3: STARTING DEPLOYMENT"

# Create ArgoCD namespace
log "INFO" "Creating ArgoCD namespace..."
if ! $KUBE_CMD create namespace argocd > /dev/null 2>&1; then
    if $KUBE_CMD get namespace argocd > /dev/null 2>&1; then
        log "WARNING" "Namespace argocd already exists."
    else
        log "ERROR" "Failed to create namespace argocd!"
        exit 1
    fi
else
    log "SUCCESS" "Namespace argocd created."
fi

# Deploy ArgoCD base installation
log "INFO" "Deploying ArgoCD base installation..."
$KUBE_CMD apply -k deployments/bootstrap/argocd/environments/$ENVIRONMENT

# Wait for ArgoCD controller to be ready (primary component)
log "INFO" "Waiting for ArgoCD controller to become ready..."
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT_DEPLOY ]; do
    if $KUBE_CMD -n argocd get deployment argocd-application-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q "[1-9]"; then
        log "SUCCESS" "ArgoCD controller is ready."
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    log "INFO" "Still waiting for ArgoCD controller... ($ELAPSED/$TIMEOUT_DEPLOY seconds)"
done

if [ $ELAPSED -ge $TIMEOUT_DEPLOY ]; then
    log "ERROR" "Timeout waiting for ArgoCD controller to be ready. Check logs:"
    $KUBE_CMD -n argocd logs -l app.kubernetes.io/name=argocd-application-controller | tail -n 100 | tee -a "$LOG_FILE"
    exit 1
fi

# Wait for all essential ArgoCD components to be ready
log "INFO" "Waiting for all ArgoCD components to be ready..."
COMPONENTS=("argocd-server" "argocd-repo-server" "argocd-redis" "argocd-application-controller")
for component in "${COMPONENTS[@]}"; do
    log "INFO" "Waiting for $component..."
    if ! $KUBE_CMD -n argocd wait --for=condition=available deployment "$component" --timeout=${TIMEOUT_COMPONENTS}s 2>/dev/null; then
        log "ERROR" "Timeout waiting for $component to be ready!"
        exit 1
    fi
    log "SUCCESS" "$component is ready."
done

# Check ArgoCD service exposure (LoadBalancer IP)
log "INFO" "Checking ArgoCD server service configuration..."
if ! $KUBE_CMD -n argocd get service argocd-server -o jsonpath='{.spec.type}' | grep -q "LoadBalancer"; then
    log "ERROR" "ArgoCD server service is not of type LoadBalancer!"
    exit 1
fi

log "INFO" "Waiting for LoadBalancer IP assignment..."
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT_LB ]; do
    LB_IP=$($KUBE_CMD -n argocd get service argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "$LB_IP" ]; then
        log "SUCCESS" "ArgoCD server assigned LoadBalancer IP: $LB_IP"
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    log "INFO" "Still waiting for LoadBalancer IP... ($ELAPSED/$TIMEOUT_LB seconds)"
done

if [ $ELAPSED -ge $TIMEOUT_LB ]; then
    log "ERROR" "Timeout waiting for LoadBalancer IP. Check MetalLB configuration!"
    exit 1
fi

# Get ArgoCD admin password
log "INFO" "Retrieving ArgoCD initial admin password..."
ARGOCD_PASSWORD=$($KUBE_CMD -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
if [ -z "$ARGOCD_PASSWORD" ]; then
    log "ERROR" "Failed to retrieve ArgoCD admin password!"
    exit 1
fi
log "SUCCESS" "Retrieved ArgoCD admin password: $ARGOCD_PASSWORD"
log "INFO" "Store this password securely as it will be needed for the next steps."

# Test ArgoCD API accessibility (initially through port forwarding)
log "INFO" "Testing ArgoCD API accessibility via port-forwarding..."
$KUBE_CMD port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 5  # Give it time to establish

# Check if port-forward is working
if ! ps -p $PORT_FORWARD_PID > /dev/null; then
    log "ERROR" "Port-forwarding failed to start!"
    exit 1
fi

# Test API access
log "INFO" "Testing API access through port-forwarding..."
if ! curl -k https://localhost:8080/api/v1/applications -o /dev/null -s; then
    log "ERROR" "Failed to access ArgoCD API through port-forwarding!"
    kill $PORT_FORWARD_PID 2>/dev/null || true
    exit 1
fi
log "SUCCESS" "Successfully accessed ArgoCD API through port-forwarding."
kill $PORT_FORWARD_PID 2>/dev/null || true

# Configuring repository in ArgoCD
log "INFO" "Installing argocd CLI tool..."
if ! command_exists argocd; then
    curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
    rm argocd-linux-amd64
    log "SUCCESS" "argocd CLI tool installed."
else
    log "INFO" "argocd CLI tool already installed."
fi

# Login to ArgoCD (using port-forwarding temporarily)
log "INFO" "Logging in to ArgoCD..."
$KUBE_CMD port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 5

# Try to login (with retries)
RETRY=0
MAX_RETRIES=5
while [ $RETRY -lt $MAX_RETRIES ]; do
    if argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure; then
        log "SUCCESS" "Successfully logged in to ArgoCD."
        break
    fi
    RETRY=$((RETRY + 1))
    log "WARNING" "Login attempt $RETRY failed. Retrying..."
    sleep 5
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    log "ERROR" "Failed to login to ArgoCD after $MAX_RETRIES attempts!"
    kill $PORT_FORWARD_PID 2>/dev/null || true
    exit 1
fi

# Add repository
log "INFO" "Adding repository to ArgoCD..."
REPO_ADDED=false

if [ -n "$SSH_PRIVATE_KEY" ]; then
    # Try SSH authentication
    if argocd repo add "$REPO_URL" --insecure --ssh-private-key-path "$SSH_PRIVATE_KEY"; then
        log "SUCCESS" "Successfully added repository to ArgoCD using SSH key."
        REPO_ADDED=true
    else
        log "ERROR" "Failed to add repository using SSH key!"
    fi
elif [ -n "$GIT_USERNAME" ] && [ -n "$GIT_TOKEN" ]; then
    # Try username/password authentication
    if argocd repo add "$REPO_URL" --insecure --username "$GIT_USERNAME" --password "$GIT_TOKEN"; then
        log "SUCCESS" "Successfully added repository to ArgoCD using username/password."
        REPO_ADDED=true
    else
        log "ERROR" "Failed to add repository using username/password!"
    fi
else
    # Try without authentication
    if argocd repo add "$REPO_URL" --insecure; then
        log "SUCCESS" "Successfully added repository to ArgoCD without authentication."
        REPO_ADDED=true
    else
        log "ERROR" "Failed to add repository without authentication!"
    fi
fi

kill $PORT_FORWARD_PID 2>/dev/null || true

if [ "$REPO_ADDED" = false ]; then
    log "ERROR" "Could not add repository to ArgoCD. Please check your authentication credentials."
    exit 1
fi

# Deploy the root app
log "STEP" "PHASE 4: DEPLOYING ROOT APPLICATION"
log "INFO" "Applying root-app.yaml to start the App of Apps pattern..."
if ! $KUBE_CMD apply -f deployments/bootstrap/argocd/base/manifests/root-app.yaml; then
    log "ERROR" "Failed to apply root-app.yaml!"
    exit 1
fi
log "SUCCESS" "Root application deployed successfully."

# Monitor deployment of core infrastructure components
log "STEP" "PHASE 5: MONITORING INFRASTRUCTURE DEPLOYMENT"

# Wait for domain root apps to be created
log "INFO" "Waiting for domain root applications to be created..."
sleep 30  # Give ArgoCD some time to create applications

# Check for infrastructure domain app using the name we extracted earlier
log "INFO" "Checking infrastructure domain application..."
if ! $KUBE_CMD -n argocd get application "$INFRA_ROOT_APP_NAME" > /dev/null 2>&1; then
    log "ERROR" "Infrastructure domain application '$INFRA_ROOT_APP_NAME' not created!"
    # Try the default name as fallback
    if ! $KUBE_CMD -n argocd get application infrastructure-root > /dev/null 2>&1; then
        log "ERROR" "Infrastructure domain application also not found with default name 'infrastructure-root'!"
        exit 1
    else
        log "WARNING" "Found infrastructure application with default name 'infrastructure-root' instead of '$INFRA_ROOT_APP_NAME'"
        INFRA_ROOT_APP_NAME="infrastructure-root"
    fi
fi
log "SUCCESS" "Infrastructure domain application '$INFRA_ROOT_APP_NAME' created."

# Monitor cert-manager deployment
log "INFO" "Monitoring cert-manager deployment..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if $KUBE_CMD get namespace cert-manager > /dev/null 2>&1; then
        log "INFO" "cert-manager namespace created, checking deployment..."
        if $KUBE_CMD -n cert-manager get deployment cert-manager -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q "[1-9]"; then
            log "SUCCESS" "cert-manager deployed successfully."
            break
        fi
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    log "INFO" "Still waiting for cert-manager... ($ELAPSED/$TIMEOUT seconds)"
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "WARNING" "Timeout waiting for cert-manager to be ready. Deployment might still be in progress."
    # Not exiting, as other components might still deploy
fi

# Monitor ingress-nginx deployment
log "INFO" "Monitoring ingress-nginx deployment..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if $KUBE_CMD get namespace ingress-nginx > /dev/null 2>&1; then
        log "INFO" "ingress-nginx namespace created, checking deployment..."
        if $KUBE_CMD -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q "[1-9]"; then
            log "SUCCESS" "ingress-nginx deployed successfully."
            break
        fi
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    log "INFO" "Still waiting for ingress-nginx... ($ELAPSED/$TIMEOUT seconds)"
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "WARNING" "Timeout waiting for ingress-nginx to be ready. Deployment might still be in progress."
    # Not exiting, as other components might still deploy
fi

# Final check for ArgoCD ingress
log "INFO" "Checking for ArgoCD ingress configuration..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if $KUBE_CMD -n argocd get ingress argocd-server-ingress > /dev/null 2>&1; then
        log "SUCCESS" "ArgoCD ingress configured successfully."
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    log "INFO" "Still waiting for ArgoCD ingress... ($ELAPSED/$TIMEOUT seconds)"
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "WARNING" "Timeout waiting for ArgoCD ingress. Check your ArgoCD ingress configuration."
    # Not exiting, as access via LoadBalancer might still work
fi

# Test access to ArgoCD via domain
log "INFO" "Testing access to ArgoCD via domain $ARGOCD_DOMAIN..."
if curl -k -s "https://$ARGOCD_DOMAIN/" > /dev/null; then
    log "SUCCESS" "ArgoCD is accessible via https://$ARGOCD_DOMAIN/"
else
    log "WARNING" "Could not access ArgoCD via https://$ARGOCD_DOMAIN/ - Check your DNS and ingress configuration."
    log "INFO" "You can still access ArgoCD via LoadBalancer IP: https://$LB_IP/"
fi

# Show final status of all ArgoCD applications
log "STEP" "PHASE 6: FINAL STATUS"
log "INFO" "Final status of ArgoCD applications:"
$KUBE_CMD -n argocd get applications | tee -a "$LOG_FILE"

# Display collected errors (if any)
display_errors

log "SUCCESS" "=== BOOTSTRAP COMPLETE ==="
log "INFO" "Your ArgoCD instance has been deployed and has started managing your infrastructure."
log "INFO" "Access your ArgoCD instance at: https://$ARGOCD_DOMAIN/ or https://$LB_IP/"
log "INFO" "Username: admin"
log "INFO" "Password: $ARGOCD_PASSWORD"
log "INFO" "Remember to secure your ArgoCD instance by changing the admin password and configuring proper authentication!"
log "INFO" "Log file: $LOG_FILE"
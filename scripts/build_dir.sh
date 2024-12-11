#!/bin/bash

# Function to create directories and files with proper permissions
create_dir_structure() {
    local path="$1"
    mkdir -p "$path"
    # Create an empty .gitkeep file to ensure git tracks empty directories
    touch "$path/.gitkeep"
}

# Function to create a basic kustomization.yaml file
create_kustomization() {
    local path="$1"
    cat > "$path/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
EOF
}

# Set the root directory for deployments
ROOT_DIR="deployments"

# Check if the directory already exists
if [ -d "$ROOT_DIR" ]; then
    echo "Warning: $ROOT_DIR directory already exists!"
    read -p "Do you want to continue? This may overwrite existing files (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 1
    fi
fi

# Create the root directory
mkdir -p "$ROOT_DIR"

# Define the environments
ENVIRONMENTS=("staging" "production")

# Define the domain structure
declare -A DOMAIN_APPS
DOMAIN_APPS["infrastructure"]="networking security observability"
DOMAIN_APPS["workloads"]="ml-pipeline data-processing"
DOMAIN_APPS["applications"]=""

# Create domains and their structure
for domain in "${!DOMAIN_APPS[@]}"; do
    # Create domain base structure
    create_dir_structure "$ROOT_DIR/domains/$domain/platform/base/manifests"
    create_dir_structure "$ROOT_DIR/domains/$domain/platform/environments"
    create_kustomization "$ROOT_DIR/domains/$domain/platform/base"
    
    # Create environment directories for platform
    for env in "${ENVIRONMENTS[@]}"; do
        create_dir_structure "$ROOT_DIR/domains/$domain/platform/environments/$env"
        create_kustomization "$ROOT_DIR/domains/$domain/platform/environments/$env"
    done
    
    # Create apps structure if domain has apps
    if [ -n "${DOMAIN_APPS[$domain]}" ]; then
        for app in ${DOMAIN_APPS[$domain]}; do
            # Create base structure for each app
            create_dir_structure "$ROOT_DIR/domains/$domain/apps/$app/base/manifests"
            create_kustomization "$ROOT_DIR/domains/$domain/apps/$app/base"
            
            # Create environment directories for each app
            for env in "${ENVIRONMENTS[@]}"; do
                create_dir_structure "$ROOT_DIR/domains/$domain/apps/$app/environments/$env"
                create_kustomization "$ROOT_DIR/domains/$domain/apps/$app/environments/$env"
            done
        done
    fi
done

# Create bootstrap structure
create_dir_structure "$ROOT_DIR/bootstrap/argocd/base"
create_dir_structure "$ROOT_DIR/bootstrap/platform-apps/base"
create_kustomization "$ROOT_DIR/bootstrap/argocd/base"
create_kustomization "$ROOT_DIR/bootstrap/platform-apps/base"

# Create bootstrap environment directories
for env in "${ENVIRONMENTS[@]}"; do
    create_dir_structure "$ROOT_DIR/bootstrap/argocd/environments/$env"
    create_dir_structure "$ROOT_DIR/bootstrap/platform-apps/environments/$env"
    create_kustomization "$ROOT_DIR/bootstrap/argocd/environments/$env"
    create_kustomization "$ROOT_DIR/bootstrap/platform-apps/environments/$env"
done

# Create root environment structure
for env in "${ENVIRONMENTS[@]}"; do
    create_dir_structure "$ROOT_DIR/environments/$env/platform-config"
done

echo "Directory structure created successfully!"
echo "Note: Empty directories contain .gitkeep files to ensure they are tracked by git"
echo "Basic kustomization.yaml files have been created in appropriate directories"
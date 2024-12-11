# GitOps Infrastructure Documentation

## Table of Contents

1. [Introduction](#introduction)
2. [Directory Structure Overview](#directory-structure-overview)
3. [Domains](#domains)
   - [Infrastructure Domain](#infrastructure-domain)
   - [Workloads Domain](#workloads-domain)
   - [Applications Domain](#applications-domain)
4. [Bootstrap Process](#bootstrap-process)
5. [Environment Management](#environment-management)
6. [Best Practices](#best-practices)
7. [Examples](#examples)
8. [Troubleshooting](#troubleshooting)

## Introduction

This document provides comprehensive documentation for the GitOps infrastructure deployment system. The system is designed to manage multiple domains of infrastructure, workloads, and applications across different environments using ArgoCD and Kubernetes.

### Key Features

- Domain-driven infrastructure organization
- Environment isolation and configuration
- Kubernetes-native deployment using ArgoCD
- Infrastructure as Code (IaC) principles
- Secure secret management
- Scalable and maintainable structure

## Directory Structure Overview

The repository follows a hierarchical structure organized by domains, applications, and environments:

```
deployments/
├── domains/           # Main domain separation
├── bootstrap/         # Bootstrap configurations
└── environments/      # Environment-specific configurations
```

### Purpose of Each Directory

Each directory serves a specific purpose in the overall infrastructure:

- `domains/`: Contains all domain-specific configurations and applications
- `bootstrap/`: Holds configurations needed to initialize the infrastructure
- `environments/`: Stores environment-specific platform configurations

## Domains

### Infrastructure Domain

The infrastructure domain contains all core infrastructure components necessary for running the platform.

#### Location

```
deployments/domains/infrastructure/
```

#### Components

1. **Networking**
   - Purpose: Manages all networking-related components
   - Example components:

     ```yaml
     # deployments/domains/infrastructure/apps/networking/base/ingress-nginx/manifests/ingress.yaml
     apiVersion: networking.k8s.io/v1
     kind: IngressClass
     metadata:
       name: nginx
     spec:
       controller: k8s.io/ingress-nginx
     ```

2. **Security**
   - Purpose: Handles security-related infrastructure
   - Components include:
     - Certificate management
     - Secret management
     - Authentication/Authorization
   - Example:

     ```yaml
     # deployments/domains/infrastructure/apps/security/base/cert-manager/manifests/cluster-issuer.yaml
     apiVersion: cert-manager.io/v1
     kind: ClusterIssuer
     metadata:
       name: letsencrypt-prod
     spec:
       acme:
         server: https://acme-v02.api.letsencrypt.org/directory
         email: admin@example.com
         privateKeySecretRef:
           name: letsencrypt-prod
         solvers:
         - http01:
             ingress:
               class: nginx
     ```

3. **Observability**
   - Purpose: Monitoring, logging, and observability
   - Components:
     - Prometheus
     - Grafana
     - Loki
     - OpenTelemetry

#### Usage

To deploy a new infrastructure component:

1. Create the component structure:

   ```bash
   mkdir -p infrastructure/apps/component-name/base/manifests
   ```

2. Add base manifests:

   ```yaml
   # infrastructure/apps/component-name/base/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - manifests/deployment.yaml
   - manifests/service.yaml
   ```

3. Create environment overlays:

   ```yaml
   # infrastructure/apps/component-name/environments/production/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../base
   patches:
   - path: patches/resource-limits.yaml
   ```

### Workloads Domain

The workloads domain contains application workloads that run on the infrastructure.

#### Location

```
deployments/domains/workloads/
```

#### Components

1. **ML Pipeline**
   - Purpose: Machine learning workflow components
   - Example structure:

     ```yaml
     # domains/workloads/apps/ml-pipeline/base/manifests/training-operator.yaml
     apiVersion: kubeflow.org/v1
     kind: TFJob
     metadata:
       name: tensorflow-training
     spec:
       tfReplicaSpecs:
         Worker:
           replicas: 1
           template:
             spec:
               containers:
               - name: tensorflow
                 image: tensorflow/tensorflow:latest
     ```

2. **Data Processing**
   - Purpose: Data processing and ETL workloads
   - Components:
     - Apache Spark operators
     - Data pipelines
     - Stream processing

### Applications Domain

The applications domain contains business applications and services.

#### Location

```
deployments/domains/applications/
```

#### Usage Guidelines

- Each application should have its own directory
- Use base/overlay pattern for environment-specific configurations
- Include necessary documentation in each application directory

## Bootstrap Process

The bootstrap directory contains configurations needed to initialize the infrastructure.

### Structure

```
bootstrap/
├── argocd/
│   ├── base/
│   └── environments/
└── platform-apps/
    ├── base/
    └── environments/
```

### Bootstrap Process

1. **ArgoCD Installation**

   ```yaml
   # bootstrap/argocd/base/install.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: argocd
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/your-org/your-repo.git
       path: bootstrap/argocd/base
       targetRevision: HEAD
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
   ```

2. **Platform Applications**
   - Define core platform applications
   - Set up initial configurations
   - Example:

     ```yaml
     # bootstrap/platform-apps/base/apps.yaml
     apiVersion: argoproj.io/v1alpha1
     kind: ApplicationSet
     metadata:
       name: infrastructure-apps
     spec:
       generators:
       - list:
           elements:
           - name: networking
           - name: security
           - name: observability
     ```

## Environment Management

### Structure

```
environments/
├── staging/
│   └── platform-config/
└── production/
    └── platform-config/
```

### Environment-Specific Configurations

1. **Platform Configuration**

   ```yaml
   # environments/production/platform-config/limits.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: compute-resources
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
   ```

2. **Environment Variables**

   ```yaml
   # environments/staging/platform-config/env-config.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: environment-config
   data:
     ENV: staging
     LOG_LEVEL: debug
   ```

## Best Practices

### 1. Version Control

- Use semantic versioning for releases
- Tag releases appropriately
- Maintain a changelog

### 2. Configuration Management

- Use Kustomize for environment-specific changes
- Keep sensitive information in sealed secrets
- Use ConfigMaps for non-sensitive configuration

### 3. Application Structure

- Follow the base/overlay pattern
- Keep manifests modular
- Document all customizations

### 4. CI/CD

- Implement automated testing
- Use GitOps workflows
- Maintain separate pipelines for different environments

## Examples

### Complete Application Deployment Example

1. **Base Configuration**

   ```yaml
   # domains/applications/apps/web-app/base/manifests/deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web-app
   spec:
     replicas: 1
     template:
       spec:
         containers:
         - name: web-app
           image: nginx:latest
   ```

2. **Production Overlay**

   ```yaml
   # domains/applications/apps/web-app/environments/production/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../base
   patches:
   - patch: |-
       - op: replace
         path: /spec/replicas
         value: 3
     target:
       kind: Deployment
       name: web-app
   ```

## Troubleshooting

### Common Issues

1. **ArgoCD Sync Issues**
   - Check application logs
   - Verify repository access
   - Validate YAML syntax

2. **Environment Misconfiguration**
   - Review environment-specific overlays
   - Check ConfigMaps and Secrets
   - Verify resource quotas

3. **Bootstrap Problems**
   - Ensure correct permissions
   - Verify network connectivity
   - Check certificate validity

### Support and Maintenance

For ongoing support and maintenance:

1. Regular Updates
   - Keep base images updated
   - Review and update dependencies
   - Monitor security advisories

2. Monitoring
   - Set up alerts for critical components
   - Monitor resource usage
   - Track application health

3. Backup and Recovery
   - Implement regular backups
   - Document recovery procedures
   - Test restoration processes

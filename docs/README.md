# Self-Hosted Runners on Azure — Tutorial Guide

> A comprehensive, step-by-step guide to deploying and managing GitHub Actions self-hosted runners on Azure — from your first VM to enterprise-scale Kubernetes clusters.

---

## 🗺️ Learning Path

```mermaid
graph TD
    START([🚀 Start Here]) --> PREREQ[03 — Prerequisites]

    %% Beginner Track
    PREREQ --> VM[06 — VM Manual Setup]
    VM --> WORKFLOWS[13 — Sample Workflows]

    %% Intermediate Track
    PREREQ --> VMAUT[07 — VM Automation]
    PREREQ --> ACI[08 — ACI Setup]
    VMAUT --> OIDC[10 — OIDC & Workload Identity]
    ACI --> OIDC
    OIDC --> MON[12 — Monitoring & Maintenance]

    %% Advanced Track
    PREREQ --> AUTH[05 — GitHub Auth & Tokens]
    AUTH --> AKS[09 — AKS + ARC Setup]
    AKS --> SEC[11 — Security Hardening]
    SEC --> ENT[14 — Advanced Enterprise]

    %% Styles — Beginner (green)
    style START fill:#4CAF50,stroke:#2E7D32,color:#fff
    style PREREQ fill:#81C784,stroke:#2E7D32,color:#000
    style VM fill:#A5D6A7,stroke:#2E7D32,color:#000
    style WORKFLOWS fill:#A5D6A7,stroke:#2E7D32,color:#000

    %% Styles — Intermediate (blue)
    style VMAUT fill:#64B5F6,stroke:#1565C0,color:#000
    style ACI fill:#64B5F6,stroke:#1565C0,color:#000
    style OIDC fill:#64B5F6,stroke:#1565C0,color:#000
    style MON fill:#64B5F6,stroke:#1565C0,color:#000

    %% Styles — Advanced (red)
    style AUTH fill:#EF5350,stroke:#B71C1C,color:#fff
    style AKS fill:#EF5350,stroke:#B71C1C,color:#fff
    style SEC fill:#EF5350,stroke:#B71C1C,color:#fff
    style ENT fill:#EF5350,stroke:#B71C1C,color:#fff
```

**Legend:** 🟢 Beginner &nbsp;|&nbsp; 🔵 Intermediate &nbsp;|&nbsp; 🔴 Advanced

---

## 📑 Full Table of Contents

| # | Guide | Level | Description |
|---|-------|-------|-------------|
| 01 | [Introduction](01-introduction.md) | 🟢 Beginner | What are self-hosted runners, why use them, architecture overview |
| 02 | [Decision Guide](02-decision-guide.md) | 🟢 All | VM vs ACI vs AKS — choose the right platform |
| 03 | [Prerequisites](03-prerequisites.md) | 🟢 All | Azure account, GitHub Enterprise Cloud, CLI tools |
| 04 | [Networking & Connectivity](04-networking-connectivity.md) | 🟡 Intermediate | Required endpoints, NSG, proxy, firewall configuration |
| 05 | [GitHub Auth & Tokens](05-github-auth-tokens.md) | 🟡 Intermediate | Registration tokens, GitHub App, PAT, JIT runners |
| 06 | [VM Manual Setup](06-vm-manual-setup.md) | 🟢 Beginner | Create Azure VM and install runner step-by-step |
| 07 | [VM Automation](07-vm-automation.md) | 🟡 Intermediate | cloud-init and Bicep templates for automated VM setup |
| 08 | [ACI Setup](08-aci-setup.md) | 🟡 Intermediate | Container-based runners on Azure Container Instances |
| 09 | [AKS + ARC Setup](09-aks-arc-setup.md) | 🔴 Advanced | Kubernetes runners with Actions Runner Controller |
| 10 | [OIDC & Workload Identity](10-oidc-workload-identity.md) | 🟡 Intermediate | Passwordless Azure authentication with federated credentials |
| 11 | [Security Hardening](11-security-hardening.md) | 🔴 Advanced | OS hardening, network security, secrets management, compliance |
| 12 | [Monitoring & Maintenance](12-monitoring-maintenance.md) | 🟡 Intermediate | Health monitoring, logging, updates, troubleshooting |
| 13 | [Sample Workflows](13-sample-workflows.md) | 🟢 All | 6 ready-to-use GitHub Actions workflow examples |
| 14 | [Advanced Enterprise](14-advanced-enterprise.md) | 🔴 Advanced | Runner groups, cost optimization, multi-region, compliance |

---

## 🔍 "I Want To…" Quick Reference

| I want to… | Go to |
|-------------|-------|
| Understand what self-hosted runners are | [01 — Introduction](01-introduction.md) |
| Choose between VM, ACI, and AKS | [02 — Decision Guide](02-decision-guide.md) |
| Set up my first runner on a VM | [06 — VM Manual Setup](06-vm-manual-setup.md) |
| Automate runner provisioning | [07 — VM Automation](07-vm-automation.md) |
| Run ephemeral runners in containers | [08 — ACI Setup](08-aci-setup.md) |
| Scale runners with Kubernetes | [09 — AKS + ARC Setup](09-aks-arc-setup.md) |
| Authenticate to Azure without secrets | [10 — OIDC & Workload Identity](10-oidc-workload-identity.md) |
| Harden my runners for production | [11 — Security Hardening](11-security-hardening.md) |
| Monitor and troubleshoot runners | [12 — Monitoring & Maintenance](12-monitoring-maintenance.md) |
| See example workflows | [13 — Sample Workflows](13-sample-workflows.md) |
| Manage runner groups for my enterprise | [14 — Advanced Enterprise](14-advanced-enterprise.md) |

---

## 🖥️ Platform Compatibility Matrix

| Feature | Azure VM | ACI | AKS + ARC |
|---------|:--------:|:---:|:---------:|
| Docker builds | ✅ | ❌ | ✅ (DinD) |
| Service containers | ✅ | ❌ | ✅ |
| Persistent caching | ✅ | ❌ | ✅ (PVC) |
| Auto-scaling | Manual | Limited | ✅ Native |
| Ephemeral runners | Via script | ✅ | ✅ |
| Custom tools | ✅ | Image only | Image only |
| GPU workloads | ✅ | ✅ | ✅ |
| Private networking | ✅ VNet | ✅ VNet | ✅ VNet |

---

## 📁 Supporting Files

| Directory | Contents |
|-----------|----------|
| `bicep/` | Infrastructure as Code templates |
| `scripts/` | Automation scripts |
| `containers/` | Runner container image |
| `k8s/` | Kubernetes manifests |
| `.github/workflows/` | Sample workflows |

---

> **Navigation note:** Each guide includes **⬅️ Previous** / **Next ➡️** navigation links at the bottom for easy sequential reading.

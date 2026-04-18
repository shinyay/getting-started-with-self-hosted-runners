# Getting Started with Self-Hosted Runners on Azure

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://gist.githubusercontent.com/shinyay/56e54ee4c0e22db8211e05e70a63247e/raw/f3ac65a05ed8c8ea70b653875ccac0c6dbc10ba1/LICENSE)
[![GitHub Enterprise Cloud](https://img.shields.io/badge/GitHub-Enterprise%20Cloud-6e40c9?logo=github)](https://docs.github.com/en/enterprise-cloud@latest)

> **From zero to production-ready self-hosted runners — on VMs, containers, and Kubernetes.**

A comprehensive, multi-level tutorial (beginner → advanced) for setting up GitHub Actions self-hosted runners on Azure. Covers Azure VMs, Container Instances, and AKS with Actions Runner Controller — with hands-on Infrastructure as Code, security hardening, and enterprise-grade configurations.

Built for **developers and DevOps engineers** at all levels — whether you're deploying your first runner or architecting a fleet for your organization.

---

## 📖 Overview

This repository contains **14 in-depth guides** spanning **3 Azure compute platforms**, complete with Bicep IaC templates, automation scripts, container images, and ready-to-use sample workflows. You'll learn not just *how* to set up self-hosted runners, but *why* each design decision matters — from networking and authentication to OIDC federation and security compliance.

---

## 🗺️ Learning Paths

Choose the path that matches your goal:

| If you are… | Start here | Then go to… |
|---|---|---|
| 🟢 Brand new to self-hosted runners | [Introduction](docs/01-introduction.md) → [Prerequisites](docs/03-prerequisites.md) → [VM Manual Setup](docs/06-vm-manual-setup.md) | [Sample Workflows](docs/13-sample-workflows.md) |
| 🔧 Want to automate VM provisioning | [Prerequisites](docs/03-prerequisites.md) → [VM Automation](docs/07-vm-automation.md) | [OIDC](docs/10-oidc-workload-identity.md), [Security](docs/11-security-hardening.md) |
| ☸️ Want Kubernetes-based runners | [Prerequisites](docs/03-prerequisites.md) → [Auth Tokens](docs/05-github-auth-tokens.md) → [AKS + ARC](docs/09-aks-arc-setup.md) | [OIDC](docs/10-oidc-workload-identity.md), [Security](docs/11-security-hardening.md) |
| 🔒 Focused on security & compliance | [Networking](docs/04-networking-connectivity.md) → [Auth](docs/05-github-auth-tokens.md) → [OIDC](docs/10-oidc-workload-identity.md) → [Security](docs/11-security-hardening.md) | [Advanced Enterprise](docs/14-advanced-enterprise.md) |

---

## ✨ What's Covered

- ☁️ **3 Azure platforms** — Virtual Machines, Container Instances (ACI), and AKS with Actions Runner Controller
- 📊 **Platform decision guide** — side-by-side comparison with cost analysis to pick the right compute for your workloads
- 🏢 **GitHub Enterprise Cloud features** — runner groups, organization policies, and fine-grained access controls
- 🔐 **OIDC / Workload Identity Federation** — eliminate stored secrets with federated credentials
- 🏗️ **Infrastructure as Code** — fully parameterized Bicep templates for repeatable deployments
- 🛡️ **Security hardening guide** — network isolation, least-privilege, image scanning, and audit logging
- 📈 **Monitoring & troubleshooting** — diagnostics, log collection, and common issue resolution
- 🚀 **6 ready-to-use sample workflows** — CI/CD patterns purpose-built for self-hosted runners

---

## ⚡ Prerequisites

Before you begin, make sure you have:

- [ ] **Azure account** — [free trial](https://azure.microsoft.com/free/) is sufficient to get started
- [ ] **GitHub Enterprise Cloud organization** — required for runner groups and advanced policies
- [ ] **Azure CLI** — `az --version` ([install](https://learn.microsoft.com/cli/azure/install-azure-cli))
- [ ] **GitHub CLI** — `gh --version` ([install](https://cli.github.com/))

> [!TIP]
> See the [full prerequisites guide](docs/03-prerequisites.md) for detailed setup instructions, required permissions, and optional tooling.

---

## 📚 Full Documentation

The complete table of contents for all 14 guides is available at:

👉 **[docs/README.md](docs/README.md)**

---

## 🏗️ Repository Structure

```
├── docs/           # 14 tutorial guides (beginner → advanced)
├── bicep/          # Infrastructure as Code templates (Azure resources)
├── scripts/        # Automation scripts (cloud-init, provisioning)
├── containers/     # Runner container image (Dockerfile + config)
├── k8s/            # Kubernetes manifests (Actions Runner Controller)
└── .github/        # Sample GitHub Actions workflows
```

---

## 📚 References

| Resource | Link |
|----------|------|
| GitHub Docs: Self-hosted runners | [docs.github.com/actions/hosting-your-own-runners](https://docs.github.com/en/actions/hosting-your-own-runners) |
| GitHub Docs: Actions Runner Controller | [docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller) |
| Microsoft Learn: Azure Virtual Machines | [learn.microsoft.com/azure/virtual-machines](https://learn.microsoft.com/azure/virtual-machines/) |
| Microsoft Learn: Azure Kubernetes Service | [learn.microsoft.com/azure/aks](https://learn.microsoft.com/azure/aks/) |
| Microsoft Learn: Azure Container Instances | [learn.microsoft.com/azure/container-instances](https://learn.microsoft.com/azure/container-instances/) |
| GitHub Docs: OIDC with Azure | [docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure) |

---

## ✍️ Author

- github: <https://github.com/shinyay>
- bluesky: <https://bsky.app/profile/yanashin.bsky.social>
- twitter: <https://twitter.com/yanashin18618>
- mastodon: <https://mastodon.social/@yanashin>
- linkedin: <https://www.linkedin.com/in/yanashin/>

## 📄 Licence

Released under the [MIT license](https://gist.githubusercontent.com/shinyay/56e54ee4c0e22db8211e05e70a63247e/raw/f3ac65a05ed8c8ea70b653875ccac0c6dbc10ba1/LICENSE)

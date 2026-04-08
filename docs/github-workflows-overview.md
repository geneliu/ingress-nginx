# GitHub Actions workflows in this repository

Short guide to the YAML files under `.github/workflows/`. Names match the **workflow name** shown in the Actions tab.

## How GitHub knows which workflow to run

GitHub does **not** choose a single workflow for the whole repo.

- Every file in `.github/workflows/` that is valid workflow YAML becomes a **separate** workflow.
- Each file has its own **`name:`** (shown in the **Actions** tab) and its own **`on:`** block (**triggers**).
- When something happens (push, PR, schedule, manual run), GitHub checks **each** workflow: if the event matches that workflow's `on:` rules, **that** workflow runs. Several workflows can run for the **same** event if they all match.

So **`dockerhub-publish.yaml`** runs only when its triggers fire, for example:

- You open **Actions**, select **Publish controller and Helm chart to Docker Hub**, and click **Run workflow** (`workflow_dispatch`), or
- Someone **pushes a git tag** that matches `v*` (see the `on.push.tags` section in that file).

It does **not** replace **`ci.yaml`**. If you push a branch and `ci.yaml` matches (e.g. push to `main`), CI still runs. If you only push a commit without a `v*` tag, **`dockerhub-publish.yaml` does not run** unless you start it manually.

To use your Docker Hub pipeline, either run it **manually** or **push a `v*` tag** (aligned with the `TAG` file in the repo root).

## Your fork-specific workflow

| File | Purpose |
|------|---------|
| `dockerhub-publish.yaml` | Builds the **linux/amd64** controller image, pushes to **Docker Hub**, packages the **ingress-nginx** Helm chart, pushes chart as **OCI**, runs **Trivy** on the published image, and uploads SARIF (see file header comments). |

## Upstream workflows (from kubernetes / Chainguard lineage)

| File | Triggers (typical) | Purpose |
|------|-------------------|---------|
| `ci.yaml` | PR, push to `main` / `release-*`, `workflow_dispatch` | Main **CI**: path filters, **Go tests**, **Lua** lint, **build** controller image (amd64) as tarball artifact, **Helm chart** lint and **kind** chart tests, **Kubernetes e2e** matrices. Heavy; uses reusable templates `zz-tmpl-k8s-e2e.yaml`. |
| `images.yaml` | PR/push when `images/**` changes | Builds **sidecar** images (nginx base, kube-webhook-certgen, etc.) via `zz-tmpl-images.yaml`. Not the main controller image from `make image` at repo root. |
| `chart.yaml` | Push when `Chart.yaml` changes, `workflow_dispatch` | **Chart lint** (ct, Artifact Hub) and **chart-releaser** GitHub releases. Uses `GITHUB_TOKEN` to publish releases; behavior is oriented to the **upstream** repo. |
| `vulnerability-scans.yaml` | Weekly cron, **release**, `workflow_dispatch` | **Trivy** scan of **`registry.k8s.io/ingress-nginx/controller:<tag>`** for the **latest three** git tags matching `controller-v*.*.*`. Uploads **SARIF** to GitHub code scanning. **Often not useful on a fresh fork** until those tags exist (see below). |
| `scorecards.yml` | Push to `main`, weekly, branch protection | **OpenSSF Scorecard** supply-chain report and SARIF upload. |
| `depreview.yaml` | **pull_request** | **Dependency Review** (GitHub) for PR dependency changes. |
| `golangci-lint.yml` | (check file) | Go static analysis. |
| `docs.yaml` | Push to `main` | Doc updates; upstream may gate on `github.repository == 'kubernetes/ingress-nginx'` so it **no-ops** on forks. |
| `perftest.yaml` | (check file) | Performance tests. |
| `plugin.yaml` | (check file) | Plugin-related CI. |
| `junit-reports.yaml` | (check file) | Test report aggregation. |
| `project.yml` | (check file) | Project automation / bot config consumed by tooling, not a full CI graph by itself. |
| `zz-tmpl-images.yaml` | Called by `images.yaml` | Reusable workflow to build one image under `images/`. |
| `zz-tmpl-k8s-e2e.yaml` | Called by `ci.yaml` | Reusable **e2e** job against a **kind** cluster. |

## Upstream `vulnerability-scans.yaml` on a personal fork

That workflow:

1. Lists git tags matching **`controller-v*.*.*`** (excluding alpha/beta).
2. Takes the **newest three** and scans **`registry.k8s.io/ingress-nginx/controller:<short-version>`**.

So it scans **upstream published images**, not your Docker Hub build. On a fork with **no** `controller-v*` tags, the version job can produce an **empty or broken matrix**.

**Options:**

- Keep it and **fetch upstream tags** into your fork if you want the same scans as upstream, or
- Rely on **Trivy** in `dockerhub-publish.yaml`, which scans **`docker.io/<you>/controller:<TAG>`** after you push (aligned with what you actually ship).

## Permissions note (SARIF / code scanning)

`vulnerability-scans.yaml` and Trivy upload steps use **`security-events: write`** to upload SARIF. On **public** repositories this usually works for the **Security** tab. **Private** repos may need **GitHub Advanced Security** (paid). If upload fails, Trivy still prints findings in the job log; you can also attach SARIF as a **workflow artifact**.

## Disabling noisy upstream workflows on a fork

If CI uses too many minutes, you can disable individual workflows in **Actions** (workflow menu) or delete/rename files you do not need. Keep **`dockerhub-publish.yaml`** for your publish and scan path.

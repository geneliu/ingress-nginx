# Publish controller image and Helm chart to Docker Hub

This fork includes [`.github/workflows/dockerhub-publish.yaml`](../.github/workflows/dockerhub-publish.yaml), which:

1. Runs `make build` and `make image` for **linux/amd64** and pushes **`docker.io/<user>/controller:<TAG>`** (`TAG` comes from the repo root file `TAG`).
2. Runs **Trivy** on that published image, uploads **SARIF** to GitHub code scanning (if enabled), and attaches SARIF as a workflow **artifact**.
3. Patches `charts/ingress-nginx/values.yaml` so the default controller image is that Docker Hub image, packages the chart, and **`helm push`**es it to **Docker Hub OCI** (`oci://registry-1.docker.io/<user>`).

For a map of **all** workflow YAML files (including upstream `vulnerability-scans.yaml`), see [`github-workflows-overview.md`](github-workflows-overview.md).

## Secrets (prepare before first workflow run)

The workflow reads exactly two **repository** secrets. Names are case-sensitive.

| Secret name | What to put there |
|-------------|-------------------|
| `DOCKERHUB_USERNAME` | Your Docker Hub **username** (or the **organization** name if the image will live under an org). Same value you use to log in at hub.docker.com. |
| `DOCKERHUB_TOKEN` | A Docker Hub **access token** (not your account password). Used for `docker login`, `helm registry login`, and Trivy pull if the image is private. |

### 1. Create a Docker Hub access token

1. Log in at https://hub.docker.com/
2. Open **Account Settings** (avatar menu) then **Personal access tokens**  
   Direct link: https://hub.docker.com/settings/security
3. **Generate new token**
4. Give it a label (for example `github-actions-ingress-nginx`)
5. **Access permissions:** choose **Read, Write, Delete** (or the closest your UI offers that includes **write**). The workflow must **push** images and **push** Helm charts as OCI; read-only tokens will fail.
6. Copy the token **once** when shown. Store it in a password manager until you paste it into GitHub.

**Notes**

- If you use **2FA** on Docker Hub, you **must** use a token; the workflow cannot use your login password interactively.
- Pushing to `docker.io/<username>/controller` creates the repository on first push if your account allows it.
- **Org namespaces:** use the **org** name as `DOCKERHUB_USERNAME` only if the org allows your user (or a bot account) to push there; create the token for that account.

### 2. Add secrets in GitHub

1. Open your **fork** on GitHub (the repo that will run the workflow).
2. **Settings** > **Secrets and variables** > **Actions**
3. **New repository secret** (not *Environment* secrets unless you choose to use environments later).
4. Add **`DOCKERHUB_USERNAME`** = your Docker Hub user or org name (no `docker.io/`, no spaces).
5. Add **`DOCKERHUB_TOKEN`** = the full token string from step 1.

Do **not** commit tokens or put them in the YAML file. After saving, GitHub only shows secret names, not values.

### 3. Quick local check (optional)

From your laptop, confirm the token can push to your namespace:

```bash
echo "<TOKEN>" | docker login -u "<USERNAME>" --password-stdin
docker pull hello-world
docker tag hello-world docker.io/<USERNAME>/controller:test-login
docker push docker.io/<USERNAME>/controller:test-login
```

Remove the test tag/repo in Docker Hub if you do not want to keep it.

## Run

- **Actions** tab: workflow **Publish controller and Helm chart to Docker Hub** > **Run workflow**, or
- Push a **git tag** matching `v*` (for example `v1.15.0`).

## Install examples

Replace `<user>`, `<TAG>`, and chart version from `charts/ingress-nginx/Chart.yaml`.

```bash
# Controller image (for custom values)
docker pull docker.io/<user>/controller:<TAG>

# Chart from Docker Hub OCI
helm install nginx-ingress oci://registry-1.docker.io/<user>/ingress-nginx --version <chart version>
```

If OCI push fails on your Docker Hub plan, download the **helm-chart-tgz** artifact from the workflow run and `helm install ./ingress-nginx-*.tgz`.

## NSP overlay

The **cn-nsp-ingress** chart is separate; install the base release as **`nginx-ingress`** first, then apply the NSP overlay.

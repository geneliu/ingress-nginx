# Build helpers

Scripts in this directory support compiling the ingress-nginx controller and related workflows. The main entry point for a normal compile is **`make build`** from the repository root, which calls **`run-in-docker.sh`** and then **`build/build.sh`** inside a container.

## `run-in-docker.sh`

Runs a command inside the image given by **`E2E_IMAGE`**. The script default is a pinned test-runner image; **`make build`** overrides this with **`golang:<GOLANG_VERSION>-alpine`** from the root Makefile.

### Container engine

- **`RUNTIME`** (default `docker`): set to **`podman`** on hosts that use Podman instead of Docker (for example macOS with Podman Machine).
- The Makefile sets **`RUNTIME=$(RUNTIME)`** for **`make build`**. Override on the command line:

  ```bash
  make build RUNTIME=podman ARCH=arm64
  ```

- When **`RUNTIME=docker`**, the script mounts **`/var/run/docker.sock`** into the build container. That mount is omitted for Podman.

### Podman and image references

If **`RUNTIME=podman`**, the script strips the digest from **`E2E_IMAGE`** because Podman does not accept tag and digest together in the same reference.

### Corporate HTTP(S) proxy

The script forwards these host environment variables into the build container **only when each one is set** (it adds one **`-e NAME=value`** per non-empty variable):

`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, lowercase forms, `ALL_PROXY`, **`GOPROXY`**, **`GOPRIVATE`**, **`GOSUMDB`**.

Set them before **`make build`** so module downloads work behind a proxy. For the full **`local-patch-artifacts`** flow, see [Proxy when using local-patch-artifacts](#proxy-when-using-local-patch-artifacts) below.

### Platform

- **`PLATFORM`** (optional): passed through as **`docker run --platform ...`** / **`podman run --platform ...`** (for example cross-building from Apple Silicon).

### macOS

On Darwin, a temporary directory under **`tmp/`** in the repo is used for the ingress volume mount to avoid some tmpfs edge cases.

## `build.sh`

Invoked **inside** the container. Expects **`PKG`**, **`ARCH`**, **`COMMIT_SHA`**, **`REPO_INFO`**, and **`TAG`**. Produces binaries under **`rootfs/bin/${ARCH}`**.

## Root Makefile integration

From the repo root:

| Target | Notes |
|--------|--------|
| **`make build`** | Containerized compile; uses **`RUNTIME`** (see above). |
| **`make image`** | Builds the controller image; uses **`DOCKER`** (default `docker`). Use **`DOCKER=podman`** with Podman. |
| **`ARCH`**, **`PLATFORM`**, **`TAG`**, **`REGISTRY`** | Standard variables for arch, platform, version string, and image prefix. |
| **`RUNTIME_BASE_IMAGE`** | **`make image-chroot`** only: final-stage Alpine ref (**`rootfs/Dockerfile-chroot`**). Default **`alpine:3.23.3`**. Set to an internal mirror if **`podman build`** cannot verify **docker.io** TLS (same corporate CA story as [TLS when pulling images](#tls-when-pulling-images)). |
| **`CHROOT_DEV_PLATFORM`** | **`make image-chroot`** / **`make release`**: **`linux/<arch>`** for the **`chroot-devices`** Dockerfile stage (creates **`/chroot/dev`** nodes). Default **`linux/$(go env GOARCH)`**. Must match the **container engine host** (Podman Machine arch on Mac), not **`ARCH`** when cross-building (see **`build/image-inventory.md`**). |
| **`CHROOT_IMAGE_BUILD_FLAGS`** | **`make image-chroot`** with **`DOCKER=podman`** only: defaults to **`--security-opt seccomp=unconfined --cap-add CAP_MKNOD`** so **`mknod`** works under **rootless** Podman and under QEMU cross-builds. Clear with **`CHROOT_IMAGE_BUILD_FLAGS=`** if your policy forbids it (then use **rootful** Podman; see **`build/developer-tricks.md`**). |
| **`make local-patch-artifacts`** | Patch/CVE-style local flow: Podman, no registry push, controller image + Helm chart tarball (see **`hack/ci/jenkins-controller-publish.sh`**). |
| **`make ci-publish`** | Same script with registry credentials (CI or laptop push). |

### Local development: `make local-patch-artifacts`

Typical local loop: controller image plus a Helm chart **`.tgz`** with no registry push. The Makefile sets **`SKIP_PUSH=1`**, **`RUNTIME=podman`**, and **`DOCKER=podman`**. The chart is written under **`dist/patch-artifacts/`**.

- **Apple Silicon (for example M4), cluster nodes are `linux/amd64`:** cross-build and match cluster arch (slower than native because of emulation):

  ```bash
  ARCH=amd64 PLATFORM=linux/amd64 make local-patch-artifacts
  ```

- **Same machine, native image (faster):** use **`ARCH=arm64`** and omit **`PLATFORM`** unless you need a specific platform.

**Environment:** The recipe runs **`hack/ci/jenkins-controller-publish.sh`** in a shell that **inherits your current environment**. You do not need to teach the Makefile about proxy or Go module settings: if a variable is **set** in that shell, child steps see it; if **unset**, nothing is injected for it. The Go build step still only forwards variables into the container when each is non-empty (see **`run-in-docker.sh`** above).

### Proxy when using local-patch-artifacts

| Step | What to do |
|------|------------|
| **`go mod` / compile inside the build container** | Export **`HTTP_PROXY`**, **`HTTPS_PROXY`**, **`NO_PROXY`** (and lowercase forms if you use them), plus optional **`GOPROXY`**, **`GOPRIVATE`**, **`GOSUMDB`** on the host before **`make`**. **`run-in-docker.sh`** passes through **only variables that are set**. |
| **Helm / yq download in the publish script** | Same exports; **`curl`** uses your proxy env. **`jenkins-controller-publish.sh`** normalizes upper- and lowercase proxy names. |
| **`podman build` / base image pulls** | Pulls go through the container engine. On macOS with Podman Machine, configure proxy for the **machine / daemon** if pulls still fail; host exports alone are not always enough. If you see **`x509: certificate signed by unknown authority`**, add your corporate root CA inside the Podman machine (see [TLS when pulling images](#tls-when-pulling-images)). |

Example:

```bash
export HTTP_PROXY=http://proxy.example.com:8080
export HTTPS_PROXY=http://proxy.example.com:8080
export NO_PROXY=localhost,127.0.0.1,.example.corp

# Optional (corporate Go module policy):
# export GOPROXY=https://proxy.golang.org,direct
# export GOPRIVATE=*.example.corp
# export GOSUMDB=sum.golang.org

ARCH=amd64 PLATFORM=linux/amd64 make local-patch-artifacts
```

### TLS when pulling images

If **`podman`** fails while pulling (for example **`golang:...`** from Docker Hub) with **`tls: failed to verify certificate: x509: certificate signed by unknown authority`**, traffic is often going through a **corporate HTTPS proxy** that re-signs TLS. Your Mac may trust that CA, but the **Podman machine** (Linux VM) uses its **own** CA bundle, so registry checks fail until you add the corporate **root CA** there.

1. Get the corporate root CA as a **`.pem`** file (IT / security documentation). If you already exported a chain while viewing **`https://github.com`** (for example **`github-com-chain.pem`** in **`~/Downloads`**), that file is usually the **same** inspection CA your network uses for **Docker Hub** and other HTTPS; you can install **that** PEM into the Podman machine (one file may contain several **`BEGIN CERTIFICATE`** blocks; **`update-ca-trust`** picks them up).
2. Install it into the machine and refresh trust (Fedora-style paths used by many Podman machines):

   ```bash
   cat /path/to/corp-root-or-chain.pem | podman machine ssh sudo tee /etc/pki/ca-trust/source/anchors/corp-ca.pem >/dev/null
   podman machine ssh sudo update-ca-trust extract
   ```

3. Retry **`podman pull golang:1.26.1-alpine3.23`**, **`podman pull alpine:3.23.3`**, or your **`make`** command.

**Chroot image:** **`make image-chroot`** uses a multi-stage Dockerfile; stage 1 is **`BASE_IMAGE`** (nginx base), stage 2 pulls **`RUNTIME_BASE_IMAGE`** (default **`alpine:3.23.3`**) from Docker Hub. If only the Alpine pull fails, either fix Podman-machine trust as above or build with **`RUNTIME_BASE_IMAGE=your.registry.example/library/alpine:3.23.3`** (mirrored image).

You may need to repeat step 2 after **`podman machine init`** / a new VM.

Do **not** turn off TLS verification for Docker Hub or other registries (for example **`insecure = true`** drop-ins under **`registries.conf.d`**). Fix trust with the steps above. If you ever added such a file while debugging, remove it from the Podman machine.

#### If you cannot get the root CA from IT

You can often **export the issuing CA yourself** (same cert the proxy uses):

- **Browser:** open **`https://registry-1.docker.io`** (or any HTTPS site that fails the same way), open the site certificate details, open the **top / root** entry in the chain, export as **Base64 / PEM** (wording varies by browser).
- **Command line:** run **`openssl s_client -connect registry-1.docker.io:443 -showcerts`** (with proxy vars set if required), copy the **last** certificate block in the output (often the corporate root) into a **`.pem`** file, then use step 2 above.

## Other scripts (short)

- **`dev-env.sh`** - Local development environment helpers.
- **`run-ingress-controller.sh`** - Run the controller binary against a cluster (see script header).
- **`kind.yaml`** - Kind cluster configuration used by some tests.
- **`cover.sh`** - Coverage helper for tests.

## Related documentation

- Images to own after upstream archive (nginx base, controller, chroot, certgen, default backend): **`build/image-inventory.md`**
- Local macOS / Podman / TLS / Trivy tips: **`build/developer-tricks.md`**
- Patch publish pipeline (Jenkins, proxy, **`SKIP_PUSH`**, Mac): **`hack/ci/jenkins-controller-publish.sh`** header comments and repository **`Jenkinsfile`**.

# Developer tricks (local builds, Podman on macOS)

Tips for **local** controller image builds, TLS behind corporate proxies, and scanning. For the main build flow see **`build/README.md`**.

### Why upstream GitHub Actions is fine but your Mac is not

**GitHub-hosted runners** sit on a network path that usually does **not** use your employer’s **TLS inspection** (HTTPS MITM). Pulls and **`curl`** to Docker Hub, GitHub, **nginx.org**, and similar endpoints validate with the **default public CA** bundle. No extra certs are required.

Your **laptop** on a **corporate** network often hits a **proxy that re-signs TLS** with an **internal CA**. That is unrelated to “we both use containers”: each place has its **own** trust store (**macOS Keychain**, **Podman machine**, **golang build container**, **Alpine layer in `podman build`**). Fixing trust in one layer **does not** copy it to the others. **Self-hosted** runners inside the same corp network would typically need the **same** kind of CA injection unless builds use internal mirrors.

---

## 1. TLS: `x509: certificate signed by unknown authority` on image pulls

### What you see

`podman pull` or **`make build`** fails when pulling (for example **`golang:...`** from Docker Hub) with:

`tls: failed to verify certificate: x509: certificate signed by unknown authority`

### Why it happens

HTTPS to the registry often goes through a **corporate SSL inspection** proxy. Your **Mac** may trust the corporate CA (Keychain), but **Podman Machine** is a separate Linux VM with its **own** CA bundle. Until that VM trusts your corporate root (or issuing CA), registry TLS verification fails.

**Nginx base image build:** **`podman build`** for **`images/nginx/rootfs`** runs **`build.sh`** inside an **Alpine container**. That environment has its **own** CA store again. If **`curl`** fails with verify errors when downloading from **GitHub** during the nginx image build, add your **`.pem`** files under **`images/nginx/rootfs/build-certs/`** (see **`build-certs/README.md`** in that directory).

### Fix A (recommended): trust the corporate CA inside Podman Machine

1. Obtain the CA as a **`.pem`** file (IT, or export from browser / Keychain; see below). A chain saved from **`https://github.com`** (for example **`~/Downloads/github-com-chain.pem`**) is often the **corporate root or chain** used for **all** inspected HTTPS, including **registry-1.docker.io**; you can use that same file for the Podman machine anchors below (and copy it into **`images/nginx/rootfs/build-certs/`** for the nginx image build if **`curl`** fails there too).
2. Install and refresh trust on the VM:

   ```bash
   cat /path/to/corp-root-ca.pem | podman machine ssh sudo tee /etc/pki/ca-trust/source/anchors/corp-root-ca.pem >/dev/null
   podman machine ssh sudo update-ca-trust extract
   ```

3. Retry **`podman pull`** / **`make`**.

Repeat after **`podman machine init`** if you recreate the VM.

Do **not** use **`insecure = true`** registry overrides for Docker Hub on the Podman machine. Rely on **CA trust** only. If you still have a leftover **`registries.conf.d`** drop-in from old troubleshooting, remove it (for example **`sudo rm -f /etc/containers/registries.conf.d/999-insecure-dockerhub.conf`** inside **`podman machine ssh`**).

### Browser export (when IT does not hand you a PEM)

Export the **CA that signs the inspected TLS traffic**, not only the website leaf certificate.

**Firefox (often easiest on macOS):**

1. Open `https://registry-1.docker.io` (or any HTTPS site that uses the same proxy).
2. Lock icon -> **Connection secure** -> **More information** -> **View Certificate**.
3. Open the **chain** / hierarchy tab. Select the **root** at the top, or the **corporate issuing** certificate (the one above the site leaf that is **not** a public CA like DigiCert).
4. Download or export as **PEM** if offered. If you only get **DER** (`.crt`), convert:

   ```bash
   openssl x509 -inform DER -in ~/Downloads/cert.crt -out ~/Downloads/corp-ca.pem
   ```

**macOS Keychain Access:**

1. Open **Keychain Access**, search for your **company** or the **issuer name** you see in the browser chain.
2. Export the matching **certificate** as **`.pem`** or **`.cer`**, then convert with **`openssl x509`** if needed (same as **`build/README.md`** TLS section).

**Sanity check:**

```bash
openssl x509 -in ~/Downloads/corp-ca.pem -noout -subject -issuer
```

### Fix B: OpenSSL through the proxy

If the UI is awkward, with **`HTTPS_PROXY`** / **`HTTP_PROXY`** set as your network requires:

```bash
openssl s_client -proxy "$HTTPS_PROXY" -connect registry-1.docker.io:443 -showcerts </dev/null 2>/dev/null \
  | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/chain.pem
```

That file may contain **multiple** PEM blocks. Often the **last** block is the **root**; sometimes you need the **corporate intermediate** instead. Copy one block into **`corp-ca.pem`** and try **Fix A**.

More context: **`build/README.md`** (TLS when pulling images).

---

## 2. Trivy: Podman on Mac vs default Docker socket

### Symptom

```text
trivy image localhost/ingress/controller:v1.15.2
...
docker error: Cannot connect to the Docker daemon at unix:///var/run/docker.sock
podman error: no podman socket found: stat podman/podman.sock: no such file or directory
remote error: ... UNAUTHORIZED ...
```

Trivy probes **Docker**, **containerd**, **Podman**, then treats the name as a **remote** registry. On macOS, Podman’s engine is not on **`/var/run/docker.sock`**, and Trivy’s default Podman socket path does not match the Mac layout, so the image is never found.

### Fix A: point `DOCKER_HOST` at Podman’s API socket

Podman exposes a **Docker-compatible** API on a Unix socket. Set **`DOCKER_HOST`** in the same shell before **`trivy`**:

```bash
export DOCKER_HOST="unix://$(podman machine inspect podman-machine-default --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
trivy image localhost/ingress/controller:v1.15.2
```

If your machine name is not **`podman-machine-default`**, use **`podman machine list`** and substitute.

### Fix B: scan a tarball (no socket coupling)

```bash
podman save -o /tmp/ingress-controller.tar localhost/ingress/controller:v1.15.2
trivy image --input /tmp/ingress-controller.tar
```

Useful in CI or when **`DOCKER_HOST`** is awkward.

### Faster scans

```bash
trivy image --scanners vuln localhost/ingress/controller:v1.15.2
```

### `local-patch-artifacts` and Trivy

**`hack/ci/jenkins-controller-publish.sh`** runs Trivy **after** the image build **only if** **`trivy`** is on **`PATH`** and **`SKIP_TRIVY`** is not set. If Trivy is missing, you only get a message; no scan runs. Silence the hint with **`SKIP_TRIVY=1`**.

---

## 3. Other image checks (no Trivy)

| Goal | Example |
|------|---------|
| **Metadata** (labels, arch, config) | `podman inspect localhost/ingress/controller:v1.15.2` |
| **Layer history** | `podman history localhost/ingress/controller:v1.15.2` |
| **Interactive shell** (if image allows) | `podman run --rm -it --entrypoint /bin/sh localhost/ingress/controller:v1.15.2` (controller image may use **`USER www-data`**; add **`--user 0`** only for debugging, then remove from any production pattern) |
| **Layer tree UI** | [dive](https://github.com/wagoodman/dive) **`dive localhost/ingress/controller:v1.15.2`** |

**`cosign`** / **`sigstore`**: verify signatures on **published** upstream images; your locally built **`localhost/ingress`** image will not match upstream signatures unless you sign it yourself.

---

## 4. Controller-chroot image: `mknod: Operation not permitted` (Podman)

**`rootfs/Dockerfile-chroot`** creates **`/chroot/dev/*`** device nodes in the **`chroot-devices`** stage. **Rootless** Podman (common on macOS) often denies **`mknod(2)`** even when that stage uses your **native** **`linux/arm64`** image, so the build fails before the final **`COPY --from=chroot-devices`**.

**Fix A (Makefile default):** **`make image-chroot DOCKER=podman`** passes **`--security-opt seccomp=unconfined --cap-add CAP_MKNOD`** (**`CHROOT_IMAGE_BUILD_FLAGS`**). Retry your build.

**Fix B:** Run the Podman machine **rootful** so builds are not stuck in a user namespace that blocks device creation:

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

Then **`make image-chroot ... DOCKER=podman`** again. Revert with **`podman machine set --rootful=false`** if you prefer rootless for normal work.

**Fix C:** Build the chroot image with **Docker Desktop** (or a **Linux** host with rootful **`docker build`**) if you cannot change Podman settings.

More context: **`CHROOT_DEV_PLATFORM`**, **`CHROOT_IMAGE_BUILD_FLAGS`**, **`build/README.md`** (Root Makefile integration table), **`build/image-inventory.md`**.

---

## 5. Podman Machine must be running

If you see **connection refused** to **`127.0.0.1:...`** when running **`podman`** or **`make`**:

```bash
podman machine start
```

---

## See also

- **`build/README.md`** - build flow, proxy, TLS, **`local-patch-artifacts`**
- **`hack/ci/jenkins-controller-publish.sh`** - patch pipeline, **`SKIP_TRIVY`**, **`SKIP_PUSH`**

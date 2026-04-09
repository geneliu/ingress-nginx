# Container images to own after upstream archive

The upstream project [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx) was archived (read-only) in March 2026. Official text says **no further releases or security fixes**; **existing** charts and images remain available but **will not be updated**.

If you run ingress-nginx from a **fork**, plan to **build or mirror** every image your clusters actually pull. Below is the usual production set and where it comes from in **this** repository.

## Images central to the controller

| Published name (typical) | Role | In this repo? | Notes |
|--------------------------|------|---------------|--------|
| **`ingress-nginx/nginx`** | Base layer for controller (patched nginx, modules, Alpine) | **Yes** | **`images/nginx/`** (see **`images/nginx/cloudbuild.yaml`**). Version / checksums in **`images/nginx/rootfs/build.sh`**. **`NGINX_BASE`** in the repo root points at the tag/digest you build against. |
| **`ingress-nginx/controller`** | Main ingress controller | **Yes** | **`make build`** then **`make image`** (or your **`local-patch-artifacts`** flow). Uses **`BASE_IMAGE`** (**`NGINX_BASE`**). |
| **`ingress-nginx/controller-chroot`** | Controller variant when **`controller.image.chroot: true`** | **Yes** | **`make image-chroot`** (**`rootfs/Dockerfile-chroot`**). |

Rebuild the **nginx** base when nginx/Alpine/module CVEs require it, then rebuild **controller** (and **chroot** if you use it) on that new base.

## Admission webhooks

| Published name (typical) | Role | In this repo? | Notes |
|--------------------------|------|---------------|--------|
| **`ingress-nginx/kube-webhook-certgen`** | Helm Jobs that create/patch webhook TLS material | **Yes** | **`images/kube-webhook-certgen/`** (**`images/kube-webhook-certgen/cloudbuild.yaml`**). |

You **do not** need a running cluster workload for this image; only short-lived **Jobs** use it.

If Helm has **`controller.admissionWebhooks.certManager.enabled: true`**, the chart **does not** render those Jobs, so clusters may **never pull** certgen. Confirm with **`helm template ... | grep kube-webhook-certgen`**. You still might keep a **mirror** of certgen for installs that do not use that flag.

## Default backend (optional)

If **`defaultBackend.enabled: true`** and you set **`defaultBackend.image.repository`** (and tag) to **your own** image, you **do not** need upstream **`registry.k8s.io/defaultbackend-amd64`** for maintenance in this fork. You already own that workload image elsewhere.

| Published name (typical) | Role | In this repo? | Notes |
|--------------------------|------|---------------|--------|
| **`defaultbackend-amd64`** (under **`registry.k8s.io`**) | Chart **default** when you enable default backend but do not override the image | **No Dockerfile in this repo** | Only relevant if you rely on this upstream name. Otherwise override in Helm and ignore. |

Default backend is **disabled** in chart defaults (**`defaultBackend.enabled: false`**). Many clusters omit it or use a **custom** image in values.

## Images you usually do **not** need for production ingress

These live under **`images/`** or **`test/`** for **tests**, **examples**, or **CI** (for example **test-runner**, **httpbun**, **cfssl**, **e2e** images). You only maintain them if your pipeline or docs depend on them.

## Practical checklist

1. **Pin or build** **`ingress-nginx/nginx`** (base), then **controller** and **controller-chroot** (if used).
2. Decide **cert-manager for admission webhooks** vs **certgen Jobs**; mirror/build **kube-webhook-certgen** if Jobs still appear in rendered manifests.
3. If **default backend** is enabled: either use **your own** image in **`defaultBackend.image`** (nothing to do here for **`defaultbackend-amd64`**), or **mirror** upstream **`defaultbackend-amd64`** if you still reference it.
4. Point Helm **`values.yaml`** at **your** registry for each image you own.

## Rebuild all needed images (no default backend)

**By itself**, **`make local-patch-artifacts`** only produces the **controller** image plus a Helm chart tarball. It does **not** build the **nginx base**, **controller-chroot**, or **kube-webhook-certgen**. Use the full sequence below when you want **all** of those (except default backend).

Assume **`REGISTRY=localhost/ingress`**, **`linux/amd64`**, and **Podman** (**`DOCKER=podman`**) like your successful controller build. Adjust **`REGISTRY`**, **`ARCH`**, **`PLATFORM`**, and **`DOCKER`** for your environment.

### 1. Nginx base (optional)

Skip this if you still build the controller against the existing **`NGINX_BASE`** (upstream or already mirrored).

The nginx image is a **long** compile (**`images/nginx/rootfs/`**). Build and tag it to match what you will reference from **`NGINX_BASE`**:

```bash
# From the repository root; tag should match images/nginx/TAG or your policy
NGINX_TAG=$(cat images/nginx/TAG)
podman build --platform linux/amd64 \
  -t localhost/ingress/nginx:${NGINX_TAG} \
  -f images/nginx/rootfs/Dockerfile \
  images/nginx/rootfs
```

**Corporate TLS inspection:** Trust on the Podman machine does **not** apply inside the **build container**. If **`curl: (60) SSL certificate`** appears while **`build.sh`** fetches from GitHub, copy your corporate **`.pem`** into **`images/nginx/rootfs/build-certs/`** (see **`build-certs/README.md`**; **`*.pem`** is gitignored), then rebuild.

Set the repo root **`NGINX_BASE`** file to that reference (for example **`localhost/ingress/nginx:v2.2.9`** or tag plus digest after you push and pin).

### 2. Controller image and Helm chart tarball

**`local-patch-artifacts`** runs **`make build`** and **`make image`** and packages the chart (same flow you used for **`localhost/ingress/controller:v1.15.2`**):

```bash
REGISTRY=localhost/ingress ARCH=amd64 PLATFORM=linux/amd64 make local-patch-artifacts
```

### 3. Controller chroot (only if you use chroot mode)

Chroot is a **separate** image and is **not** built by **`local-patch-artifacts`**. It reuses binaries already in **`rootfs/bin/${ARCH}/`** from step 2.

```bash
REGISTRY=localhost/ingress-nginx make image-chroot ARCH=amd64 PLATFORM=linux/amd64 DOCKER=podman
```

If **`podman build`** fails pulling **`alpine:3.23.3`** with **x509** against **docker.io**, install the corporate CA in the Podman machine (**`build/README.md`**, TLS section) or mirror Alpine and set **`RUNTIME_BASE_IMAGE`** (for example **`RUNTIME_BASE_IMAGE=corp.example/docker-mirror/library/alpine:3.23.3`**).

**`/chroot/dev` device nodes:** **`Dockerfile-chroot`** builds them in a **`chroot-devices`** stage on **`CHROOT_DEV_PLATFORM`** (default **`linux/$(go env GOARCH)`**) so **`mknod`** does not run in the **QEMU-emulated** final stage when you set **`PLATFORM=linux/amd64`** on Apple Silicon. **Rootless Podman** can still deny **`mknod`** in that native stage; **`DOCKER=podman`** adds **`CHROOT_IMAGE_BUILD_FLAGS`** (**`seccomp=unconfined`** and **`CAP_MKNOD`**). If you still see **`Operation not permitted`**, use **rootful** Podman Machine (**`build/developer-tricks.md`**, section 4).

Skip this if **`controller.image.chroot`** is **false**.

### 4. kube-webhook-certgen

Independent of nginx; uses **Go** + **distroless**. Tag comes from **`images/kube-webhook-certgen/TAG`**.

```bash
CERTGEN_TAG=$(cat images/kube-webhook-certgen/TAG)
GOLANG_VERSION=$(cat GOLANG_VERSION)
podman build --platform linux/amd64 \
  --build-arg "GOLANG_VERSION=${GOLANG_VERSION}" \
  -t "localhost/ingress/kube-webhook-certgen:${CERTGEN_TAG}" \
  -f images/kube-webhook-certgen/rootfs/Dockerfile \
  images/kube-webhook-certgen/rootfs
```

If you use **cert-manager** for admission webhook certs (**`controller.admissionWebhooks.certManager.enabled: true`**) and your rendered manifests **do not** reference certgen, you can skip this image for clusters that never pull it.

### 5. Helm values

Point **`values.yaml`** (or overlays) at your registry for:

- **`controller.image`** (and **`digest`** / **`digestChroot`** if you use them)
- **`controller.admissionWebhooks.patch.image`** if Jobs still use certgen
- **`controller.image.chroot`** and chroot-specific digest if you use the chroot image

Do **not** change default backend if you already use **your own** image there.

### 6. Push and deploy

Tag only exists locally until you **`podman push`** (or your CI pushes) to the registry your cluster uses. Then **`helm upgrade`** (or install) with updated values.

## Related docs

- **`build/README.md`** - local build and **`local-patch-artifacts`**
- **`build/developer-tricks.md`** - Podman, TLS, Trivy
- **`MANUAL_RELEASE.md`** - historical upstream release and nginx base rebuild notes

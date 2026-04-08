# Changelog

### controller-v1.15.2

Patch release: dependency updates (see `go.mod` / `go.sum`) and chart `4.15.2` (appVersion `1.15.2`).

Images for this fork are published via CI (for example Docker Hub `controller:v1.15.2` when using `dockerhub-publish.yaml`). Upstream `registry.k8s.io` digests are not updated in this fork unless you promote images there.

### All changes:

* Go: dependency updates aligned with maintenance branch work.
* Helm: chart `4.15.2` default controller image tag `v1.15.2`.

**Full Changelog**: compare `v1.15.1..v1.15.2` on this repository.

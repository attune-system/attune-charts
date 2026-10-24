# Central acceptance image inputs

Each `images.<component>.digest` accepts an actual OCI manifest digest and takes
precedence over its tag. Keep it empty until the matching compatible image exists.
The existing registry/namespace/repository selection still applies. For example,
the central operator supplies `images.api.digest=sha256:<measured 64 hex>` and
the corresponding repository in an owned registry. Never substitute a source
archive checksum or pack archive digest.

`corePack.digest` remains a different value: the measured canonical core pack
archive, including both native timer architectures. No default is fabricated.
Use the application artifact-preparation receipt as evidence of actual OCI bytes,
then preserve or remeasure digests when importing into an explicitly authorized
owned registry. Offline artifacts/Helm rendering do not prove live lifecycle.

Central render check, after supplying real fixture values and artifact pins:

```sh
helm template acceptance charts/attune --values /owned/acceptance-values.yaml
helm template acceptance charts/attune --values /owned/acceptance-values.yaml --is-upgrade
```

Cluster provisioning, namespace/PVC ownership and the live both-storage-mode
fresh/failed-upgrade/rollback matrix remain explicit central responsibilities.
These offline checks start no cluster workloads and do not prove live admission.

The chart defaults to platform `0.9.0`, independently from core `1.0.4`.
Older `0.8.0` platform images cannot satisfy this bootstrap contract.
The API must advertise `pack_publication` on `/health/ready` with integer
protocol/client versions `1`, revision `authenticated-pack-publication-1`,
authorization `registrar`, and exactly `immutable_release` plus
`atomic_deployment`. The bundled publisher must export matching constants and
the API-only `publish_core` helper. `BOOTSTRAP_ADMISSION_ENABLED=false` describes
a different managed-runtime gate and must not be flipped to satisfy this contract.

Retain source revisions, measured image manifests, the native-inclusive canonical
pack archive checksum, authenticated denial/success evidence, `/health/bootstrap`
release/version/digest/policy results and the independent `/health/content` result.
Missing artifacts need a central build and authorized registry import/publication.
Missing registrar authority needs an existing operator-provided deployment token.
Neither a successful render nor a source version proves either is available.

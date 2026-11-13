# Central acceptance image inputs

Each `images.<component>.digest` accepts an actual OCI manifest digest and takes
precedence over its tag. Keep it empty until the matching compatible image exists.
The existing registry/namespace/repository selection still applies. For example,
the central operator supplies `images.api.digest=sha256:<measured 64 hex>` and
the corresponding repository in an owned registry. Never substitute a source
archive checksum or pack archive digest.

`corePack.digest` remains a different value: the measured canonical core pack
archive, including musl-linked AMD64/ARM64 core action binaries. No default is fabricated.
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

The chart defaults to platform `0.10.4`, independently from core `1.0.7`.
This draft default combination is not deployable: stock `0.10.4` workers cannot
execute native directories, even though they advertise `native`. No compatible
immutable worker/agent image has been selected. Require an actual measured
`images.agent` override (the injected executable source in this chart), compatible
API/worker code, and fresh-install execution evidence before core activation.
Changing only a pool's runtime-container image does not replace its injected agent.
Prefer a coordinated platform release once actual versions/images exist. Keep
this PR draft until that concrete image selection is established.

For upgrades, first roll compatible worker/agent code with all OLD core version,
archive digest and init-packs tag/digest pins preserved in the existing config.
Wait for workers to roll, old workers to drain/terminate and dispatch eligibility
to be verified; test old-core execution on the new workers. Only then activate
core `1.0.7` with those compatible worker pins retained. Optional publication Jobs
can race worker rollout; required post-upgrade hooks gate the API, not worker
versions or drainage. See the [inspected hook ordering and staged rollout](../charts/attune/README.md#native-core-107-worker-compatibility).
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

Core `1.0.7` depends on [Attune PR 41](https://github.com/attune-system/attune/pull/41)
and measured compatible `init-packs:core-1.0.7` artifacts. The tag is a desired
input, not publication evidence. Retain a draft until that evidence exists.
Publication Python/PyYAML stays inside init-packs; native full worker pools need
no added Python or shell prerequisites for `core.echo`, `core.sleep`, `core.noop`.
Verify the image includes the matching binary-directory entrypoints and both
musl architectures, then execute all three actions on owned workers.

The chart calls the bundled `publish_core` helper without constructing the API
payload. Verify that helper explicitly sends scalar multipart `absent_metadata_policy=remove`.
The policy applies across the pack, with no component selector. Verify that
activation retires every other core action callable while leaving unrelated
metadata, runtimes, sensors, IAM sets and dashboards unchanged. Retained unrelated
component definitions remain byte-identical, including `core.key_creator`.
Scalar Remove retires eight omitted action refs plus `install_packs`'s own
`workflow_definition` child. This owning-workflow retirement is the explicit
non-action projection exception; broader unrelated removal is not intended.
Require regression evidence for retained unrelated projection IDs/lifecycle,
retired owning workflow child, pinned old-release preservation and denied new
lookup/execution of removed actions. This does not
make the scalar policy action-only.
Record request, resulting inventory, idempotent rerun and failed-upgrade
preservation evidence. Offline Helm/adapter tests prove pins and delegation;
they do not prove the bundled helper's API payload or action execution.

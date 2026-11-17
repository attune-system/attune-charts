# Published images and owned acceptance

Chart `0.11.1` selects published Attune `0.11.1` platform images, including the
injected agent and init-user helper, by immutable AMD64/ARM64 index digest.
[Platform provenance](published-images-0.11.1.json) records registry manifests,
configs and source revision `46a80c7edf458c2dfa15461826fa3df269ebc6b2`. Core `1.0.7`,
timer `0.7.5`, the init-packs image and canonical archive pins are unchanged.
Registry metadata verification and chart checks do not establish live `0.11.1`
execution or upgrade acceptance. The measured `0.11.0` results below remain
historical evidence for that release.

Chart `0.11.0` targets published Attune `0.11.0`, core `1.0.7` and timer `0.7.5`.
Defaults select immutable AMD64/ARM64 OCI indexes, including the injected
`images.agent` and `images.initUser`. [The provenance record](published-images-0.11.0.json)
contains public registry index, architecture-manifest and config digests, release
source revision, and publisher workflow. Both configs for each image identify
release commit `67b2f572a75f5057e1dd5978258fd7910d2564c9`. These are actual
published references, not desired local import names or pre-release receipts.

`images.<component>.digest` takes precedence over its tag. Changing only
`global.imageTag` cannot replace pinned binaries. Override the corresponding
digest explicitly, or clear it to use a tag. The release-update script clears
previous platform digests when advancing the application version, while retaining
independent core init-packs pins; measure new published pins before activation.
A runtime-container image override alone does not replace the agent executable
copied by `init-agent`. Stock `0.10.4` agents cannot execute native directories.

`corePack.digest` is separate: SHA256 of the canonical native-inclusive pack
archive from the selected image, not an OCI/source/upload-tarball digest. The
default pins the measured published archive recorded in the provenance file.
Historical b8/local mixed-source checksums are not release pins. Record actual API
`/health/bootstrap` release/version/digest/policy and
independent `/health/content` results. Source or image metadata is not execution.

## Fresh installations and staged forward upgrades

Use dedicated disposable namespaces, credentials, storage and explicit context,
with a campaign lease/resource budget and awaited cleanup. Fresh acceptance must
exercise the published service/agent/init-user/init-packs bytes and actual imageIDs,
normal init-user/login/password-change/**re-login**, then a legitimate
identities:manage-issued registrar token. Never replace this with SQL tokens,
extra grants, root publisher UID or admission bypass.

For a staged forward upgrade, recover a genuine OLD tuple from historical published artifacts;
do not seed the new release and call absent components retired:

1. Preserve OLD `corePack.version`, canonical `corePack.digest`, and init-packs
   tag/digest. Roll compatible `0.11.0` services and injected agent first. Verify
   rollout, old workers drained/terminated and dispatch eligibility, then old-core
   execution on the new workers, before core activation.
2. Keep those compatible worker pins and activate the selected core `1.0.7` image.
   Verify four native executions including HTTP, retirement/preservation inventories,
   old-release pins/history, failure preservation and rollback boundaries.

Optional upgrade publication is an ordinary Job and can race workers. Required
post-upgrade hooks gate the target API only; Helm `--wait`/`--wait-for-jobs` does
not prove worker drainage. See [inspected hook ordering](../charts/attune/README.md#native-core-107-worker-compatibility).
A missing historical publisher/API/schema compatibility prerequisite must be
reported concretely; do not reset data or weaken gates to manufacture an upgrade.

## Measured acceptance and rollback boundary

Chart `0.11.0` support validated here covers fresh installations and staged
**forward upgrades** from `0.10.4`/core `1.0.5` to `0.11.0`/core `1.0.7`.
Published-source `67b2f572a75f5057e1dd5978258fd7910d2564c9` passed that owned AMD64
scope in both storage modes:
normal credentials/re-login, actual imageIDs, worker rollout/drainage and old-core
execution before activation, native four-action/HTTP success, exact seven action
and owning-workflow retirement, unrelated IDs/history/old-archive retention,
failed-admission preservation and idempotency. The canonical core archive is
`82a032962e28cf288a77e23273202e021428550cd655ba2c7776f3a98281e638`.
These observations do not establish ARM execution, RWX, proxy/TLS or general
provider-failure coverage. The overnight object test included host suspend;
wall elapsed is not an execution/performance measurement.

**Original core `1.0.5` restoration is unsupported.** Released `0.11.0` exposes
no supported retained-release reactivation or rollback operation. Release history,
archive retention and historical execution pins do not reactivate an older
release. The rollback command described in the application's proposed pack-release
specification is not shipped in this release.

Re-upload through the original published `0.10.4` helper returned HTTP400 at
`permission_sets/admin.yaml` `/grants`: “System administration requires explicit
external authority.” Its unchanged legacy admin definition defaults to Pack
scope and is not an exact current-catalog definition. This structural rejection
is not remedied by stronger registrar privileges or external approvals.

The failed attempt preserved core `1.0.7`, its release/policy, retained projections
and `identities:manage` in both modes. New-core execution and forward recovery to
the pinned `1.0.7` Helm configuration passed in object mode. Rejection safety and
forward recovery are distinct from successful restoration; no restorative
rollback passed.

Keep compatible `0.11.0` services/agent and current core pins. Do not remove
archive pins, add grants/acknowledgements or loosen authority checks to bypass
this boundary. Helm rollback does not reverse admitted pack state. Full
backup-based disaster recovery requires separate coordination and was not
validated here; no application/database downgrade is established.

## Publisher and inventory contract

The chart delegates unchanged to the image's API-only `publish_core` helper.
The API must advertise `pack_publication` version/client1,
`authenticated-pack-publication-1`, registrar authorization and exactly
`immutable_release` plus `atomic_deployment`; matching helper exports are required.
`BOOTSTRAP_ADMISSION_ENABLED=false` describes a different managed-runtime gate,
and must not be flipped to satisfy publication.

The publisher sends scalar pack-wide multipart `absent_metadata_policy=remove`,
with no component selector. Four native actions remain: echo, sleep, noop and
http_request. Require eight executable static musl ELF payloads (AMD64/ARM64 for
each), correct machines and no `PT_INTERP`/`DT_NEEDED`; pre-upload validation has no
source fallback. Python/PyYAML belongs in the publication image, not native action
runtime prerequisites. Execute all four on the actual compatible worker binaries.

Seven omitted actions newly retire, plus install_packs's OWN workflow_definition
child. Preserve unrelated definitions, projection IDs/lifecycle and historical
release pins, including core.key_creator. Compare against the post-admin-policy
baseline; for older releases allow only the explicit identities:manage addition
to core.admin/platformadmin (catalog4/epoch1), not arbitrary IAM changes. This
preservation does not make scalar Remove action-only. Fresh absence is not
retirement or ID/history preservation evidence.

Record source-specific receipts, actual imageIDs, authenticated success and 401/403
denials, inventories, canonical archive digest and cleanup. Published-source fresh
and staged-upgrade results are distinct from earlier local b8 acceptance. ARM
payload presence does not prove ARM worker execution; RWX, proxy/TLS and provider
failure remain outside the measured scope. Original legacy restoration is
unsupported as described above; this is not a blanket compatibility waiver.

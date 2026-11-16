# Published images and owned acceptance

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
archive from the selected image, not an OCI/source/upload-tarball digest. Leave it
empty until measured. Historical b8/local mixed-source checksums are not release
pins. Record actual API `/health/bootstrap` release/version/digest/policy and
independent `/health/content` results. Source or image metadata is not execution.

## Fresh and staged upgrades

Use dedicated disposable namespaces, credentials, storage and explicit context,
with a campaign lease/resource budget and awaited cleanup. Fresh acceptance must
exercise the published service/agent/init-user/init-packs bytes and actual imageIDs,
normal init-user/login/password-change/**re-login**, then a legitimate
identities:manage-issued registrar token. Never replace this with SQL tokens,
extra grants, root publisher UID or admission bypass.

For an upgrade, recover a genuine OLD tuple from historical published artifacts;
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
payload presence does not prove ARM worker execution; RWX, proxy/TLS, provider
failure and rollback need their own affected coverage. Keep readiness gaps explicit.

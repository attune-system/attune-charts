# Automated chart validation

Release refreshes open or update an `automation/attune-release` pull request.
After creation, the update workflow calls the same verification workflow used by
ordinary PRs, checking out the action's exact PR-head SHA. Both Helm versions
must pass. A separate job records **Chart validation** on that tested commit;
failure, cancellation, and skipped verification all record failure.

This path does not depend on a GITHUB_TOKEN branch push or an approved PR event
starting CI. Validation has read-only access. Only the reporting job receives
Checks write permission, and it executes no checkout code. No automatic merge
or new branch rule is enabled. Unchanged refreshes create no PR and skip this
validation/reporting path.

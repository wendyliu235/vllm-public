# Fork-only XPU kernel nightly synchronization

The `Update XPU kernel nightly test branch` workflow lives on this fork's
default branch (`main`). It runs daily at 14:00 UTC (22:00 Asia/Shanghai)
and supports manual runs from the Actions page. GitHub may delay scheduled runs.
Enable GitHub Actions and this scheduled workflow in the fork if disabled.

The workflow uses a GitHub-hosted Ubuntu runner and the repository's
`GITHUB_TOKEN` with `contents: write`. Repository rules must permit it to
update `intel-kernel-nightly-test`, including force pushes. No personal token
or XPU runner is required for synchronization. Configure the repository secret
`BUILDKITE_TOKEN` with permission to create builds (`write_builds`) in
`vllm/intel-ci`.

Each run fetches `vllm-project/vllm:main`, applies
[`integration.patch`](integration.patch), checks shell syntax, and pushes the
result to `intel-kernel-nightly-test` using an explicit `--force-with-lease`.
The test branch consists of upstream plus one integration commit; old test
history is not merged or rebased back in. Unchanged source and patches produce
no push. A patch conflict or failed check stops the run before pushing.
After successful synchronization, each scheduled or manual run creates one
full Intel CI build via the Buildkite API, even when no push was needed:
a new kernel nightly wheel may exist without an upstream source change.
Failed synchronization prevents the trigger. The POST is not automatically
retried, to avoid duplicate builds after an ambiguous response.

The test branch contains the Intel CI script and XPU Dockerfile changes in the patch.
It builds vLLM from upstream source, not a published vLLM wheel. The kernel
nightly wheel is selected at Intel CI build time, not during branch sync.
The existing vLLM nightly wheel sync workflow is independent and unchanged.

## Running Intel CI

The API request uses the exact synchronized commit, fork branch
`wendyliu235:intel-kernel-nightly-test`, and PR #66995 metadata, following
the existing vLLM nightly wheel workflow. It sets:

```yaml
env:
  VLLM_XPU_KERNEL_NIGHTLY: "1"
  RUN_ALL: "1"
  NIGHTLY: "1"
```

The created Buildkite URL and commit are recorded in the Actions job summary.
No tests execute on the GitHub-hosted runner.
This workflow does not disable PR-driven Intel CI triggers; those must be
disabled separately to avoid a second build after branch updates. Closing
PR #66995 may suppress PR-driven builds, but compatibility with the pipeline's
PR checks must be verified before relying on closed-PR API builds.

By default the image build selects the latest compatible development wheel
from the public kernel nightly index. To reproduce a specific version, also set
`VLLM_XPU_KERNEL_VERSION`, for example `0.1.18.dev20261109`.
The image build records the exact wheel URL, version, SHA256, and image tag in
`build/xpu-kernel-wheel/kernel-wheel-info.txt` and Buildkite annotations.
The kernel pin is supplied through a temporary BuildKit context, leaving the
tracked requirements file unchanged. This avoids introducing a dirty SCM
version that differs from the Rust frontend version. The selected image must
pass the kernel version and extension import checks before publication.

## Maintaining the overlay

Do not manually develop on or pull/merge into `intel-kernel-nightly-test`:
the next sync replaces it. Keep custom changes in `integration.patch` on
the fork's default branch. The previous `intel-kernel-nightly` branch is
not modified by this workflow.

To refresh the patch from a reviewed integration branch:

```bash
git diff --full-index upstream/main...reviewed-kernel-branch -- \
  .buildkite/image_build/image_build_xpu.sh \
  .buildkite/scripts/hardware_ci/run-intel-test.sh \
  docker/Dockerfile.xpu \
  > .github/kernel-nightly/integration.patch
```

Commit the updated patch to the fork's default branch, then manually run
the workflow. If upstream changes these scripts incompatibly, resolve the
integration against current upstream before regenerating the patch.

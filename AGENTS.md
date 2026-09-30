# forge-perf

forge-perf measures the sustained ingest rate of the Forge storage stack on a dedicated EC2 box and publishes one record per run to a public page. [docs/DESIGN.md](docs/DESIGN.md) is the design; read it before changing anything here.

## Layout

| Path | Holds |
|---|---|
| `docs/` | the design and the reference documents for each area |
| `terraform/` | OpenTofu roots under `envs/` and modules under `modules/` |
| `host/`, `systemd/` | box provisioning, pinned tool versions and the unit files |
| `scripts/host/` | scripts that run on the box as root |
| `scripts/operator/` | scripts an operator runs from a laptop |
| `scripts/publish/` | the publish workflow's ingest and site build ([docs/publishing.md](docs/publishing.md)) |
| `cmd/` | Go programs run on the box, such as the S3 ceiling tool |
| `scripts/ci/` | `check-*.sh`, run by `make check`, and their tests under `tests/` |
| `config/` | run settings per instance type, pinned images, the harness pin |
| `schema/` | JSON schemas for the run record, gates and overrides |
| `site/`, `data/` | the static page, gates and overrides |
| `calibration/` | committed sets, measured ceilings and tier calibration results |

## Conventions

- Host scripts are bash with `set -euo pipefail` and pass shellcheck (`-x -P SCRIPTDIR`); CI pins shellcheck 0.11.0.
- Host scripts reach the host (packages, `systemctl`, `mkfs`, `mount`, `sysctl`, files under `/etc`, instance metadata) through `host_op`, `host_check`, `host_read`, `host_file` and `imds` in `scripts/host/lib.sh`, or behind a `host_ops_skipped` check as in `install-tools.sh`, so `FORGE_PERF_HOST_OPS=skip` turns them into logged no-ops for a local run (`docs/runner.md`).
- OpenTofu follows infra-nodes and infra-central: `versions.tofu`, a `versions.tf` that refuses Terraform, committed `terraform.tfvars`, shared values in `terraform/modules/shared/constants`.
- `make check` is the CI surface. It runs every `scripts/ci/check-*.sh` in name order and stops at the first failure. A new area adds its own `check-<area>.sh` instead of editing the Makefile or the workflow. Tests exercise behavior with fixtures and stubbed commands on `PATH`.
- Go: `go test ./...` and `go vet` pass; minio-go stays at the version piri pins.
- Python is standard library only; tests use `python3 -m unittest`.
- The page (`site/`) is plain ES modules with Plot and d3 vendored, no bundler. Its rules live in `site/model.js`, tested with `node --test`. `make site-preview` serves it against fixture scenarios on http://127.0.0.1:8000/; look at a change there in light and dark and at a phone width.
- Commits: imperative subject under 72 characters, a body saying what and why. main takes squash merges only.

## Public-repository rules

This repository, its commit history, its CI logs and the page are public.

- Describe the workload only as the drill's import profile, ~128 MiB objects. Never name where that workload comes from.
- Never commit anything from a run's `raw/` directory, and never commit secrets, keys or tokens. Credentials live in SSM Parameter Store and repository secrets.
- The run record is an allowlist. Its schema has no free-text field: every string is an enum, SHA, digest, timestamp, duration or patterned version. A new field is a schema change, never a copied string.
- The denylist pattern lives outside the repository (repository secret `PUBLIC_DENYLIST_REGEX`, read only by CI's `denylist` job; locally a file named by `DENYLIST_FILE`). Run `make check` with it before every push. A check reports a match by file and line or by commit, never by the matched text.

## Trust boundary

The box pulls and runs code it does not review. Merging to forge-perf, smelt or storage-qualification main, publishing a tracked `ghcr.io/fil-forge/<svc>:main` image, or a `/forge-perf` request's `pr-*` image built from a branch of a tracked service repository runs code on the box as root. From there the instance metadata service issues the instance role's credentials, which can read every `/forge-perf/*` parameter (piri's S3 key, the harness read credential, the denylist pattern), write the results bucket and empty the box's piri buckets. Treat a merge to any of those mains, the permission to publish those images, and write access to a tracked service repository as access to the box.

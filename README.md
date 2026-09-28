# forge-perf

forge-perf tracks the sustained ingest rate of the Forge storage stack. A dedicated EC2 box runs every Forge service from the images published on main, drives them with the storage-qualification drill's import profile (~128 MiB objects), and publishes one number per run: p5 of 30-second windows, the highest rate at least 95% of the windows held. The median sits beside it.

The results page will be served from GitHub Pages at https://fil-forge.github.io/forge-perf/ once the first run is published.

## How a run works

1. Every five minutes the box resolves a set: the smelt SHA, the harness SHA and the digest of every tracked Forge image. A new set starts a run; a nightly run starts at 03:00 UTC regardless.
2. The box boots the stack with smelt, every image pinned by digest, piri writing to S3, and 25 ms of round trip added between the node and the central services.
3. The drill ingests up to its cap and reports per-window rates.
4. The box builds an allowlisted record, uploads it and the raw data to a private bucket, and wipes every container, every volume and the box's piri buckets.
5. A scheduled Action checks the record, commits it to the `results` branch and redeploys the page.

## Tiers

| Tier | Instance | Role |
|---|---|---|
| 1 | m9gd.2xlarge | the persistent box today |
| 2 | m9gd.8xlarge | the persistent box once a valid run reaches tier 1's ceiling |
| 3 | m9gd.16xlarge | short-lived campaign boxes only |

Each tier's ceiling is the lower of its measured sustained S3 PUT and NVMe write throughput. The page draws the three ceilings as gates on a thermometer.

## Documents

- [docs/DESIGN.md](docs/DESIGN.md): what is measured, the modeled topology, the box, a run from trigger to result, latency, storage, the record and page, operations and open questions.
- [docs/operations.md](docs/operations.md): procedures run by hand: the bootstrap apply, piri's key, the harness credential, the denylist parameter and the cost allocation tag.
- [docs/runner.md](docs/runner.md): the host scripts on the box, and running them on a laptop in skip mode.
- [AGENTS.md](AGENTS.md): layout, conventions and the rules for this public repository.

## Checks

`make check` runs every `scripts/ci/check-*.sh`, the same command CI runs. The denylist check needs a pattern from `PUBLIC_DENYLIST_REGEX` or a file named by `DENYLIST_FILE`, and skips with a notice without one. CI runs it in a job of its own, which fails when the pattern is missing, except on pull requests from forks.

## License

MIT; see [LICENSE](LICENSE).

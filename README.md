# forge-perf results

Run records published by the `publish` workflow on `main`. Each record under
`runs/<yyyy>/<mm>/<run_id>.json` is one run of the Forge storage stack on a
forge-perf box, checked against `schema/run-record.v1.json` before it is
committed; `status/` holds each box's alert state.

The workflow is the only writer. Nobody edits this branch by hand, and it is
never force-pushed or deleted. See `docs/publishing.md` on `main`.

# forge-perf

forge-perf measures how fast the Forge storage stack ingests and serves data under the drill's import profile, one run at a time on a dedicated box, and publishes the results.

## Language

### Streams

**Ingest**:
The drill's writes: one PUT per blob of about 128 MiB.
_Avoid_: upload, write throughput

**Read-back**:
The drill's verification read: one GET of a whole blob, 30 to 60 seconds after the blob was written.
_Avoid_: verification read, read throughput

**Restore**:
The drill's reads of older blobs in block-sized ranges, made by a fixed number of workers walking each account's blobs.
_Avoid_: range restore, ranged read, retrieval

**Ranged GET**:
A GET of one byte range of a blob, the request restore makes. It names a request, never the stream.

**Local disk**:
Ingot's copies of the blobs it has accepted, on the box's NVMe: its spool holds a blob until the provider holds it, and its cache after that. Both read streams read a blob there while ingot holds it, and from piri once ingot has evicted it under its local blob budget. Ingot's own name for these copies is its local blobs.
_Avoid_: page cache

### Measurement

**Window**:
One 30-second interval of a run, with the bytes and requests each stream completed in it.

**Steady window**:
A window that closed before ingest reached its cap. Every rate on the page is taken over the steady windows.
_Avoid_: sustained window

**p5**:
The highest rate that at least 95% of the steady windows held. The page labels it "held by 95% of windows".
_Avoid_: floor, minimum

**Noise band**:
The range an unchanged stack's results fall in from run to run, used to decide whether a difference is real.
_Avoid_: margin, tolerance

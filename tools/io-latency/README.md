# io-latency — how much a burst of writes stalls the desktop

CI jobs, builds and big copies write gigabytes while the desktop keeps
writing small files and calling `fsync`: a browser's databases, an editor's
saves, KWin's configuration. When those small writes queue behind the big
ones, windows grey out and the pointer stops. These scripts reproduce that
and measure it.

[run.sh](run.sh) starts job-like containers (three by default, from the CI
runner's job image) that write in parallel, and meanwhile measures, from
`app.slice` where the desktop's applications run:

- a 4 KiB write + `fsync` every 100 ms on the measured filesystem,
  [probe.py](probe.py), together with the I/O and CPU pressure (PSI) and the
  write latency, flush latency and write rate of the filesystem's device and
  of the physical disk under it;
- an `O_DIRECT` 4 KiB random read every 100 ms, [readlat.py](readlat.py).

Two loads: `dd` writes SCALE GiB of zeros per job (one big file; zeros
compress to nothing, so use `build` on a compressing filesystem), `build`
copies the image's `/usr` SCALE times per job (tens of thousands of small
files).

[series.sh](series.sh) runs a plan of measurements as root, each with its own
I/O scheduler and settings (`vm.*` sysctls, the io.cost controller, the jobs'
IOWeight, btrfs compression), restoring them after every run. It also runs
[dstate.py](dstate.py): every 100 ms it records which threads of the desktop's
processes are blocked in D state, with their kernel stacks and, inside
`fsync`, the file being synced. [analyze.py](analyze.py) sums each run up.

The block devices come from the filesystem that holds the results directory,
through every device-mapper layer down to the disk, so the results directory
has to be on the filesystem to measure — normally the one holding `$HOME`.

## Use

```
tools/io-latency/run.sh work/io-latency/try dd 6 --memory=2g --cpus=3
sudo tools/io-latency/series.sh "$USER" tools/io-latency/plans/example.txt work/io-latency/base
tools/io-latency/analyze.py work/io-latency/base
```

On Bazzite use `pkexec` with the script's full path in place of `sudo`.

- Options after the scale go to `podman run`; give the CI jobs' limits.
- `IOTEST_JOBS` sets the number of containers, `IOTEST_IMAGE` the image
  (`ghcr.io/catthehacker/ubuntu:act-latest`, which has to be pulled already).
- The results directory's parent gets `readtarget.dat`, 1 GiB of random data
  for the read probe.
- A run refuses to start while a CI job's container or volumes exist; a
  series stops `gitea-runner.service` for its duration and starts it again.
- A run takes two to five minutes, plus 30 s between runs. Expect the desktop
  to stall during it on a machine with the problem.

## Reading the results

- `stall_s`: seconds spent in fsyncs over 1 s. `fsync_max` is the longest
  single one; anything over a few hundred milliseconds is a visible hitch.
- `kwin_main_s`: time KWin's main thread was blocked; that is when the
  pointer stops. `kwin` counts KWin's "main thread was hanging" messages.
- `disk_mbps`, `flush_ms_max`: the disk's side. An SSD that drains the jobs'
  writes slowly, with long flushes, while its filesystem is mostly empty,
  probably does not know which blocks are free: check
  `/sys/block/<dm device>/queue/discard_max_bytes`; 0 means TRIM does not pass
  through dm-crypt (the `system-disk` role passes it).
- The blocked stacks say where the desktop waits. Many threads in
  `rq_qos_wait < wbt_wait` behind dm-crypt's one writer thread point at its
  workqueues (also `system-disk`); `folio_wait_writeback` from a page fault is
  a write to a memory-mapped page that is being written out; `btrfs_sync_file`
  under `fdatasync` is a synchronous save, and the synced file names it.

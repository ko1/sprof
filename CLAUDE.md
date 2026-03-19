# sprof - Development Guide

## Project Overview

sprof is a safepoint-based sampling profiler for Ruby. It uses actual time deltas (not uniform sample counts) as weights to correct safepoint bias. Output is pprof protobuf format.

- Linux only (uses Linux kernel ABI for per-thread CPU clocks)
- Requires Ruby >= 4.0.0

## Architecture

```
ext/sprof/sprof.c    -- C extension: timer thread, sampling, time measurement
lib/sprof.rb         -- Ruby API: profile/save/ENV auto-start, pprof protobuf encoder
exe/sprof            -- CLI wrapper (sets ENV, exec's the target command)
test/test_sprof.rb   -- Unit tests
benchmark/           -- Accuracy benchmark suite (see benchmark/README.md)
```

## Build & Test

```bash
rake compile          # Build C extension (use CCACHE_DISABLE=1 if ccache fails)
rake test             # Run unit tests
```

## Benchmark

```bash
cd benchmark
rake compile          # Build benchmark workload C extension
ruby check_accuracy.rb                        # Default: sprof, mixed scenarios, cpu mode
ruby check_accuracy.rb -m wall                # Wall mode
ruby check_accuracy.rb -P stackprof -m cpu    # Compare with other profilers
ruby check_accuracy.rb -l -m wall             # Run under CPU load
```

See `benchmark/README.md` for full documentation.

## Key Design Decisions

- **Weight = time delta, not sample count**: Each sample's weight is `clock_now - clock_prev` in nanoseconds. This corrects for safepoint delays.
- **Postponed jobs for sampling**: Timer thread calls `rb_postponed_job_trigger()`. Actual sampling happens at the next VM safepoint via `sprof_sample_job()`.
- **Per-thread state via `rb_internal_thread_specific_key`**: Stores `prev_cpu_ns` per thread. First sample for each thread is skipped (no delta yet).
- **Deferred string resolution**: Sampling stores raw frame VALUEs in a pool. String resolution (`rb_profile_frame_full_label`, `rb_profile_frame_path`) happens at stop time, not during sampling. This keeps the hot path allocation-free.
- **No protobuf dependency**: pprof format is encoded with a hand-written encoder in `lib/sprof.rb` (`Sprof::PProf.encode`). String table is built in Ruby at encode time.
- **Two clock modes**: cpu (per-thread `clock_gettime` via Linux TID-based clockid) and wall (`CLOCK_MONOTONIC`).
- **Method-level profiling**: No line numbers. Frame labels use `rb_profile_frame_full_label` for qualified names (e.g., `Integer#times`).

## Coding Notes

- The C extension uses a single global `sprof_profiler_t`. Only one profiling session at a time.
- Frame pool (`VALUE *frame_pool`, initial ~1MB) stores raw frame VALUEs from `rb_profile_thread_frames`. A TypedData wrapper with `dmark` using `rb_gc_mark_locations` keeps them alive across GC.
- `rb_profile_thread_frames` writes directly into the frame pool (no intermediate buffer).
- Sample buffer and frame pool both grow by 2x on demand via `realloc`.
- Thread exit cleanup is handled by `RUBY_INTERNAL_THREAD_EVENT_EXITED` hook. Stop cleans up all live threads' thread-specific data.
- Benchmark workload methods (rw/cw/csleep/cwait) are numbered 1-1000 to appear as distinct functions in profiler output.

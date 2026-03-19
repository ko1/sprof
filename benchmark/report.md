# Profiler Accuracy Report

Benchmark date: 2026-03-20
Ruby: 4.0.0, Linux 6.6.87 (WSL2, 20 cores)

## Methodology

Each profiler was tested against a mixed-workload scenario containing four types of methods:

- **rw** (Ruby busy-wait): spins in a Ruby loop reading `CLOCK_THREAD_CPUTIME_ID`
- **cw** (C busy-wait): spins in a C function reading `CLOCK_THREAD_CPUTIME_ID`
- **csleep** (C nanosleep, GVL held): calls `nanosleep()` without releasing the GVL
- **cwait** (C nanosleep, GVL released): calls `nanosleep()` via `rb_thread_call_without_gvl`

Each scenario has 50-150 base method calls with ~30% repeated 3-10 times, totaling 160-400 calls per scenario. Every method has a known execution time in microseconds. The expected CPU time and wall time for each method are precomputed and stored in the scenario JSON.

The runner (`check_accuracy.rb`) generates a profiler-specific script, executes it, parses the profiler output, and compares per-method actual time against expected time. The reported "error" is the average of `|actual - expected| / expected` across all methods.

Two frequencies (100Hz and 1000Hz), two modes (cpu and wall), and two load conditions (idle and full CPU saturation on all 20 cores) were tested.

## Results: Mixed Workload (No Load)

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **1.9%** | **5.4%** | **0.2%** | **0.8%** |
| stackprof | 21.4% | 83.7% | 38.1% | 83.5% |
| vernier | 63.5% | 93.2% | 63.5% | 35.9% |
| pf2 | 58.7% | 46.4% | 61.4% | 55.8% |

### Key observations

**sprof** is the only profiler that passes (<20% error) in all combinations. At 1000Hz the error drops below 1% in both modes. Even at 100Hz, cpu mode stays under 2% because the time-delta weighting compensates for the lower sampling rate.

**stackprof** shows high error for several reasons:
- In cpu mode, it counts samples uniformly (1 sample = 1 interval) without time-delta correction. At 1000Hz the interval is 1ms, but C busy-wait methods (`cw`) execute long stretches without safepoints, so their TOTAL counts are inflated by `clock_gettime` being sampled as the leaf frame instead of the actual workload method. At 100Hz, each sample represents a larger interval but the same bias applies.
- In wall mode, stackprof at 1000Hz still shows ~84% error because `nanosleep`-based methods (csleep/cwait) are invisible: the thread is sleeping inside a C call with no safepoint, so no samples are collected during that time, yet the wall clock advances.

**vernier** has a unique profile:
- cpu mode always shows 63.5% error because vernier does not support CPU-time sampling. The `:retained` mode is used as a fallback, which measures something entirely different (object retention).
- wall mode at 1000Hz (35.9%) is moderately accurate for rw/cw/cwait methods but completely misses csleep (GVL-held sleep). At 100Hz, wall error jumps to 93.2% due to fewer samples and coarser resolution.

**pf2** outputs pprof format but with flat=0 for all Ruby/C frames. Only cumulative values are available, and they include native stack frames (libc, VM internals), making per-method attribution unreliable. The 46-62% errors are consistent across frequencies, suggesting a structural issue rather than a sampling rate problem.

## Results: Mixed Workload (Under Full CPU Load)

All 20 cores were saturated with busy-loop processes during profiling.

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **1.7%** | 35.1% | **0.2%** | 36.2% |
| stackprof | 24.8% | 85.9% | 39.6% | 82.8% |
| vernier | 63.5% | 90.5% | 63.5% | 37.7% |
| pf2 | 95.2% | 68.8% | 87.0% | 81.4% |

### Key observations

**sprof cpu mode is unaffected by load**: 0.2% at 1000Hz, 1.7% at 100Hz -- essentially identical to no-load results. This is because sprof reads per-thread CPU clocks (`clock_gettime` with thread-specific clockid), which only count time the thread actually ran on a CPU, excluding time spent in the OS scheduler's run queue.

**sprof wall mode correctly degrades under load** (5% -> 35%): busy-wait methods (rw/cw) take longer in wall time because the OS scheduler preempts them to run the load processes. This is not a bug -- wall time is supposed to reflect real elapsed time including scheduling delays.

**stackprof cpu barely changes under load** (21% -> 25% at 100Hz, 38% -> 40% at 1000Hz): the error was already high without load due to safepoint bias and uniform sample weighting, so the additional scheduling noise is within the existing error margin.

**pf2 cpu degrades significantly under load** (59% -> 95% at 100Hz): pf2's cumulative values become even more inflated when wall time expands due to CPU contention, suggesting its "cpu" mode may actually be measuring wall time internally.

## Results: Ruby-Only Workload (rw methods, No Load)

To isolate the effect of workload type, the same benchmark was run with rw-only scenarios (pure Ruby busy-wait, no C methods or sleep).

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **7.9%** | **7.3%** | **1.2%** | **0.9%** |
| stackprof | 8.3% | 7.4% | 75.0% | 0.7% |
| vernier | 219.5% | 89.8% | 219.5% | 1.4% |

### Key observations

**stackprof wall at 1000Hz achieves 0.7% error** on rw-only workloads. This is because pure Ruby busy-wait hits safepoints frequently (every `clock_gettime` call), so uniform sample counting works well when there are no C-level blind spots. However, stackprof cpu at 1000Hz shows 75.0% error -- the high frequency causes the `clock_gettime` leaf frame to dominate TOTAL counts, inflating error.

**stackprof at 100Hz** (8.3% cpu, 7.4% wall) is usable for rw-only workloads. The lower frequency means each sample carries more weight, which averages out the safepoint bias for methods that frequently reach safepoints.

**vernier wall at 1000Hz achieves 1.4% error** on rw-only workloads, comparable to sprof. Vernier's sampling is accurate when the workload consists entirely of Ruby code with frequent safepoints and no sleep/blocking calls. Its wall mode at 100Hz (89.8%) suffers because fewer samples mean coarser attribution.

**sprof at 100Hz** (7.9% cpu, 7.3% wall) is less accurate than at 1000Hz but still well within usable range. The time-delta weighting ensures that even with 10x fewer samples, each sample carries the correct weight proportional to elapsed time.

## Summary

### What makes sprof different

sprof's core advantage is **time-delta weighting**: each sample's weight equals the actual nanoseconds elapsed since the previous sample, not a fixed interval. This has three consequences:

1. **Safepoint delay is corrected**: if a safepoint is delayed by 5ms, the sample carries 5ms of weight instead of 1ms. Other profilers lose this information.
2. **Per-thread CPU clocks**: in cpu mode, sprof reads each thread's actual CPU consumption via Linux's thread-specific clockid. Sleep, I/O, and scheduling delays are excluded. Other profilers either use wall time or rely on signal-based sampling that doesn't distinguish CPU from wall time.
3. **Works across workload types**: C busy-wait, Ruby busy-wait, GVL-held sleep, and GVL-released sleep are all accurately attributed in the appropriate mode. Other profilers have blind spots for one or more of these categories.

### Profiler suitability by scenario

| Scenario | sprof | stackprof | vernier | pf2 |
|----------|-------|-----------|---------|-----|
| Mixed workload, cpu time | Accurate | Poor (safepoint bias) | Not supported | Poor (inflated cum) |
| Mixed workload, wall time | Accurate | Poor (misses sleep) | Moderate (misses csleep) | Poor (inflated cum) |
| Ruby-only, wall, 1000Hz | Accurate | Accurate | Accurate | Not tested |
| Under CPU load, cpu time | Stable | Unchanged (already poor) | Not supported | Degrades heavily |
| Under CPU load, wall time | Degrades (correct) | Unchanged (already poor) | Moderate | Degrades |

### Frequency guidance

- **1000Hz**: best accuracy for all profilers, but higher overhead. Recommended for short-running benchmarks.
- **100Hz**: sprof stays accurate (1-8% depending on mode and workload). stackprof and vernier degrade but remain usable for rw-only wall mode. Recommended as the default for production profiling.

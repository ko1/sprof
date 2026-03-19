# Sprof Accuracy Benchmark

A benchmark suite for quantitatively verifying sprof's profiling accuracy.
It profiles workloads with known execution times and compares the output against expected values.
Accuracy comparisons with other profilers (stackprof, vernier, pf2) are also supported.

## Purpose

- Verify that CPU time / wall time reported by sprof matches actual time consumed
- Check accuracy across workload types: Ruby busy-wait, C busy-wait, sleep, GVL-released sleep
- Confirm that wall mode is affected by CPU contention while cpu mode is not
- Compare accuracy against other profilers under identical conditions

## Workload Methods

Each method type is defined with numbers 1 through 1000 (1000 methods each).
Different numbers appear as distinct functions in profiler output, allowing per-function accuracy verification.

| Prefix | Defined in | Behavior | GVL | CPU time | Wall time |
|--------|-----------|----------|-----|----------|-----------|
| `rw`   | `lib/sprof_workload_methods.rb` | Ruby busy-wait (`CLOCK_THREAD_CPUTIME_ID`) | Held | usec consumed | usec consumed |
| `cw`   | `ext/sprof_workload/sprof_workload.c` | C busy-wait (`CLOCK_THREAD_CPUTIME_ID`) | Held | usec consumed | usec consumed |
| `csleep` | same | `nanosleep` (GVL held) | Held | 0 | usec consumed |
| `cwait` | same | `nanosleep` (`rb_thread_call_without_gvl`) | Released | 0 | usec consumed |

## Tools

### generate_scenarios.rb -- Scenario Generator

Generates random workload call sequences and their expected values as JSON.

```bash
ruby generate_scenarios.rb                        # mixed (rw/cw/csleep/cwait), 10 scenarios
ruby generate_scenarios.rb -p rw -n 10            # rw only
ruby generate_scenarios.rb -p cw -n 3             # cw only
ruby generate_scenarios.rb -p csleep -n 3         # csleep only
ruby generate_scenarios.rb -p cwait -n 3          # cwait only
ruby generate_scenarios.rb -p mixed -n 10         # all types mixed
ruby generate_scenarios.rb -s 12345               # custom seed
ruby generate_scenarios.rb -o my_scenarios.json   # custom output filename
```

Generated JSON structure:

```json
{
  "id": 0,
  "calls": [["rw815", 72240], ["csleep42", 50000], ...],
  "expected_cpu_ms":  { "rw815": 72.24, "csleep42": 0.0, ... },
  "expected_wall_ms": { "rw815": 72.24, "csleep42": 50.0, ... }
}
```

- Some calls are repeated (approximately 30% of methods are called 3-10 times each) to test accumulation
- `expected_*_ms` values are summed across duplicate calls to the same method
- Fixed seed ensures reproducibility

### check_accuracy.rb -- Accuracy Runner

Runs scenarios and compares profiler output against expected values, reporting PASS/FAIL.

```bash
ruby check_accuracy.rb                                    # sprof, scenarios_mixed.json, cpu mode
ruby check_accuracy.rb -f scenarios_rw.json               # specify scenario file
ruby check_accuracy.rb -m wall                            # wall mode
ruby check_accuracy.rb -m cpu -t 5                        # set tolerance to 5%
ruby check_accuracy.rb -l                                 # run under CPU load
ruby check_accuracy.rb -P stackprof -m cpu                # use stackprof
ruby check_accuracy.rb -P vernier -m wall                 # use vernier
ruby check_accuracy.rb -P pf2 -m wall                    # use pf2
ruby check_accuracy.rb -f scenarios_rw.json -m wall -l    # combined options
ruby check_accuracy.rb 0                                  # scenario #0 only
ruby check_accuracy.rb 0-4                                # scenarios #0 through #4
```

| Option | Default | Description |
|--------|---------|-------------|
| `-f FILE` | `scenarios_mixed.json` | Scenario file |
| `-m MODE` | `cpu` | Profiling mode (`cpu` / `wall`) |
| `-t PCT`  | `20` | Pass tolerance (%) |
| `-l`      | off | Spawn CPU-hogging processes on all cores |
| `-P PROF` | `sprof` | Profiler (`sprof` / `stackprof` / `vernier` / `pf2`) |

How it works:
1. Generates a profiler-specific temporary script for each scenario and executes it with `ruby`
2. Parses the output using the appropriate method (sprof/pf2: `go tool pprof`, stackprof: `stackprof --text`, vernier: Firefox Profiler JSON)
3. Compares actual vs expected per method; PASS if average error is within tolerance

## Included Scenario Files

| File | Contents | Count |
|------|----------|-------|
| `scenarios_rw.json` | Ruby busy-wait only | 10 |
| `scenarios_cw.json` | C busy-wait only | 3 |
| `scenarios_csleep.json` | nanosleep (GVL held) only | 3 |
| `scenarios_cwait.json` | nanosleep (GVL released) only | 3 |
| `scenarios_mixed.json` | All types mixed | 10 |

## Expected Results

### sprof (normal, no load)

All scenarios pass in both modes. Typical error is 1-2%.

```
$ ruby check_accuracy.rb -m cpu
Scenario #0     PASS (0.3%)
...
Overall average error: 0.4%
PASS (< 20%)

$ ruby check_accuracy.rb -m wall
Scenario #0     PASS (0.8%)
...
Overall average error: 1.0%
PASS (< 20%)
```

### sprof (under CPU load)

With `-l`, all cores are saturated with busy processes. Results differ by mode:

- **cpu mode -> PASS**: CPU time is per-thread, unaffected by other processes
- **wall mode -> FAIL**: Wall time for busy-wait methods (rw/cw) inflates due to CPU contention

```
$ ruby check_accuracy.rb -f scenarios_rw.json -m cpu -t 5 -l 0
Scenario #0     PASS (1.9%)
PASS (< 5%)

$ ruby check_accuracy.rb -f scenarios_rw.json -m wall -t 5 -l 0
--- Scenario #0     FAIL (avg error: 22.9%) ---
  rw975       expected=  865.8ms  actual= 1154.6ms  error= 33.4%
  ...
FAIL (> 5%)
```

This is correct behavior for wall mode. Wall time measures real elapsed time including OS scheduler effects, so CPU contention causes busy-wait methods to take longer.

### Comparison with Other Profilers

Accuracy on mixed scenario #0 (tolerance 20%):

| Profiler | cpu mode | wall mode |
|----------|----------|-----------|
| **sprof** | PASS (0.2%) | PASS (0.8%) |
| stackprof | FAIL (38%) | FAIL (82%) |
| vernier | FAIL (64%) | FAIL (35%) |
| pf2 | FAIL (64%) | FAIL (48%) |

Profiler characteristics:

- **stackprof**: Sampling occurs at the Ruby frame level, so it largely misses loops inside C functions (`cw`). High miss rate (~60%).
- **vernier**: Accurate for rw/cw/cwait in wall mode (1-3% error), but cannot measure GVL-held sleep (`csleep`). No cpu-time mode (`:retained` is used as a substitute but serves a different purpose).
- **pf2**: pprof output shows flat=0 for all frames, reporting only cumulative values that include the native stack. Values tend to be inflated.

With rw-only scenarios, vernier wall mode achieves good accuracy:

```
$ ruby check_accuracy.rb -P vernier -m wall -f scenarios_rw.json 0
Scenario #0     PASS (1.5%)
```

## Prerequisites

- `go tool pprof` in PATH (required for parsing sprof and pf2 results)
- Benchmark C extension built via `rake compile`
- For other profilers: `gem install stackprof vernier pf2`

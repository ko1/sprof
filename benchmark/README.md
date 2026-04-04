# Rperf Benchmarks

## Directory Structure

```
benchmark/
  accuracy/    -- Profiling accuracy verification
  overhead/    -- Sampling cost measurement
  ext/         -- C extension workload (shared)
  lib/         -- Ruby workload methods (shared)
  data/        -- Output data files
  Rakefile     -- Build workload C extension
```

## Build

```bash
cd benchmark
rake compile    # Build workload C extension
```

## Accuracy (`accuracy/`)

Profiles workloads with known execution times and compares against expected values.

```bash
cd accuracy

# Basic accuracy check (mixed workloads, cpu mode)
ruby check_accuracy.rb -m cpu

# Wall mode
ruby check_accuracy.rb -m wall

# Specific scenario
ruby check_accuracy.rb -m cpu 0

# Specific workload type
ruby check_accuracy.rb -f scenarios_rw.json -m cpu

# Compare with other profilers
ruby check_accuracy.rb -P stackprof -m cpu
```

See `accuracy/README.md` for full documentation.

## Overhead (`overhead/`)

Measures rperf's per-sample cost and total overhead.

### Per-sample cost

```bash
cd overhead

# Basic measurement (both modes, depth=1)
ruby measure_sampling_cost.rb

# Deep stack
ruby measure_sampling_cost.rb --depth 100

# Single mode
ruby measure_sampling_cost.rb --mode wall
```

### Cost vs stack depth

```bash
ruby compare_depth.rb              # default: 1, 10, 50, 100, 200
ruby compare_depth.rb 1 50 200     # custom depths
```

### Overhead vs frequency

```bash
ruby compare_frequency.rb                  # default: 100-10000 Hz
ruby compare_frequency.rb 100 1000 10000   # custom frequencies
```

### Profiler comparison (elapsed time overhead)

```bash
ruby run_overhead.rb    # compare rperf/stackprof/vernier/pf2
```

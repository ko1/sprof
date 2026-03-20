# Library API Usage

## Overview

The Ruby API provides programmatic control over profiling sessions. Use it when you want to profile specific sections of code, integrate profiling into test suites, or build custom profiling workflows.

## Quick Start

```ruby
require "sprof"

# Profile a block and save to file
Sprof.start(output: "profile.pb.gz") do
  # code to profile
end
```

## Starting and Stopping

### Block Form

The simplest way to use sprof is with a block:

```ruby
# With automatic file output
Sprof.start(output: "profile.pb.gz", frequency: 100, mode: :cpu) do
  run_workload
end

# Without file output -- returns raw data
data = Sprof.start(frequency: 1000, mode: :wall) do
  run_workload
end
```

The block form automatically stops profiling when the block exits (even on exception) and saves to the output file if specified.

### Manual Start/Stop

For cases where block form is inconvenient:

```ruby
Sprof.start(frequency: 100, mode: :cpu, output: "profile.pb.gz")

# ... application code ...

data = Sprof.stop  # saves to output path and returns data hash
```

> [!WARNING]
> Only one profiling session can be active at a time. Calling `Sprof.start` while profiling is already active raises `RuntimeError`.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `frequency:` | Integer | `100` | Sampling frequency in Hz (1-1,000,000) |
| `mode:` | Symbol | `:cpu` | `:cpu` for CPU time, `:wall` for wall time |
| `output:` | String | `nil` | Output file path (saves gzipped pprof on stop) |
| `verbose:` | Boolean | `false` | Print statistics to stderr on stop |

## Return Values

`Sprof.start` with a block returns the data hash from `Sprof.stop`.

`Sprof.stop` returns a hash with the following keys:

```ruby
{
  mode: :cpu,                    # profiling mode
  frequency: 100,                # configured frequency
  sampling_count: 523,           # number of sampling callbacks executed
  sampling_time_ns: 4210000,     # total time spent in sampling callbacks
  samples: [                     # array of [frames, weight] pairs
    [
      [["app.rb", "Array#each"], ["app.rb", "Object#main"]],  # frames (leaf first)
      15000000                                                  # weight in nanoseconds
    ],
    # ...
  ]
}
```

Each sample is a pair of `[frames, weight]`:
- **frames**: Array of `[path, label]` pairs, ordered leaf-first (deepest frame at index 0)
- **weight**: Nanoseconds of time attributed to this stack

## Saving Results

Results are automatically saved when `output:` is specified. You can also save manually:

```ruby
# Collect data without auto-save
data = Sprof.start(frequency: 1000) do
  run_workload
end

# Save later
Sprof.save("profile.pb.gz", data)
```

## Environment Variable Control

sprof can be activated via environment variables, useful for profiling without code changes:

```bash
SPROF_ENABLED=1 SPROF_MODE=wall SPROF_FREQUENCY=100 \
  SPROF_OUTPUT=profile.pb.gz SPROF_VERBOSE=1 \
  ruby app.rb
```

| Variable | Default | Description |
|----------|---------|-------------|
| `SPROF_ENABLED` | -- | Set to `"1"` to enable auto-start |
| `SPROF_MODE` | `"cpu"` | `"cpu"` or `"wall"` |
| `SPROF_FREQUENCY` | `100` | Sampling frequency in Hz |
| `SPROF_OUTPUT` | `"sprof.data"` | Output file path |
| `SPROF_VERBOSE` | -- | Set to `"1"` to print stats |

When `SPROF_ENABLED=1`, sprof starts profiling on `require "sprof"` and registers an `at_exit` hook to stop and save.

## Working with the Data Hash

The data hash returned by `Sprof.stop` can be used for custom analysis:

```ruby
data = Sprof.start(frequency: 1000, mode: :cpu) do
  run_workload
end

# Total profiled time
total_ns = data[:samples].sum { |_, weight| weight }
puts "Total: #{total_ns / 1_000_000.0}ms"

# Flat profile (self time per method)
flat = Hash.new(0)
data[:samples].each do |frames, weight|
  label = frames.first&.last  # leaf frame label
  flat[label] += weight if label
end

flat.sort_by { |_, w| -w }.first(10).each do |label, weight|
  pct = weight * 100.0 / total_ns
  puts "  #{weight / 1_000_000.0}ms (#{pct.round(1)}%) #{label}"
end
```

## Profiling in Tests

sprof integrates easily with test frameworks:

```ruby
class MyTest < Minitest::Test
  def test_performance
    data = Sprof.start(frequency: 1000, mode: :cpu) do
      result = MyApp.process(large_input)
      assert_equal expected, result
    end

    # Assert no single method takes more than 50% of CPU time
    total = data[:samples].sum { |_, w| w }
    data[:samples].each do |frames, weight|
      label = frames.first&.last
      pct = weight * 100.0 / total
      assert pct < 50, "#{label} consumed #{pct.round(1)}% of CPU time"
    end
  end
end
```

## Choosing Frequency

The sampling frequency controls the trade-off between profiling detail and overhead:

| Frequency | Use Case | Overhead |
|-----------|----------|----------|
| 10-100 Hz | Production, long-running processes | Negligible |
| 100-1000 Hz | Development, benchmarks | Low |
| 1000-10000 Hz | Short-lived scripts, high detail | Moderate |

> [!TIP]
> For most use cases, the default of 100 Hz is sufficient. Higher frequencies provide more samples but don't change the accuracy of time attribution -- sprof's time-delta weighting makes each sample carry proportional weight regardless of frequency.

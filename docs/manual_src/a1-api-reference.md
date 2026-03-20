# API Reference

## Module: Sprof

### Sprof.start

Starts a profiling session.

```ruby
Sprof.start(frequency: 100, mode: :cpu, output: nil, verbose: false)
Sprof.start(frequency: 100, mode: :cpu, output: nil, verbose: false) { block }
```

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `frequency:` | Integer | `100` | Sampling frequency in Hz. Valid range: 1 to 1,000,000. |
| `mode:` | Symbol | `:cpu` | Clock mode. `:cpu` for per-thread CPU time, `:wall` for wall clock time. |
| `output:` | String or nil | `nil` | File path for gzipped pprof output. If nil, no file is written on stop. |
| `verbose:` | Boolean | `false` | When true, prints sampling statistics and top functions to stderr on stop. Also enabled by `ENV["SPROF_VERBOSE"] == "1"`. |

**Returns:**

- Without block: `true`
- With block: the return value of `Sprof.stop` (data hash or nil)

**Raises:**

- `RuntimeError` if a profiling session is already active
- `ArgumentError` if frequency is out of range or mode is invalid
- `NoMemError` if buffer allocation fails

### Sprof.stop

Stops the active profiling session and returns collected data.

```ruby
data = Sprof.stop
```

**Returns:**

- `Hash` with profiling data (see Data Hash Format below)
- `nil` if no session is active

**Side effects:**

- Joins the timer thread
- Removes GVL and GC event hooks
- Frees per-thread data for all threads
- Resolves frame VALUEs to strings
- If `output:` was set on start, writes gzipped pprof to that path
- If `verbose:` was set, prints statistics to stderr

### Sprof.save

Saves profiling data to a gzipped pprof file.

```ruby
Sprof.save(path, data)
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `path` | String | Output file path |
| `data` | Hash | Data hash returned by `Sprof.stop` |

### Sprof::VERSION

```ruby
Sprof::VERSION  # => "0.1.0"
```

## Data Hash Format

The hash returned by `Sprof.stop`:

```ruby
{
  mode: Symbol,              # :cpu or :wall
  frequency: Integer,        # configured sampling frequency
  sampling_count: Integer,   # number of timer-triggered sampling callbacks
  sampling_time_ns: Integer, # total nanoseconds spent in sampling callbacks
  samples: Array             # array of sample entries
}
```

### Sample Entry Format

Each element of `samples` is a two-element array:

```ruby
[frames, weight]
```

- **frames** (`Array<Array<String, String>>`): Stack frames ordered leaf-first. Each frame is `[path, label]` where:
  - `path`: Source file path (e.g., `"app.rb"`) or `"<C method>"` for C frames, `"<GVL>"` for GVL synthetic frames, `"<GC>"` for GC synthetic frames
  - `label`: Method name from `rb_profile_frame_full_label` (e.g., `"Array#each"`, `"MyClass#process"`) or synthetic label (`"[GVL blocked]"`, `"[GVL wait]"`, `"[GC marking]"`, `"[GC sweeping]"`)

- **weight** (`Integer`): Nanoseconds of time attributed to this sample

### Synthetic Frame Labels

| Label | Path | Description | Mode |
|-------|------|-------------|------|
| `[GVL blocked]` | `<GVL>` | Time off-GVL (SUSPENDED to READY) | Wall only |
| `[GVL wait]` | `<GVL>` | GVL contention time (READY to RESUMED) | Wall only |
| `[GC marking]` | `<GC>` | GC mark phase duration | Both |
| `[GC sweeping]` | `<GC>` | GC sweep phase duration | Both |

## Environment Variables

| Variable | Values | Description |
|----------|--------|-------------|
| `SPROF_ENABLED` | `"1"` | Enable auto-start on `require "sprof"` |
| `SPROF_MODE` | `"cpu"`, `"wall"` | Profiling mode (default: `"cpu"`) |
| `SPROF_FREQUENCY` | Integer string | Sampling frequency in Hz (default: `"100"`) |
| `SPROF_OUTPUT` | File path | Output file (default: `"sprof.data"`) |
| `SPROF_VERBOSE` | `"1"` | Print statistics to stderr |

## CLI

```
sprof [options] exec command [args...]
```

| Option | Description |
|--------|-------------|
| `-o, --output PATH` | Output file (default: `sprof.data`) |
| `-f, --frequency HZ` | Sampling frequency (default: `100`) |
| `-m, --mode MODE` | `cpu` or `wall` (default: `cpu`) |
| `-v, --verbose` | Print statistics to stderr |
| `-h, --help` | Show help |

## pprof Output Format

The output file is a gzip-compressed Protocol Buffer conforming to [profile.proto](https://github.com/google/pprof/blob/main/proto/profile.proto). Key fields:

| Field | Value |
|-------|-------|
| `sample_type` | `cpu/nanoseconds` or `wall/nanoseconds` |
| `period` | `1_000_000_000 / frequency` nanoseconds |
| `sample.value` | Weight in nanoseconds (time delta) |
| `sample.location_id` | Stack frames (leaf first) |

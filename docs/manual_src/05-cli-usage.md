# CLI Usage

## Overview

The `sprof` CLI lets you profile any Ruby program without modifying its source code. It works by setting environment variables and exec'ing the target command with sprof auto-loaded.

## Basic Usage

```bash
sprof exec ruby my_app.rb
```

This profiles `my_app.rb` with default settings (100 Hz, CPU mode) and writes the output to `sprof.data`.

## Command Syntax

```
sprof [options] exec command [args...]
```

The `exec` keyword separates sprof options from the target command. Everything after `exec` is passed to the target process.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-o, --output PATH` | `sprof.data` | Output file path |
| `-f, --frequency HZ` | `100` | Sampling frequency in Hz |
| `-m, --mode MODE` | `cpu` | Profiling mode: `cpu` or `wall` |
| `-v, --verbose` | off | Print sampling statistics to stderr |
| `-h, --help` | | Show help |

## Examples

### Profile a Ruby Script

```bash
# Default settings: 100 Hz, CPU mode
sprof exec ruby my_script.rb

# Custom output path
sprof -o profile.pb.gz exec ruby my_script.rb

# Wall mode at 1000 Hz with verbose output
sprof -m wall -f 1000 -v exec ruby my_script.rb
```

### Profile a Rails Server

```bash
# Profile a Rails request handler
sprof -m wall -o rails_profile.pb.gz exec ruby -e "
  require './config/environment'
  # simulate request processing
"
```

### Profile a Rake Task

```bash
sprof -o rake_profile.pb.gz exec rake heavy_task
```

### Profile a Bundled Application

```bash
sprof exec bundle exec ruby my_app.rb
```

## Viewing Results

After profiling, use `go tool pprof` to analyze the output:

```bash
# Interactive web UI
go tool pprof -http=:8080 sprof.data

# Top functions by flat time
go tool pprof -top sprof.data

# Top functions by cumulative time
go tool pprof -cum -top sprof.data

# Text-based call graph
go tool pprof -text sprof.data

# Generate SVG flame graph
go tool pprof -svg sprof.data > profile.svg
```

> [!TIP]
> The web UI (`-http=:8080`) is the most powerful way to explore profiles. It provides interactive flame graphs, call graphs, source annotation, and filtering.

## How the CLI Works

The `sprof` CLI does not inject code into your application. Instead, it:

1. Sets `RUBYOPT=-rsprof` to auto-require the sprof library
2. Sets `SPROF_ENABLED=1` to trigger auto-start on load
3. Sets `SPROF_OUTPUT`, `SPROF_FREQUENCY`, `SPROF_MODE`, and `SPROF_VERBOSE` as configured
4. Calls `exec` to replace itself with the target command

The sprof library detects `SPROF_ENABLED=1` on load, starts profiling, and registers an `at_exit` hook to stop profiling and save results when the process exits.

## Verbose Output

When using `-v`, sprof prints sampling statistics to stderr:

```
[sprof] mode=cpu frequency=100Hz
[sprof] sampling: 523 calls, 4.21ms total, 8.1us/call avg
[sprof] samples recorded: 1847
[sprof] top 10 by flat:
[sprof]      312.4ms  31.2%  Array#each (app.rb)
[sprof]      198.7ms  19.9%  String#gsub (app.rb)
[sprof]      ...
[sprof] top 10 by cum:
[sprof]      987.3ms  98.7%  Object#main (app.rb)
[sprof]      ...
```

This includes:
- **Sampling overhead**: Total time and average time per sampling callback
- **Sample count**: Number of samples recorded (including GVL and GC samples)
- **Top functions**: By flat time (self time) and cumulative time (self + callees)

# Understanding pprof Output

## The pprof Format

sprof outputs profiles in the [pprof](#cite:pprof) protobuf format, the same format used by Go's built-in profiler and many other performance tools. The output is a gzip-compressed Protocol Buffer file (`.pb.gz`).

The pprof format encodes:

- **String table**: All unique strings (function names, file paths, units) stored once
- **Functions**: Each unique function with name and filename
- **Locations**: Points in the program mapped to functions
- **Samples**: Each sample is a stack of locations plus a weight value
- **Metadata**: Sample type (cpu/wall), unit (nanoseconds), and period

## Viewing with go tool pprof

### Interactive Web UI

The most powerful way to explore profiles:

```bash
go tool pprof -http=:8080 sprof.data
```

This opens a browser with:

- **Graph view**: Call graph showing time flow between functions
- **Flame graph**: Interactive flame chart
- **Top view**: Functions sorted by time
- **Source view**: Time attributed to source lines
- **Peek view**: Detailed callers/callees for a function

### Command-Line Reports

```bash
# Top functions by self (flat) time
go tool pprof -top sprof.data

# Top functions by cumulative time
go tool pprof -cum -top sprof.data

# Show only functions matching a regex
go tool pprof -top -nodecount=20 sprof.data

# Generate SVG graph
go tool pprof -svg sprof.data > graph.svg

# Generate flame graph as SVG
go tool pprof -flamegraph sprof.data > flame.svg
```

### Interactive Console

```bash
go tool pprof sprof.data
```

This drops you into an interactive console:

```
(pprof) top10
(pprof) top10 -cum
(pprof) list MyClass.my_method
(pprof) web              # open graph in browser
(pprof) png > out.png    # save graph as PNG
```

## Reading the Output

### Flat vs Cumulative Time

- **Flat (self) time**: Time spent directly in a function, excluding callees
- **Cumulative time**: Time spent in a function including all callees

Example `pprof -top` output:

```
Showing nodes accounting for 980ms, 98% of 1000ms total
      flat  flat%   sum%        cum   cum%
     320ms 32.00% 32.00%      320ms 32.00%  Array#each
     200ms 20.00% 52.00%      200ms 20.00%  String#gsub
     180ms 18.00% 70.00%      500ms 50.00%  MyApp#process
     150ms 15.00% 85.00%      150ms 15.00%  JSON.parse
     130ms 13.00% 98.00%      980ms 98.00%  Object#main
```

In this output, `MyApp#process` has 180ms flat time (its own code) but 500ms cumulative time (including the methods it calls).

### Synthetic Frames

sprof adds synthetic frames for non-CPU activity. These appear as leaf frames in the profile:

| Frame | Meaning | Mode |
|-------|---------|------|
| `[GVL blocked]` | Time off-GVL (I/O, sleep with GVL released) | Wall only |
| `[GVL wait]` | Time waiting to reacquire GVL | Wall only |
| `[GC marking]` | Time in GC mark phase | Both |
| `[GC sweeping]` | Time in GC sweep phase | Both |

These frames appear as children of the code that triggered the event. For example, a `[GVL blocked]` frame under `Net::HTTP#request` shows the I/O wait time for that HTTP call.

### CPU Mode vs Wall Mode Output

**CPU mode** output shows where CPU cycles are spent:

```
# CPU mode: only computation shows up
     320ms 64.00%  Array#each
     180ms 36.00%  String#gsub
```

**Wall mode** output shows where real time is spent, including waiting:

```
# Wall mode: I/O and GVL contention visible
     320ms 16.00%  Array#each
     180ms  9.00%  String#gsub
    1200ms 60.00%  [GVL blocked]    # I/O wait time
     300ms 15.00%  [GVL wait]       # GVL contention
```

## Filtering and Focusing

pprof supports powerful filtering:

```bash
# Show only functions in a specific file
go tool pprof -focus="app.rb" -top sprof.data

# Ignore standard library
go tool pprof -ignore="ruby/lib" -top sprof.data

# Show only a specific function and its callers/callees
go tool pprof -focus="MyApp.process" -http=:8080 sprof.data

# Trim insignificant nodes
go tool pprof -nodefraction=0.01 -top sprof.data
```

## Comparing Profiles

pprof can diff two profiles to show changes:

```bash
# Generate base and new profiles
sprof -o base.pb.gz exec ruby app.rb
# ... make changes ...
sprof -o new.pb.gz exec ruby app.rb

# Compare
go tool pprof -base=base.pb.gz -http=:8080 new.pb.gz
```

The diff view highlights functions that got faster (green) or slower (red).

> [!TIP]
> Profile comparison is one of the most useful features for performance optimization. Always capture a baseline profile before making changes so you can verify improvements.

## pprof Output Without Go

If you don't have Go installed, you can still work with sprof output:

1. **Raw data in Ruby**: Use `Sprof.stop` to get the data hash directly in your Ruby code
2. **Standalone pprof**: Install `github.com/google/pprof` as a standalone binary
3. **Programmatic access**: The `.pb.gz` file is a gzip-compressed Protocol Buffer that can be parsed by any protobuf library using the [profile.proto](https://github.com/google/pprof/blob/main/proto/profile.proto) schema

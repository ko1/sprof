# Usage Examples

## Profiling a CPU-Bound Script

This example profiles a Ruby script that performs heavy computation:

```ruby
# fibonacci.rb
def fibonacci(n)
  return n if n <= 1
  fibonacci(n - 1) + fibonacci(n - 2)
end

require "sprof"

Sprof.start(output: "fib_profile.pb.gz", frequency: 1000, mode: :cpu) do
  result = fibonacci(35)
  puts "fibonacci(35) = #{result}"
end
```

Run and view:

```bash
ruby fibonacci.rb
go tool pprof -http=:8080 fib_profile.pb.gz
```

The profile will show `fibonacci` consuming nearly 100% of CPU time, with the recursive calls visible in the flame graph.

## Profiling a Multi-Threaded Application

sprof automatically captures samples from all threads:

```ruby
require "sprof"

data = Sprof.start(frequency: 1000, mode: :cpu) do
  threads = 4.times.map do |i|
    Thread.new do
      # Each thread does different work
      case i
      when 0 then 10_000_000.times { "hello".upcase }
      when 1 then 10_000_000.times { [1, 2, 3].sort }
      when 2 then 10_000_000.times { {a: 1}.merge(b: 2) }
      when 3 then 10_000_000.times { "foo bar".split }
      end
    end
  end
  threads.each(&:join)
end

Sprof.save("threads_profile.pb.gz", data)
```

The pprof output will show all four workloads with CPU time proportional to their actual execution.

## Diagnosing GVL Contention

Wall mode reveals GVL contention through synthetic frames:

```ruby
require "sprof"
require "net/http"
require "uri"

Sprof.start(output: "gvl_profile.pb.gz", frequency: 100, mode: :wall) do
  threads = 8.times.map do
    Thread.new do
      10.times do
        # HTTP requests release the GVL during I/O
        uri = URI("https://httpbin.org/delay/0.1")
        Net::HTTP.get(uri)
      end
    end
  end
  threads.each(&:join)
end
```

```bash
go tool pprof -http=:8080 gvl_profile.pb.gz
```

In the flame graph, you'll see:

- `[GVL blocked]` frames under `Net::HTTP` calls showing I/O wait time
- `[GVL wait]` frames showing time threads spent waiting to reacquire the GVL
- Normal frames showing CPU time spent on request construction and response parsing

## Profiling with the CLI (Zero Code Changes)

Profile any Ruby program without modification:

```bash
# Profile a Rake task
sprof -o rake_profile.pb.gz -m cpu exec rake db:migrate

# Profile a Ruby script with wall mode
sprof -o wall_profile.pb.gz -m wall -f 200 exec ruby process_data.rb

# Profile with verbose output
sprof -v -o profile.pb.gz exec ruby app.rb
```

## Comparing CPU vs Wall Mode

Profile the same code in both modes to understand different bottlenecks:

```ruby
require "sprof"

def mixed_workload
  # CPU work
  1_000_000.times { Math.sqrt(rand) }

  # I/O (releases GVL)
  sleep 0.5

  # More CPU work
  500_000.times { "hello world".bytes.sum }
end

# CPU mode: shows only computation
Sprof.start(output: "cpu_profile.pb.gz", mode: :cpu) do
  mixed_workload
end

# Wall mode: shows computation + I/O + GVL events
Sprof.start(output: "wall_profile.pb.gz", mode: :wall) do
  mixed_workload
end
```

```bash
# Compare: CPU profile shows ~100% computation
go tool pprof -top cpu_profile.pb.gz

# Compare: Wall profile shows sleep dominating
go tool pprof -top wall_profile.pb.gz
```

In CPU mode, the `sleep` is invisible because no CPU time is consumed. In wall mode, the 0.5s sleep appears as `[GVL blocked]` time.

## Profiling GC Impact

sprof tracks GC phases automatically:

```ruby
require "sprof"

Sprof.start(output: "gc_profile.pb.gz", frequency: 1000, mode: :cpu) do
  # Generate GC pressure
  100_000.times do
    Array.new(1000) { Object.new }
  end
end
```

```bash
go tool pprof -top gc_profile.pb.gz
```

The output will include `[GC marking]` and `[GC sweeping]` frames showing how much time GC consumed and which code triggered it.

## Profiling a Rails Request

Profile Rails request handling using environment variables:

```bash
# Start Rails with sprof enabled
SPROF_ENABLED=1 SPROF_MODE=wall SPROF_FREQUENCY=200 \
  SPROF_OUTPUT=rails_profile.pb.gz \
  bundle exec rails runner "
    require 'rack/test'
    app = Rails.application
    env = Rack::MockRequest.env_for('/users')
    100.times { app.call(env) }
  "

go tool pprof -http=:8080 rails_profile.pb.gz
```

> [!TIP]
> For production profiling, use a low frequency (10-50 Hz) to minimize overhead. sprof's time-delta weighting ensures accuracy even at low sampling rates.

## Iterative Performance Optimization

A typical workflow for optimizing a method:

```bash
# 1. Capture baseline profile
sprof -o baseline.pb.gz exec ruby benchmark.rb

# 2. Identify hotspots
go tool pprof -top baseline.pb.gz

# 3. Make optimization
vim app.rb

# 4. Capture new profile
sprof -o optimized.pb.gz exec ruby benchmark.rb

# 5. Compare profiles
go tool pprof -base=baseline.pb.gz -http=:8080 optimized.pb.gz
```

The diff view in pprof will highlight exactly which functions improved and by how much.

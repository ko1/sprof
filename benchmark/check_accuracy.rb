#!/usr/bin/env ruby
# frozen_string_literal: true

# Sprof accuracy benchmark runner
#
# Usage:
#   ruby check_accuracy.rb                           # run all scenarios from scenarios_mixed.json
#   ruby check_accuracy.rb 42                        # run scenario #42
#   ruby check_accuracy.rb 10-19                     # run scenarios #10 through #19
#   ruby check_accuracy.rb 0 5 99                    # run specific scenarios
#   ruby check_accuracy.rb -f scenarios_rw.json      # use a different scenario file
#   ruby check_accuracy.rb -t 10                     # set pass tolerance to 10%
#   ruby check_accuracy.rb -m wall                   # use wall-time profiling mode
#   ruby check_accuracy.rb -l                        # run under CPU load (all cores busy)
#   ruby check_accuracy.rb -P stackprof              # use stackprof profiler
#   ruby check_accuracy.rb -P vernier                # use vernier profiler
#   ruby check_accuracy.rb -P pf2                    # use pf2 profiler

require "json"
require "open3"
require "etc"

FREQUENCY = 1000

# Parse options
scenario_file = File.join(__dir__, "scenarios_mixed.json")
tolerance = 0.20
profiling_mode = :cpu
profiler = "sprof"
args = ARGV.dup
if (idx = args.index("-f"))
  args.delete_at(idx)
  scenario_file = File.join(__dir__, args.delete_at(idx))
end
if (idx = args.index("-t"))
  args.delete_at(idx)
  tolerance = args.delete_at(idx).to_f / 100.0
end
if (idx = args.index("-m"))
  args.delete_at(idx)
  profiling_mode = args.delete_at(idx).to_sym
end
if (idx = args.index("-P"))
  args.delete_at(idx)
  profiler = args.delete_at(idx)
end
cpu_load = !!args.delete("-l")

scenarios = JSON.parse(File.read(scenario_file))

# Pick expected_ms key based on mode
expected_key = "expected_#{profiling_mode}_ms"

# Validate that the scenario file has the expected key
unless scenarios.first&.key?(expected_key)
  # Fallback: legacy format with "expected_ms"
  if scenarios.first&.key?("expected_ms")
    expected_key = "expected_ms"
  else
    abort "Scenario file missing '#{expected_key}' (mode: #{profiling_mode})"
  end
end

# Detect all method name prefixes used across scenarios
all_prefixes = scenarios.flat_map { |s| s["calls"].map { |name, _| name[/\A[a-z]+/] } }.uniq
method_prefix_re = all_prefixes.join("|")

# Parse arguments to select scenarios
selected =
  if args.empty?
    scenarios
  else
    ids = []
    args.each do |arg|
      if arg.include?("-")
        lo, hi = arg.split("-", 2).map(&:to_i)
        ids.concat((lo..hi).to_a)
      else
        ids << arg.to_i
      end
    end
    ids.map { |i| scenarios[i] || (abort "Scenario ##{i} not found") }
  end

puts "=== Sprof Accuracy Check ==="
puts "File: #{File.basename(scenario_file)}"
puts "Profiler: #{profiler}"
puts "Mode: #{profiling_mode}"
puts "Load: #{cpu_load ? "ON (#{Etc.nprocessors} cores)" : "off"}"
puts "Running #{selected.size} scenario(s) out of #{scenarios.size}"
puts

# Spawn CPU-hogging processes to simulate load
load_pids = []
if cpu_load
  Etc.nprocessors.times do
    load_pids << spawn("ruby", "-e", "loop {}", [:out, :err] => File::NULL)
  end
end

# --- Profiler-specific script generation ---

def generate_script_sprof(calls, output_path, profiling_mode)
  script = <<~RUBY
    $LOAD_PATH.unshift(File.join(__dir__, "..", "lib"))
    $LOAD_PATH.unshift(File.join(__dir__, "lib"))
    require "sprof"
    require "sprof_workload_methods"
    Sprof.start(frequency: #{FREQUENCY}, mode: :#{profiling_mode})
  RUBY
  calls.each { |name, usec| script << "SprofWorkload.#{name}(#{usec})\n" }
  script << "Sprof.save(#{output_path.inspect})\n"
  script
end

def generate_script_stackprof(calls, output_path, profiling_mode)
  mode = profiling_mode == :wall ? :wall : :cpu
  script = <<~RUBY
    $LOAD_PATH.unshift(File.join(__dir__, "lib"))
    require "stackprof"
    require "sprof_workload_methods"
    StackProf.run(mode: :#{mode}, interval: #{FREQUENCY}, raw: true, out: #{output_path.inspect}) do
  RUBY
  calls.each { |name, usec| script << "  SprofWorkload.#{name}(#{usec})\n" }
  script << "end\n"
  script
end

def generate_script_vernier(calls, output_path, profiling_mode)
  mode = profiling_mode == :wall ? :wall : :retained
  # Vernier supports :wall and :retained (no direct cpu mode); use wall for both
  # since cpu-time sampling is not supported in vernier
  script = <<~RUBY
    $LOAD_PATH.unshift(File.join(__dir__, "lib"))
    require "vernier"
    require "sprof_workload_methods"
    result = Vernier.trace(mode: :#{mode}, interval: #{FREQUENCY}) do
  RUBY
  calls.each { |name, usec| script << "  SprofWorkload.#{name}(#{usec})\n" }
  script << <<~RUBY
    end
    result.write(out: #{output_path.inspect})
  RUBY
  script
end

def generate_script_pf2(calls, output_path, profiling_mode)
  time_mode = profiling_mode == :wall ? :wall : :cpu
  script = <<~RUBY
    $LOAD_PATH.unshift(File.join(__dir__, "lib"))
    require "pf2"
    require "sprof_workload_methods"
    Pf2.profile(out: #{output_path.inspect}, format: :pprof, time_mode: :#{time_mode}) do
  RUBY
  calls.each { |name, usec| script << "  SprofWorkload.#{name}(#{usec})\n" }
  script << "end\n"
  script
end

# --- Profiler-specific result parsing ---

def parse_results_pprof(output_path, method_re)
  pprof_out, _pprof_err, pprof_status = Open3.capture3(
    "go", "tool", "pprof", "-top", "-nodecount=0", "-nodefraction=0", output_path
  )
  return nil, pprof_out unless pprof_status.success?

  actual_ms = {}
  pprof_out.each_line do |line|
    if line =~ method_re
      val = $1.to_f
      unit = $2
      name = $3
      actual_ms[name] = case unit
                        when "s"  then val * 1000.0
                        when "ms" then val
                        when "us" then val / 1000.0
                        else val
                        end
    end
  end
  [actual_ms, pprof_out]
end

def parse_results_stackprof(output_path, _method_re)
  raw_out, _err, status = Open3.capture3("stackprof", "--text", output_path)
  return nil, raw_out unless status.success?

  # Parse stackprof --text output:
  #      TOTAL    (pct)     SAMPLES    (pct)     FRAME
  #        234  (59.2%)          12   (3.0%)     SprofWorkload.rw317
  # TOTAL = cumulative sample count for the frame (what we want).
  # interval is in microseconds (cpu) or microseconds (wall).
  # Extract interval from the header: Mode: cpu(1000)
  interval_us = FREQUENCY
  if raw_out =~ /Mode:\s+\w+\((\d+)\)/
    interval_us = $1.to_i
  end

  actual_ms = {}
  raw_out.each_line do |line|
    if line =~ /^\s+(\d+)\s+\(\s*[\d.]+%\)\s+\d+\s+\(\s*[\d.]+%\)\s+SprofWorkload\.((#{$method_prefix_re_global})\d+)\s*$/
      total_samples = $1.to_i
      name = $2
      actual_ms[name] = total_samples * interval_us / 1000.0
    end
  end
  [actual_ms, raw_out]
end

def parse_results_vernier(output_path, _method_re)
  begin
    data = JSON.parse(File.read(output_path))
  rescue => e
    return nil, e.message
  end

  t = data["threads"][0]
  strings = t["stringArray"]
  func_table = t["funcTable"]
  frame_table = t["frameTable"]
  stack_table = t["stackTable"]
  samples = t["samples"]

  # Compute cumulative time per function by walking the full stack
  cum_time = Hash.new(0.0)
  samples["length"].times do |i|
    weight = samples["weight"][i]  # ms
    seen = {}
    idx = samples["stack"][i]
    while idx
      fi = stack_table["frame"][idx]
      funci = frame_table["func"][fi]
      name = strings[func_table["name"][funci]]
      # Strip "SprofWorkload." prefix if present
      short = name.sub(/\ASprofWorkload\./, "")
      unless seen[short]
        cum_time[short] += weight
        seen[short] = true
      end
      idx = stack_table["prefix"][idx]
    end
  end

  raw_out = cum_time.sort_by { |_, v| -v }.map { |n, v| "  #{n}: #{v.round(1)}ms" }.join("\n")
  [cum_time, raw_out]
end

# --- Main loop ---

all_errors = []
failures = []

# Build regex for pprof parsing based on method prefix
# Matches cum column (4th value column): flat flat% sum% CUM cum% name
pprof_method_re = /^\s*\S+\s+\S+\s+\S+\s+([\d.]+)(s|ms|us)\s+[\d.]+%\s+(?:SprofWorkload\.)?((#{method_prefix_re})\d+)\s*$/
# For stackprof (needs to be accessible from parse function)
$method_prefix_re_global = method_prefix_re

# Provide access to the prefix regex from stackprof parser
def method_prefix_re_global
  $method_prefix_re_global
end

selected.each do |scenario|
  scenario_id = scenario["id"]
  calls = scenario["calls"]
  expected_ms = scenario[expected_key]

  output_ext = case profiler
               when "vernier" then ".json"
               when "stackprof" then ".dump"
               else ".pb.gz"
               end
  output_path = File.join(__dir__, "output_#{scenario_id}#{output_ext}")

  # Generate test script
  script = case profiler
           when "sprof"    then generate_script_sprof(calls, output_path, profiling_mode)
           when "stackprof" then generate_script_stackprof(calls, output_path, profiling_mode)
           when "vernier"  then generate_script_vernier(calls, output_path, profiling_mode)
           when "pf2"      then generate_script_pf2(calls, output_path, profiling_mode)
           else abort "Unknown profiler: #{profiler}"
           end

  script_path = File.join(__dir__, "_bench_#{scenario_id}.rb")
  File.write(script_path, script)

  # Execute
  ruby_bin = RbConfig.ruby
  _stdout, stderr, status = Open3.capture3(ruby_bin, script_path)

  unless status.success?
    $stderr.puts "Scenario ##{scenario_id}: script failed: #{stderr}"
    failures << scenario_id
    File.delete(script_path) if File.exist?(script_path)
    next
  end

  # Parse results
  actual_ms, raw_out = case profiler
                       when "sprof", "pf2"
                         parse_results_pprof(output_path, pprof_method_re)
                       when "stackprof"
                         parse_results_stackprof(output_path, pprof_method_re)
                       when "vernier"
                         parse_results_vernier(output_path, pprof_method_re)
                       end

  unless actual_ms
    $stderr.puts "Scenario ##{scenario_id}: parse failed: #{raw_out}"
    failures << scenario_id
    File.delete(script_path) if File.exist?(script_path)
    File.delete(output_path) if File.exist?(output_path)
    next
  end

  # Compare
  errors = []
  expected_ms.each do |method, exp|
    act = actual_ms[method] || 0.0
    error = exp > 0 ? ((act - exp).abs / exp) : 0.0
    errors << error
  end

  avg_error = errors.empty? ? 0.0 : errors.sum / errors.size
  all_errors << avg_error
  pass = avg_error <= tolerance

  unless pass
    failures << scenario_id

    # Print details for failing scenarios
    puts format("--- Scenario #%-4d  FAIL (avg error: %.1f%%) ---", scenario_id, avg_error * 100)
    expected_ms.sort_by { |_, v| -v }.each do |method, exp|
      act = actual_ms[method] || 0.0
      err = exp > 0 ? ((act - exp).abs / exp * 100) : 0.0
      puts format("  %-20s  expected=%7.1fms  actual=%7.1fms  error=%5.1f%%", method, exp, act, err)
    end
    puts
    puts "  raw output:"
    raw_out.each_line { |l| puts "    #{l}" }
    puts
  end

  # Progress (compact for passing)
  if pass
    puts format("Scenario #%-4d  PASS (%.1f%%)", scenario_id, avg_error * 100)
  end

  # Cleanup temp files
  File.delete(script_path) if File.exist?(script_path)
  File.delete(output_path) if File.exist?(output_path)
end

# Kill load processes
load_pids.each do |pid|
  Process.kill(:TERM, pid) rescue nil
  Process.wait(pid) rescue nil
end

# Summary
puts
puts "=" * 50
overall_avg = all_errors.empty? ? 0.0 : all_errors.sum / all_errors.size
puts format("Scenarios: %d total, %d passed, %d failed",
            selected.size, selected.size - failures.size, failures.size)
puts format("Overall average error: %.1f%%", overall_avg * 100)

unless failures.empty?
  puts "Failed scenarios: #{failures.join(", ")}"
end

tol_pct = (tolerance * 100).to_i
if failures.empty? && overall_avg <= tolerance
  puts "PASS (< #{tol_pct}%)"
else
  puts "FAIL (> #{tol_pct}%)"
  exit 1
end

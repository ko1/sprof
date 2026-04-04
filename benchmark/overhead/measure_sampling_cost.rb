#!/usr/bin/env ruby
# frozen_string_literal: true

# Measure per-sample overhead (ns/sample) of rperf's sampling callback.
#
# Usage:
#   ruby measure_sampling_cost.rb                  # default: all modes, depth=1
#   ruby measure_sampling_cost.rb --depth 100      # deep stack
#   ruby measure_sampling_cost.rb --mode cpu       # cpu only
#   ruby measure_sampling_cost.rb --frequency 1000 # custom frequency
#   ruby measure_sampling_cost.rb --runs 10        # more runs

require "optparse"

$LOAD_PATH.unshift(File.join(__dir__, "..", "..", "lib"))
require "rperf"

depth = 1
modes = [:cpu, :wall]
frequency = 10000
runs = 5
iterations = 500_000

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"
  opts.on("--depth N", Integer, "Stack depth (default: #{depth})") { |v| depth = v }
  opts.on("--mode MODE", "cpu, wall, or both (default: both)") do |v|
    modes = v == "both" ? [:cpu, :wall] : [v.to_sym]
  end
  opts.on("--frequency N", Integer, "Sampling frequency in Hz (default: #{frequency})") { |v| frequency = v }
  opts.on("--runs N", Integer, "Number of runs per mode (default: #{runs})") { |v| runs = v }
  opts.on("--iterations N", Integer, "Workload iterations (default: #{iterations})") { |v| iterations = v }
end.parse!

def deep_call(depth, &block)
  if depth <= 1
    block.call
  else
    deep_call(depth - 1, &block)
  end
end

def measure(mode:, frequency:, runs:, iterations:, depth:)
  results = []

  runs.times do |i|
    Rperf.start(frequency: frequency, mode: mode, verbose: false)
    deep_call(depth) { iterations.times { 1 + 1 } }
    data = Rperf.stop
    next unless data

    count = data[:sampling_count]
    total_ns = data[:sampling_time_ns]
    avg = count > 0 ? total_ns.to_f / count : 0
    results << { run: i, samples: count, avg_ns: avg }
  end

  results
end

puts "rperf sampling cost benchmark"
puts "  frequency: #{frequency} Hz"
puts "  stack depth: #{depth}"
puts "  runs: #{runs}"
puts "  iterations: #{iterations}"
puts

modes.each do |mode|
  results = measure(mode: mode, frequency: frequency, runs: runs, iterations: iterations, depth: depth)
  avgs = results.map { |r| r[:avg_ns] }.sort

  # Trimmed mean: drop highest and lowest if enough runs
  trimmed = avgs.size >= 3 ? avgs[1..-2] : avgs
  mean = trimmed.sum / trimmed.size

  puts "#{mode} mode:"
  results.each do |r|
    puts "  run %d: %4d samples, %7.1f ns/sample" % [r[:run], r[:samples], r[:avg_ns]]
  end
  puts "  trimmed mean: %.1f ns/sample" % mean
  puts "  min: %.1f  max: %.1f  spread: %.1f" % [avgs.first, avgs.last, avgs.last - avgs.first]
  puts
end

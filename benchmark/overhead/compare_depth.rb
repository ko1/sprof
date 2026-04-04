#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare sampling cost across different stack depths.
# Shows how rb_profile_frames cost scales with stack depth.
#
# Usage:
#   ruby compare_depth.rb                  # default depths
#   ruby compare_depth.rb 1 50 100 200     # custom depths

require "optparse"

$LOAD_PATH.unshift(File.join(__dir__, "..", "..", "lib"))
require "rperf"

frequency = 10000
runs = 5
iterations = 500_000
modes = [:cpu, :wall]

depths = ARGV.empty? ? [1, 10, 50, 100, 200] : ARGV.map(&:to_i)

def deep_call(depth, &block)
  if depth <= 1
    block.call
  else
    deep_call(depth - 1, &block)
  end
end

def trimmed_mean(values)
  sorted = values.sort
  trimmed = sorted.size >= 3 ? sorted[1..-2] : sorted
  trimmed.sum / trimmed.size
end

puts "rperf sampling cost vs stack depth"
puts "  frequency: #{frequency} Hz, runs: #{runs}"
puts

modes.each do |mode|
  puts "#{mode} mode:"
  puts "  %8s  %12s  %8s" % ["depth", "ns/sample", "samples"]

  depths.each do |depth|
    avgs = []
    sample_counts = []

    runs.times do
      Rperf.start(frequency: frequency, mode: mode, verbose: false)
      deep_call(depth) { iterations.times { 1 + 1 } }
      data = Rperf.stop
      next unless data
      count = data[:sampling_count]
      total_ns = data[:sampling_time_ns]
      avgs << (count > 0 ? total_ns.to_f / count : 0)
      sample_counts << count
    end

    mean = trimmed_mean(avgs)
    median_samples = sample_counts.sort[sample_counts.size / 2]
    puts "  %8d  %12.1f  %8d" % [depth, mean, median_samples]
  end
  puts
end

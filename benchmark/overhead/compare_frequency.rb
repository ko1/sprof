#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare sampling cost and total overhead across different frequencies.
# Shows overhead as percentage of total runtime.
#
# Usage:
#   ruby compare_frequency.rb                          # default frequencies
#   ruby compare_frequency.rb 100 1000 5000 10000      # custom frequencies

require "optparse"

$LOAD_PATH.unshift(File.join(__dir__, "..", "..", "lib"))
require "rperf"

runs = 5
iterations = 1_000_000
modes = [:cpu, :wall]

frequencies = ARGV.empty? ? [100, 500, 1000, 5000, 10000] : ARGV.map(&:to_i)

def trimmed_mean(values)
  sorted = values.sort
  trimmed = sorted.size >= 3 ? sorted[1..-2] : sorted
  trimmed.sum / trimmed.size
end

puts "rperf overhead vs sampling frequency"
puts "  runs: #{runs}, iterations: #{iterations}"
puts

modes.each do |mode|
  puts "#{mode} mode:"
  puts "  %8s  %12s  %8s  %12s  %10s" % ["freq(Hz)", "ns/sample", "samples", "total(us)", "overhead%"]

  frequencies.each do |freq|
    avgs = []
    sample_counts = []
    total_overheads = []
    durations = []

    runs.times do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rperf.start(frequency: freq, mode: mode, verbose: false)
      iterations.times { 1 + 1 }
      data = Rperf.stop
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next unless data

      count = data[:sampling_count]
      total_ns = data[:sampling_time_ns]
      avgs << (count > 0 ? total_ns.to_f / count : 0)
      sample_counts << count
      total_overheads << total_ns
      durations << ((t1 - t0) * 1_000_000_000).to_i
    end

    mean_ns = trimmed_mean(avgs)
    median_samples = sample_counts.sort[sample_counts.size / 2]
    mean_total_us = trimmed_mean(total_overheads) / 1000.0
    mean_duration = trimmed_mean(durations)
    pct = mean_duration > 0 ? (trimmed_mean(total_overheads).to_f / mean_duration * 100) : 0

    puts "  %8d  %12.1f  %8d  %12.1f  %9.4f%%" % [freq, mean_ns, median_samples, mean_total_us, pct]
  end
  puts
end

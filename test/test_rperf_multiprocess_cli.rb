require_relative "test_helper"
require "open3"
require "json"
require "tmpdir"

class TestRperfMultiprocessCli < Test::Unit::TestCase
  include RperfTestHelper

  RPERF_EXE = File.expand_path("../exe/rperf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)
  RUBY = RbConfig.ruby

  private

  # Run rperf CLI in a clean subprocess.
  # Clears RPERF_* env vars to avoid interference from parent test process.
  def run_rperf(*args, env: {})
    clean_env = {
      "RPERF_ENABLED" => nil,
      "RPERF_SESSION_DIR" => nil,
      "RPERF_ROOT_PROCESS" => nil,
      "RPERF_OUTPUT" => nil,
      "RPERF_MODE" => nil,
      "RPERF_FREQUENCY" => nil,
      "RPERF_FORMAT" => nil,
      "RPERF_STAT" => nil,
      "RPERF_STAT_COMMAND" => nil,
      "RPERF_STAT_REPORT" => nil,
      "RPERF_VERBOSE" => nil,
      "RPERF_SIGNAL" => nil,
      "RPERF_AGGREGATE" => nil,
      "RPERF_TMPDIR" => nil,
    }.merge(env)
    cmd = [RUBY, "-I", LIB_DIR, RPERF_EXE, *args]
    Open3.capture3(clean_env, *cmd)
  end

  def load_profile(path)
    compressed = File.binread(path)
    raw = Zlib::GzipReader.new(StringIO.new(compressed)).read
    JSON.parse(raw, symbolize_names: true)
  end

  def with_tmpdir
    Dir.mktmpdir("rperf-test-") do |dir|
      yield dir
    end
  end

  # Helper: find distinct %pid values in label_sets
  def distinct_pids(data)
    ls = data[:label_sets] || []
    ls.map { |h| h[:"%pid"] }.compact.uniq
  end

  # Helper: check if a method name appears in aggregated_samples
  def has_method?(data, method_name)
    (data[:aggregated_samples] || []).any? do |frames, *|
      frames.any? { |_, label| label.to_s.include?(method_name) }
    end
  end

  # Helper: total weight for samples matching a method
  def method_weight(data, method_name)
    (data[:aggregated_samples] || []).select do |frames, *|
      frames.any? { |_, label| label.to_s.include?(method_name) }
    end.sum { |_, w, *| w }
  end

  public

  # --- Single process (no fork) ---

  def test_single_process_stat
    _, stderr, status = run_rperf("stat", "-f", "100",
                                  RUBY, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_not_include stderr, "processes profiled"
  end

  def test_single_process_record_no_session_dir
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf("record", "-f", "100", "-o", outfile,
                                RUBY, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      assert File.exist?(outfile)
      data = load_profile(outfile)
      assert_nil data[:process_count], "single process should not have process_count"
    end
  end

  # --- Fork ---

  def test_fork_stat_aggregates
    _, stderr, status = run_rperf(
      "stat", "-f", "100",
      RUBY, "-e", '3.times { fork { 500_000.times { 1 + 1 } } }; Process.waitall')
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_include stderr, "4"
    assert_include stderr, "Ruby processes profiled"
  end

  def test_fork_record_merges
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "500", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def root_work = 10_000_000.times { 1 + 1 }
          def child_work = 10_000_000.times { 1 + 1 }
          fork { child_work }
          Process.waitall
          root_work
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_equal 2, data[:process_count]
      assert has_method?(data, "root_work"), "root_work should be present"
      assert has_method?(data, "child_work"), "child_work should be present"
    end
  end

  # --- Spawn ---

  def test_spawn_stat_aggregates
    _, stderr, status = run_rperf(
      "stat", "-f", "100",
      RUBY, "-e", "pid = spawn('#{RUBY}', '-e', '500_000.times { 1 + 1 }'); Process.wait(pid)")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_include stderr, "2"
    assert_include stderr, "Ruby processes profiled"
    # Should only have one Performance stats block (no duplicate)
    assert_equal 1, stderr.scan("Performance stats").size,
                 "Should not have duplicate stat output"
  end

  def test_spawn_record_merges
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "500", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def root_spawn = 10_000_000.times { 1 + 1 }
          pid = spawn('#{RUBY}', '-e', 'def spawn_child = 10_000_000.times { 1 + 1 }; spawn_child')
          Process.wait(pid)
          root_spawn
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_equal 2, data[:process_count]
      assert has_method?(data, "root_spawn"), "root_spawn should be present"
      assert has_method?(data, "spawn_child"), "spawn_child should be present"
    end
  end

  # --- --no-inherit ---

  def test_no_inherit_fork_not_tracked
    _, stderr, status = run_rperf(
      "stat", "--no-inherit", "-f", "100",
      RUBY, "-e", '3.times { fork { 500_000.times { 1 + 1 } } }; Process.waitall')
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_not_include stderr, "processes profiled"
  end

  def test_no_inherit_record
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "--no-inherit", "-f", "100", "-o", outfile,
        RUBY, "-e", 'fork { 500_000.times { 1 + 1 } }; Process.waitall; 500_000.times { 1 + 1 }')
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_nil data[:process_count]
    end
  end

  # --- Nested fork (grandchild, great-grandchild) ---

  def test_nested_fork_4_generations
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "500", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def gen0_work = 5_000_000.times { 1 + 1 }
          def gen1_work = 5_000_000.times { 1 + 1 }
          def gen2_work = 5_000_000.times { 1 + 1 }
          def gen3_work = 5_000_000.times { 1 + 1 }
          fork {
            fork {
              fork { gen3_work }
              Process.waitall
              gen2_work
            }
            Process.waitall
            gen1_work
          }
          Process.waitall
          gen0_work
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_equal 4, data[:process_count]
      assert has_method?(data, "gen0_work"), "gen0 (root) should be present"
      assert has_method?(data, "gen1_work"), "gen1 (child) should be present"
      assert has_method?(data, "gen2_work"), "gen2 (grandchild) should be present"
      assert has_method?(data, "gen3_work"), "gen3 (great-grandchild) should be present"
    end
  end

  # --- Fork + system() mix ---

  def test_fork_and_system_mix
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "500", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def parent_mix = 5_000_000.times { 1 + 1 }
          def fork_child_mix = 5_000_000.times { 1 + 1 }
          fork { fork_child_mix }
          system('#{RUBY}', '-e', 'def system_child_mix = 5_000_000.times { 1 + 1 }; system_child_mix')
          Process.waitall
          parent_mix
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_equal 3, data[:process_count]
      assert has_method?(data, "parent_mix"), "parent should be present"
      assert has_method?(data, "fork_child_mix"), "fork child should be present"
      assert has_method?(data, "system_child_mix"), "system child should be present"
    end
  end

  # --- %pid label ---

  def test_pid_label_on_fork_children_not_root
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "500", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          fork { 5_000_000.times { 1 + 1 } }
          Process.waitall
          5_000_000.times { 1 + 1 }
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      pids = distinct_pids(data)
      assert_equal 1, pids.size, "should have exactly 1 child PID label"

      # Root samples should NOT have %pid
      ls = data[:label_sets] || []
      root_samples = (data[:aggregated_samples] || []).select do |_, _, _, lsi|
        lbl = ls[lsi] || {}
        !lbl.key?(:"%pid")
      end
      assert_operator root_samples.size, :>, 0, "root should have samples without %pid"
    end
  end

  # --- pid/ppid metadata in JSON ---

  def test_json_includes_pid_ppid
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "--no-inherit", "-f", "100", "-o", outfile,
        RUBY, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_not_nil data[:pid], "JSON should include pid"
      assert_not_nil data[:ppid], "JSON should include ppid"
    end
  end

  # --- GVL labels preserved in multi-process merge ---

  def test_gvl_labels_in_multiprocess_wall_mode
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "1000", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          fork { 10.times { sleep 0.05 } }
          fork { 10_000_000.times { 1 + 1 } }
          Process.waitall
          10_000_000.times { 1 + 1 }
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      ls = data[:label_sets] || []
      has_gvl_blocked = ls.any? { |h| h[:"%GVL"] == "blocked" }
      has_plain = ls.any? { |h| !h.key?(:"%GVL") && !h.key?(:"%GC") }
      assert has_gvl_blocked, "GVL blocked label should be present from sleeping child"
      assert has_plain, "CPU-only samples should be present"
      assert_equal 3, data[:process_count]
    end
  end

  # --- CPU mode: no GVL labels ---

  def test_cpu_mode_no_gvl_labels
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "1000", "-m", "cpu", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def cpu_r = 10_000_000.times { 1 + 1 }
          def cpu_c = 10_000_000.times { 1 + 1 }
          fork { cpu_c }
          Process.waitall
          cpu_r
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_equal "cpu", data[:mode].to_s
      assert_equal 2, data[:process_count]
      ls = data[:label_sets] || []
      has_gvl = ls.any? { |h| h.key?(:"%GVL") }
      assert !has_gvl, "CPU mode should not have GVL labels"
      assert has_method?(data, "cpu_r")
      assert has_method?(data, "cpu_c")
    end
  end

  # --- Wall mode: I/O time captured ---

  def test_wall_mode_captures_io_time
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "1000", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          fork { sleep 0.3 }
          fork { 10_000_000.times { 1 + 1 } }
          Process.waitall
          10_000_000.times { 1 + 1 }
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      ls = data[:label_sets] || []
      gvl_blocked_weight = (data[:aggregated_samples] || []).select { |_, _, _, lsi|
        lbl = ls[lsi] || {}
        lbl[:"%GVL"] == "blocked"
      }.sum { |_, w, *| w }
      # sleep 0.3 should produce >= 200ms of GVL blocked time
      assert_operator gvl_blocked_weight / 1_000_000, :>=, 200,
                      "Wall mode should capture >= 200ms of GVL blocked time from sleep"
    end
  end

  # --- CPU vs wall weight comparison ---

  def test_cpu_vs_wall_sleep_weight
    with_tmpdir do |dir|
      cpu_file = File.join(dir, "cpu.json.gz")
      wall_file = File.join(dir, "wall.json.gz")
      run_rperf("record", "-f", "1000", "-m", "cpu", "-o", cpu_file,
                RUBY, "-e", "fork { sleep 0.3 }; Process.waitall; sleep 0.3")
      run_rperf("record", "-f", "1000", "-m", "wall", "-o", wall_file,
                RUBY, "-e", "fork { sleep 0.3 }; Process.waitall; sleep 0.3")
      cpu_data = load_profile(cpu_file)
      wall_data = load_profile(wall_file)
      cpu_total = (cpu_data[:aggregated_samples] || []).sum { |_, w, *| w }
      wall_total = (wall_data[:aggregated_samples] || []).sum { |_, w, *| w }
      # Wall should be much larger than CPU for a sleep-only workload
      assert_operator wall_total, :>, cpu_total + 100_000_000,
                      "Wall total (#{wall_total / 1_000_000}ms) should be >> CPU total (#{cpu_total / 1_000_000}ms) for sleep workload"
    end
  end

  # --- signal: false (nanosleep mode) ---

  if RUBY_PLATFORM =~ /linux/
    def test_signal_false_with_fork
      with_tmpdir do |dir|
        outfile = File.join(dir, "out.json.gz")
        _, _, status = run_rperf(
          "record", "-f", "500", "-m", "wall", "--signal", "false", "-o", outfile,
          RUBY, "-e", <<~RUBY)
            def ns_root = 5_000_000.times { 1 + 1 }
            def ns_child = 5_000_000.times { 1 + 1 }
            fork { ns_child }
            Process.waitall
            ns_root
          RUBY
        assert_equal 0, status.exitstatus
        data = load_profile(outfile)
        assert_equal 2, data[:process_count]
        assert has_method?(data, "ns_root")
        assert has_method?(data, "ns_child")
      end
    end
  end

  # --- Weight distribution: equal workers ---

  def test_equal_workers_balanced_weight
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "1000", "-m", "cpu", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def equal_worker = 20_000_000.times { 1 + 1 }
          4.times { fork { equal_worker } }
          Process.waitall
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      ls = data[:label_sets] || []
      pid_weights = Hash.new(0)
      (data[:aggregated_samples] || []).each do |_, weight, _, lsi|
        lbl = ls[lsi] || {}
        pid_val = lbl[:"%pid"]
        next unless pid_val
        pid_weights[pid_val] += weight
      end
      assert_equal 4, pid_weights.size, "should have 4 worker PIDs"
      weights = pid_weights.values
      min_w = weights.min
      max_w = weights.max
      ratio = max_w.to_f / [min_w, 1].max
      assert_operator ratio, :<, 3.0,
                      "Weight should be roughly balanced (ratio=#{format('%.1f', ratio)}, min=#{min_w / 1_000_000}ms, max=#{max_w / 1_000_000}ms)"
    end
  end

  # --- Weight conservation: fork + spawn ---

  def test_weight_conservation_fork_and_spawn
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "1000", "-m", "wall", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def root_conserve = 10_000_000.times { 1 + 1 }
          def fork_conserve = 10_000_000.times { 1 + 1 }
          fork { fork_conserve }
          pid = spawn('#{RUBY}', '-e', 'def spawn_conserve = 10_000_000.times { 1 + 1 }; spawn_conserve')
          Process.wait(pid)
          Process.waitall
          root_conserve
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      %w[root_conserve fork_conserve spawn_conserve].each do |m|
        w = method_weight(data, m)
        assert_operator w, :>, 10_000_000,
                        "#{m} should have > 10ms weight (got #{w / 1_000_000}ms)"
      end
    end
  end

  # --- Large worker count ---

  def test_large_worker_count
    with_tmpdir do |dir|
      outfile = File.join(dir, "out.json.gz")
      _, _, status = run_rperf(
        "record", "-f", "500", "-m", "cpu", "-o", outfile,
        RUBY, "-e", <<~RUBY)
          def worker_task = 3_000_000.times { 1 + 1 }
          16.times { fork { worker_task } }
          Process.waitall
        RUBY
      assert_equal 0, status.exitstatus
      data = load_profile(outfile)
      assert_equal 17, data[:process_count], "should have 17 processes (1 root + 16 workers)"
      pids = distinct_pids(data)
      assert_equal 16, pids.size, "should have 16 distinct child PIDs"
    end
  end

  # --- Session dir cleanup ---

  def test_session_dir_cleaned_up_after_fork
    _, _, status = run_rperf(
      "stat", "-f", "100",
      RUBY, "-e", "fork { }; Process.waitall")
    assert_equal 0, status.exitstatus
    # Check no stale session dirs remain
    uid = Process.uid
    tmpdir = ENV["TMPDIR"] || "/tmp"
    user_dir = File.join(tmpdir, "rperf-#{uid}")
    if File.directory?(user_dir)
      entries = Dir.glob(File.join(user_dir, "rperf-*"))
      assert_equal 0, entries.size, "session dir should be cleaned up (found: #{entries})"
    end
  end

  # --- exec subcommand with fork ---

  def test_exec_with_fork
    _, stderr, status = run_rperf(
      "exec", "-f", "100",
      RUBY, "-e", '2.times { fork { 500_000.times { 1 + 1 } } }; Process.waitall')
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_include stderr, "3"
    assert_include stderr, "Ruby processes profiled"
    assert_include stderr, "Flat"
  end

  # --- Daemon child (outlives parent, profile lost gracefully) ---

  def test_daemon_child_does_not_crash_parent
    _, stderr, status = run_rperf(
      "stat", "-f", "100",
      RUBY, "-e", <<~RUBY)
        fork {
          Process.daemon(true, true)
          5_000_000.times { 1 + 1 }
        }
        5_000_000.times { 1 + 1 }
      RUBY
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
  end
end

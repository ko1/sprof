require_relative "test_helper"

class TestRperfGvl < Test::Unit::TestCase
  include RperfTestHelper

  def test_gvl_blocked_frames_wall_mode
    Rperf.start(frequency: 100, mode: :wall)

    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    has_blocked = labels.include?("[GVL blocked]")
    has_wait = labels.include?("[GVL wait]")

    assert has_blocked || has_wait,
      "Wall mode with sleep should produce [GVL blocked] or [GVL wait] samples"
  end

  def test_gvl_events_cpu_mode_no_synthetic
    Rperf.start(frequency: 100, mode: :cpu)

    threads = 4.times.map do
      Thread.new { 20.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    refute labels.include?("[GVL blocked]"),
      "CPU mode should NOT produce [GVL blocked] samples"
    refute labels.include?("[GVL wait]"),
      "CPU mode should NOT produce [GVL wait] samples"
  end

  def test_gvl_wait_weight_positive
    Rperf.start(frequency: 100, mode: :wall)

    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.001 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    gvl_samples = data[:aggregated_samples].select { |frames, _|
      frames.any? { |_, label| label == "[GVL blocked]" || label == "[GVL wait]" }
    }

    gvl_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GVL sample weight should be positive"
    end
  end

  # --- GC synthetic frames ---

  def test_gc_frames_wall_mode
    Rperf.start(frequency: 1000, mode: :wall)

    # Force GC repeatedly to generate GC samples
    arrays = []
    100.times do
      arrays << Array.new(10_000) { Object.new }
      arrays.shift if arrays.size > 5
      GC.start
    end

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    has_gc_marking = labels.include?("[GC marking]")
    has_gc_sweeping = labels.include?("[GC sweeping]")

    assert has_gc_marking || has_gc_sweeping,
      "Wall mode with forced GC should produce [GC marking] or [GC sweeping] samples"
  end

  def test_gc_frames_weight_positive
    Rperf.start(frequency: 1000, mode: :wall)

    arrays = []
    100.times do
      arrays << Array.new(10_000) { Object.new }
      arrays.shift if arrays.size > 5
      GC.start
    end

    data = Rperf.stop
    assert_not_nil data

    gc_samples = data[:aggregated_samples].select { |frames, _|
      frames.any? { |_, label| label == "[GC marking]" || label == "[GC sweeping]" }
    }

    gc_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GC sample weight should be positive"
    end
  end

  def test_gc_frames_cpu_mode_still_recorded
    # GC samples use wall time regardless of mode
    Rperf.start(frequency: 1000, mode: :cpu)

    arrays = []
    100.times do
      arrays << Array.new(10_000) { Object.new }
      arrays.shift if arrays.size > 5
      GC.start
    end

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    has_gc = labels.include?("[GC marking]") || labels.include?("[GC sweeping]")
    # GC frames should be recorded even in CPU mode (they use wall time)
    assert has_gc,
      "CPU mode should still record GC samples (with wall time weight)"
  end
end

require_relative "test_helper"

class TestRperfLabel < Test::Unit::TestCase
  include RperfTestHelper

  def test_label_with_block
    Rperf.start(frequency: 1000)
    assert_equal({}, Rperf.labels)

    Rperf.label(request: "abc") do
      assert_equal({ request: "abc" }, Rperf.labels)
      5_000_000.times { 1 + 1 }
    end

    assert_equal({}, Rperf.labels)
    data = Rperf.stop
    assert_not_nil data
  end

  def test_label_without_block
    Rperf.start(frequency: 1000)
    Rperf.label(request: "abc")
    assert_equal({ request: "abc" }, Rperf.labels)
    5_000_000.times { 1 + 1 }
    data = Rperf.stop
    assert_not_nil data
  end

  def test_label_merge
    Rperf.start(frequency: 1000)
    Rperf.label(request: "abc")
    Rperf.label(endpoint: "/api")
    assert_equal({ request: "abc", endpoint: "/api" }, Rperf.labels)
  end

  def test_label_overwrite
    Rperf.start(frequency: 1000)
    Rperf.label(request: "abc")
    Rperf.label(request: "def")
    assert_equal({ request: "def" }, Rperf.labels)
  end

  def test_label_delete_with_nil
    Rperf.start(frequency: 1000)
    Rperf.label(request: "abc", endpoint: "/api")
    Rperf.label(request: nil)
    assert_equal({ endpoint: "/api" }, Rperf.labels)
  end

  def test_nested_blocks
    Rperf.start(frequency: 1000)
    assert_equal({}, Rperf.labels)

    Rperf.label(request: "abc") do
      assert_equal({ request: "abc" }, Rperf.labels)

      Rperf.label(phase: "db") do
        assert_equal({ request: "abc", phase: "db" }, Rperf.labels)
      end

      assert_equal({ request: "abc" }, Rperf.labels)
    end

    assert_equal({}, Rperf.labels)
  end

  def test_block_restores_after_inner_set
    Rperf.start(frequency: 1000)

    Rperf.label(foo: "bar") do
      Rperf.label(foo: "baz")
      Rperf.label(x: "1")
      assert_equal({ foo: "baz", x: "1" }, Rperf.labels)
    end

    assert_equal({}, Rperf.labels)
  end

  def test_label_in_result_data
    Rperf.start(frequency: 1000)

    Rperf.label(request: "abc") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_not_nil data[:label_sets]
    assert_kind_of Array, data[:label_sets]

    # Some samples should have label_set_id > 0
    labeled_samples = data[:aggregated_samples].select { |_, _, _, lsi| lsi && lsi > 0 }
    assert_operator labeled_samples.size, :>, 0, "Should have labeled samples"
  end

  def test_label_in_snapshot
    Rperf.start(frequency: 1000)

    Rperf.label(request: "abc") do
      5_000_000.times { 1 + 1 }
      snap = Rperf.snapshot
      assert_not_nil snap[:label_sets]

      labeled = snap[:aggregated_samples].select { |_, _, _, lsi| lsi && lsi > 0 }
      assert_operator labeled.size, :>, 0, "Snapshot should have labeled samples"
    end
  end

  def test_label_pprof_encoding
    Rperf.start(frequency: 1000)

    Rperf.label(request: "test-123") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    pprof = Rperf::PProf.encode(data)
    assert_kind_of String, pprof
    assert_operator pprof.bytesize, :>, 0

    # The label key and value strings should be in the protobuf
    assert_include pprof, "request"
    assert_include pprof, "test-123"
  end

  def test_label_collapsed_encoding
    Rperf.start(frequency: 1000)

    Rperf.label(request: "abc") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    collapsed = Rperf::Collapsed.encode(data)
    assert_kind_of String, collapsed
    assert_operator collapsed.size, :>, 0
  end

  def test_label_multithread
    Rperf.start(frequency: 1000, mode: :wall)

    threads = 2.times.map do |i|
      Thread.new do
        Rperf.label(thread_name: "worker-#{i}") do
          5_000_000.times { 1 + 1 }
        end
      end
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data[:label_sets]
  end

  def test_labels_empty_when_not_profiling
    assert_equal({}, Rperf.labels)
  end

  def test_label_dedup
    Rperf.start(frequency: 1000)
    # Same label set should get same id
    Rperf.label(a: "1")
    id1 = Rperf.send(:_c_get_label)
    Rperf.label(a: nil)
    Rperf.label(a: "1")
    id2 = Rperf.send(:_c_get_label)
    assert_equal id1, id2, "Same label set should be deduped to same id"
  end

  def test_label_text_encoding
    Rperf.start(frequency: 1000)

    Rperf.label(request: "abc") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    text = Rperf::Text.encode(data)
    assert_kind_of String, text
    assert_include text, "Total:"
  end

  def test_label_no_label_sets_when_unused
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    data = Rperf.stop

    # If labels were never used, label_sets should not be in data
    assert_nil data[:label_sets]
  end

  def test_label_block_restores_on_exception
    Rperf.start(frequency: 1000)

    begin
      Rperf.label(request: "abc") do
        raise "boom"
      end
    rescue RuntimeError
    end

    assert_equal({}, Rperf.labels, "Labels should be restored after exception")
  end
end

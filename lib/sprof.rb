require "sprof.so"
require "zlib"
require "stringio"

module Sprof
  VERSION = "0.1.0"

  def self.save(path)
    data = stop
    return unless data

    encoded = PProf.encode(data)
    File.binwrite(path, gzip(encoded))
  end

  def self.profile(output: "sprof.data", frequency: 1000, mode: :cpu)
    start(frequency: frequency, mode: mode)
    yield
  ensure
    save(output)
  end

  def self.gzip(data)
    io = StringIO.new
    io.set_encoding("ASCII-8BIT")
    gz = Zlib::GzipWriter.new(io)
    gz.write(data)
    gz.close
    io.string
  end

  # ENV-based auto-start for CLI usage
  if ENV["SPROF_ENABLED"] == "1"
    _sprof_mode = ENV["SPROF_MODE"] == "wall" ? :wall : :cpu
    start(frequency: (ENV["SPROF_FREQUENCY"] || 1000).to_i, mode: _sprof_mode)
    at_exit { save(ENV["SPROF_OUTPUT"] || "sprof.data") }
  end

  # Hand-written protobuf encoder for pprof profile format.
  # Only runs once at stop time, so performance is not critical.
  module PProf
    module_function

    def encode(data)
      string_table = data[:string_table]
      samples_raw = data[:samples]
      frequency = data[:frequency]
      interval_ns = 1_000_000_000 / frequency

      mode = data[:mode] || :cpu

      # Merge samples with identical stacks
      merged = merge_samples(samples_raw)

      # Build location/function tables
      locations, functions = build_tables(merged, string_table)

      # Intern type label and unit in string table
      type_label = mode == :wall ? "wall" : "cpu"
      type_idx = string_table_index(string_table, type_label)
      ns_idx = string_table_index(string_table, "nanoseconds")

      # Encode Profile message
      buf = "".b

      # field 1: sample_type (repeated ValueType)
      buf << encode_message(1, encode_value_type(type_idx, ns_idx))

      # field 2: sample (repeated Sample)
      merged.each do |frames, weight|
        sample_buf = "".b
        # location_id (repeated uint64, packed)
        loc_ids = frames.map { |f| locations[f] }
        sample_buf << encode_packed_uint64(1, loc_ids)
        # value (repeated int64, packed)
        sample_buf << encode_packed_int64(2, [weight])
        buf << encode_message(2, sample_buf)
      end

      # field 4: location (repeated Location)
      locations.each do |frame, loc_id|
        loc_buf = "".b
        loc_buf << encode_uint64(1, loc_id) # id
        # line (repeated Line)
        line_buf = "".b
        func_id = functions[frame]
        line_buf << encode_uint64(1, func_id)   # function_id
        line_buf << encode_int64(2, frame[2])    # line
        loc_buf << encode_message(4, line_buf)
        buf << encode_message(4, loc_buf)
      end

      # field 5: function (repeated Function)
      functions.each do |frame, func_id|
        func_buf = "".b
        func_buf << encode_uint64(1, func_id)   # id
        func_buf << encode_int64(2, frame[1])    # name (label_idx)
        func_buf << encode_int64(4, frame[0])    # filename (path_idx)
        buf << encode_message(5, func_buf)
      end

      # field 6: string_table (repeated string)
      string_table.each do |s|
        buf << encode_bytes(6, s.encode("UTF-8"))
      end

      # field 11: period_type (ValueType)
      buf << encode_message(11, encode_value_type(type_idx, ns_idx))

      # field 12: period (int64)
      buf << encode_int64(12, interval_ns)

      buf
    end

    def merge_samples(samples_raw)
      merged = Hash.new(0)
      samples_raw.each do |frames, weight|
        key = frames.map { |f| [f[0], f[1], f[2]] }
        merged[key] += weight
      end
      merged.to_a
    end

    def build_tables(merged, string_table)
      locations = {}  # frame_key -> location_id
      functions = {}  # frame_key -> function_id
      next_id = 1

      merged.each do |frames, _weight|
        frames.each do |frame|
          unless locations.key?(frame)
            locations[frame] = next_id
            functions[frame] = next_id
            next_id += 1
          end
        end
      end

      [locations, functions]
    end

    def string_table_index(string_table, str)
      idx = string_table.index(str)
      unless idx
        idx = string_table.size
        string_table << str
      end
      idx
    end

    # --- Protobuf encoding helpers ---

    def encode_varint(value)
      value = value & 0xFFFFFFFF_FFFFFFFF if value < 0  # zigzag not needed for unsigned
      buf = "".b
      loop do
        byte = value & 0x7F
        value >>= 7
        if value > 0
          buf << (byte | 0x80).chr
        else
          buf << byte.chr
          break
        end
      end
      buf
    end

    def encode_uint64(field, value)
      encode_varint((field << 3) | 0) + encode_varint(value)
    end

    def encode_int64(field, value)
      encode_varint((field << 3) | 0) + encode_varint(value < 0 ? value + (1 << 64) : value)
    end

    def encode_bytes(field, data)
      data = data.b if data.respond_to?(:b)
      encode_varint((field << 3) | 2) + encode_varint(data.bytesize) + data
    end

    def encode_message(field, data)
      encode_bytes(field, data)
    end

    def encode_value_type(type_idx, unit_idx)
      encode_int64(1, type_idx) + encode_int64(2, unit_idx)
    end

    def encode_packed_uint64(field, values)
      inner = values.map { |v| encode_varint(v) }.join
      encode_bytes(field, inner)
    end

    def encode_packed_int64(field, values)
      inner = values.map { |v| encode_varint(v < 0 ? v + (1 << 64) : v) }.join
      encode_bytes(field, inner)
    end
  end
end

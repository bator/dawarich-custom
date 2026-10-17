# frozen_string_literal: true

require 'csv'

# Streams the CSV files of a GTFS zip without extracting it to disk (spec 7.2,
# 7.3). Guards against zip bombs and path traversal, reads columns by header
# name (column order differs per feed), strips a UTF-8 BOM and treats
# unresolved template placeholders such as "${realcity...}" as blank.
class Gtfs::ZipReader
  class Error < StandardError; end
  class UnsafeArchive < Error; end
  class MissingFile < Error; end
  class MissingColumn < Error; end

  KNOWN_FILES = %w[
    agency.txt stops.txt routes.txt trips.txt stop_times.txt calendar.txt
    calendar_dates.txt shapes.txt frequencies.txt transfers.txt feed_info.txt
  ].freeze
  MAX_ENTRIES = ENV.fetch('GTFS_MAX_ZIP_ENTRIES', 100).to_i
  MAX_UNCOMPRESSED_BYTES = ENV.fetch('GTFS_MAX_UNCOMPRESSED_BYTES', 8 * 1024**3).to_i
  PLACEHOLDER = /\A\$\{[^}]*\}\z/
  HEADER_CONVERTER = ->(h) { h.to_s.delete("\uFEFF").strip.downcase }

  CP1250_UNDEFINED = [0x81, 0x83, 0x88, 0x90, 0x98].freeze
  NON_ASCII = /[^\x00-\x7F]/

  attr_reader :placeholder_count, :legacy_lines, :dropped_bytes

  def self.open(path, max_uncompressed_bytes: MAX_UNCOMPRESSED_BYTES, max_entries: MAX_ENTRIES)
    reader = new(path, max_uncompressed_bytes:, max_entries:)
    reader.open
    yield reader
  ensure
    reader&.close
  end

  def initialize(path, max_uncompressed_bytes: MAX_UNCOMPRESSED_BYTES, max_entries: MAX_ENTRIES)
    @path = path
    @max_uncompressed_bytes = max_uncompressed_bytes
    @max_entries = max_entries
    @placeholder_count = 0
    @legacy_lines = 0
    @dropped_bytes = 0
    @bytes_read = 0
  end

  def open
    @zip = Zip::File.open(@path)
    @entries = index_entries
    self
  rescue Zip::Error => e
    raise Error, "not a readable zip archive: #{e.message}"
  end

  def close
    @zip&.close
  end

  def file?(name)
    @entries.key?(name)
  end

  def files
    @entries.keys.sort
  end

  # Yields one Hash per data row (keys are normalized header names, values are
  # UTF-8 strings or nil). Returns the number of yielded rows.
  def each_row(name, required: [])
    entry = @entries[name] || raise(MissingFile, "#{name} is missing from the feed")
    count = 0
    entry.get_input_stream do |raw|
      csv = CSV.new(Utf8Stream.new(raw, self), headers: true, return_headers: false,
                    header_converters: HEADER_CONVERTER, liberal_parsing: true, skip_blanks: true,
                    row_sep: "\n")
      checked = false
      csv.each do |row|
        unless checked
          missing = required - row.headers
          raise MissingColumn, "#{name}: missing required column(s) #{missing.join(', ')}" if missing.any?

          checked = true
        end
        count += 1
        yield clean(row)
      end
      if !checked && required.any?
        headers = csv.headers.is_a?(Array) ? csv.headers : []
        missing = required - headers
        raise MissingColumn, "#{name}: missing required column(s) #{missing.join(', ')}" if missing.any?
      end
    end
    count
  rescue CSV::MalformedCSVError => e
    raise Error, "#{name}: malformed CSV (#{e.message})"
  rescue Zip::Error, Zlib::Error, EOFError => e
    # Corrupt or truncated entry (e.g. Zip::EntrySizeError when the declared
    # size lies): deterministic, so it must not be retried like a network error.
    raise Error, "#{name}: cannot read zip entry (#{e.class}: #{e.message})"
  end

  # Turns one chunk of raw bytes into UTF-8 (K3). Valid UTF-8 is returned as
  # is. A chunk that contains valid multi-byte UTF-8 but also broken bytes is
  # scrubbed (dropped bytes are counted). A chunk without any valid UTF-8
  # sequence is treated as a legacy Windows-1250 line (Hungarian feeds).
  def decode(bytes)
    utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
    return utf8 if utf8.valid_encoding?

    scrubbed = utf8.scrub('')
    if scrubbed.match?(NON_ASCII)
      @dropped_bytes += utf8.bytesize - scrubbed.bytesize
      return scrubbed
    end

    @legacy_lines += 1
    @dropped_bytes += bytes.each_byte.count { |b| CP1250_UNDEFINED.include?(b) }
    bytes.dup.force_encoding(Encoding::Windows_1250)
         .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
  end

  # Called by Utf8Stream for every chunk actually inflated: protects against
  # archives whose declared sizes lie.
  def track_bytes!(bytes)
    @bytes_read += bytes
    return if @bytes_read <= @max_uncompressed_bytes

    raise UnsafeArchive, "uncompressed data exceeds #{@max_uncompressed_bytes} bytes"
  end

  private

  def index_entries
    entries = @zip.entries
    raise UnsafeArchive, "too many zip entries (#{entries.size} > #{@max_entries})" if entries.size > @max_entries

    total = 0
    found = {}
    entries.each do |entry|
      name = entry.name.to_s
      raise UnsafeArchive, "unsafe entry name #{name.inspect}" if unsafe_name?(name)
      next if entry.directory?

      total += entry.size.to_i
      if total > @max_uncompressed_bytes
        raise UnsafeArchive,
              "declared uncompressed size exceeds #{@max_uncompressed_bytes} bytes"
      end

      base = File.basename(name).downcase
      next unless KNOWN_FILES.include?(base)
      # Accept files at the root or inside one top-level folder; root wins.
      next if found[base] && found[base].name.count('/') <= name.count('/')
      next if name.count('/') > 1

      found[base] = entry
    end
    found
  end

  def unsafe_name?(name)
    name.start_with?('/', '\\') || name.match?(/\A[a-zA-Z]:/) ||
      name.split(%r{[/\\]}).include?('..') || name.include?("\0")
  end

  def clean(row)
    row.to_h.transform_values do |value|
      next nil if value.nil?

      value = value.strip
      if value.empty?
        nil
      elsif PLACEHOLDER.match?(value)
        @placeholder_count += 1
        nil
      else
        value
      end
    end
  end

  # Minimal IO facade: inflated bytes as UTF-8 (see ZipReader#decode) with
  # byte accounting for the zip-bomb guard. Line endings are normalized to LF
  # because real feeds mix CRLF and LF inside one file (e.g. weekendbus
  # calendar_dates.txt has a CRLF header and LF rows), which CSV rejects.
  # CSV reads with a byte limit (gets("\n", 8192)), so a chunk can end inside
  # a multi-byte character: the missing continuation bytes are read before
  # decoding. NUL bytes are removed (PostgreSQL text cannot store them).
  class Utf8Stream
    def initialize(io, reader)
      @io = io
      @reader = reader
      @pending = nil
    end

    def gets(*args)
      normalize(take_pending(@io.gets(*args)))
    end

    def read(*args)
      normalize(take_pending(@io.read(*args)))
    end

    def eof?
      @pending.nil? && @io.eof?
    end
    alias eof eof?

    def external_encoding
      Encoding::UTF_8
    end

    def internal_encoding
      nil
    end

    def close; end

    private

    def take_pending(data)
      return data if @pending.nil?

      pending = @pending
      @pending = nil
      data.nil? ? pending : pending + data
    end

    def normalize(data)
      return nil if data.nil?

      @reader.track_bytes!(data.bytesize)
      data = data.b
      if data.end_with?("\r")
        # A chunk may end between "\r" and "\n": look one byte ahead.
        following = @io.read(1)
        if following == "\n"
          @reader.track_bytes!(1)
          data << following
        else
          @pending = following
        end
      else
        complete_character!(data)
      end
      @reader.decode(data.gsub("\r\n", "\n").delete("\0"))
    end

    # If the chunk ends with an incomplete UTF-8 sequence, read the missing
    # continuation bytes (at most 3) so the character is not split.
    def complete_character!(data)
      missing = missing_utf8_bytes(data)
      return if missing.zero?

      rest = @io.read(missing)
      return if rest.nil?

      @reader.track_bytes!(rest.bytesize)
      data << rest.b
    end

    def missing_utf8_bytes(data)
      tail = data.byteslice([data.bytesize - 3, 0].max, 3).bytes
      tail.reverse.each_with_index do |byte, back|
        next if byte.between?(0x80, 0xBF) # continuation byte, keep looking

        needed = if byte.between?(0xC2, 0xDF) then 2
                 elsif byte.between?(0xE0, 0xEF) then 3
                 elsif byte.between?(0xF0, 0xF4) then 4
                 else 0
                 end
        present = back + 1
        return needed > present ? needed - present : 0
      end
      0
    end
  end
end

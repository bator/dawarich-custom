# frozen_string_literal: true

# Bulk loader using PostgreSQL COPY ... FROM STDIN (text format) on the
# current ActiveRecord connection. Rows are buffered and flushed in chunks.
class Gtfs::CopyWriter
  FLUSH_BYTES = 1 << 20

  # Each COPY runs in its own (sub)transaction: if the block raises, only this
  # COPY is rolled back and the connection stays usable for error handling.
  def self.copy(table, columns, connection: ActiveRecord::Base.connection, &)
    connection.transaction(requires_new: true) { copy_rows(table, columns, connection, &) }
  end

  def self.copy_rows(table, columns, connection)
    writer = new(connection.raw_connection)
    count = 0
    writer.raw.copy_data("COPY #{table} (#{columns.join(', ')}) FROM STDIN") do
      buffer = +''
      yield(lambda do |values|
        buffer << encode_row(values)
        count += 1
        if buffer.bytesize >= FLUSH_BYTES
          writer.raw.put_copy_data(buffer)
          buffer = +''
        end
      end)
      writer.raw.put_copy_data(buffer) unless buffer.empty?
    end
    count
  end

  def self.encode_row(values)
    values.map { |v| encode_value(v) }.join("\t") << "\n"
  end

  def self.encode_value(value)
    case value
    when nil then '\N'
    when true then 't'
    when false then 'f'
    when Integer, Float then value.to_s
    else
      value.to_s.gsub(/[\\\t\n\r]/, '\\' => '\\\\', "\t" => '\t', "\n" => '\n', "\r" => '\r')
    end
  end

  attr_reader :raw

  def initialize(raw)
    @raw = raw
  end
end

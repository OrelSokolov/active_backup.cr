# ustar (POSIX tar) writer/reader — the container format of every
# ActiveBackup archive. P0 scope: regular files and directories, names
# up to 255 bytes via the prefix field; no symlinks/hardlinks, no
# PAX/GNU long-name extensions (unknown typeflags are skipped on read).
#
# Two-way compatibility with real tooling is the contract (verified in
# spec/tar_spec.cr against the system GNU tar):
#   - archives this writer produces are listed/extracted by `tar`;
#   - archives produced by GNU tar are read by `Reader`
#     (oracle/fixtures/gnu.tar is committed for that direction).

module ActiveBackup
  module Tar
    class HeaderError < Exception
    end

    class CorruptError < Exception
    end

    BLOCK = 512

    # --- writer -------------------------------------------------------------

    class Writer
      def initialize(@io : IO)
        @finished = false
      end

      def add_dir(name : String, mtime : Time = Time.utc,
                  mode : Int32 = 0o755) : Nil
        write_header(name.rstrip('/') + "/", 0, mtime, mode, '5')
      end

      # Streaming form: the block writes exactly `size` bytes to the io.
      def add_file(name : String, size : Int64, mtime : Time = Time.utc,
                   mode : Int32 = 0o644, & : IO ->) : Nil
        write_header(name, size, mtime, mode, '0')
        counting = CountingIO.new(@io)
        yield counting
        raise HeaderError.new(
          "short write for #{name}: expected #{size}, wrote #{counting.count}") \
          unless counting.count == size
        pad_to_block(size)
      end

      def add_file(name : String, data : String | Bytes,
                   mtime : Time = Time.utc, mode : Int32 = 0o644) : Nil
        bytes = data.to_slice
        add_file(name, bytes.size.to_i64, mtime, mode) { |io| io.write(bytes) }
      end

      # Two zero blocks mark the end of the archive (readers stop here;
      # record-level blocking padding is not required by GNU tar).
      def close : Nil
        return if @finished
        @finished = true
        @io.write(Bytes.new(BLOCK * 2, 0))
      end

      private def write_header(name : String, size : Int64, mtime : Time,
                               mode : Int32, type : Char) : Nil
        raise HeaderError.new("empty name") if name.empty?
        name_field, prefix = split_name(name)
        h = Bytes.new(BLOCK, 0)
        put_string(h, 0, 100, name_field)
        put_octal(h, 100, 7, mode)
        put_octal(h, 108, 7, 0)   # uid
        put_octal(h, 116, 7, 0)   # gid
        put_octal(h, 124, 11, size)
        put_octal(h, 136, 11, Math.max(mtime.to_unix, 0))
        h.fill(32.to_u8!, 148, 8) # chksum field = spaces while summing
        h[156] = type.ord.to_u8!
        put_string(h, 257, 6, "ustar\0")
        put_string(h, 263, 2, "00")
        put_string(h, 345, 155, prefix)
        checksum = 0
        BLOCK.times { |i| checksum += h[i] }
        checksum &= 0o777777
        s = checksum.to_s(8).rjust(6, '0')
        put_string(h, 148, 6, s)
        h[154] = 0
        h[155] = 32
        @io.write(h)
      end

      private def put_string(buf : Bytes, offset : Int32, width : Int32,
                             value : String) : Nil
        bytes = value.to_slice
        raise HeaderError.new("field too long (#{value.bytesize} > #{width})") \
          if bytes.size > width
        buf[offset, bytes.size].copy_from(bytes)
      end

      private def put_octal(buf : Bytes, offset : Int32, digits : Int32,
                            value : Int64 | Int32) : Nil
        s = value.to_i64.to_s(8).rjust(digits, '0')
        raise HeaderError.new("octal field overflow: #{value}") \
          if s.size > digits
        buf[offset, s.bytesize].copy_from(s.to_slice)
        # the last byte of the field stays NUL
      end

      # ustar long names: split at a '/' so the base fits in name[100]
      # and the directory part fits in prefix[155].
      private def split_name(name : String) : {String, String}
        return {name, ""} if name.bytesize <= 100
        bytes = name.to_slice
        best_split = -1
        bytes.each_with_index do |b, i|
          next unless b == '/'.ord.to_u8!
          next if i == 0
          prefix_len = i
          base_len = bytes.size - i - 1
          if prefix_len <= 155 && base_len <= 100 && base_len > 0
            best_split = i
            break
          end
        end
        raise HeaderError.new(
          "name too long for ustar (#{name.bytesize} bytes): #{name}") \
          if best_split < 0
        {name[(best_split + 1)..], name[0...best_split]}
      end

      private def pad_to_block(size : Int64) : Nil
        rem = (BLOCK - (size % BLOCK)) % BLOCK
        @io.write(Bytes.new(rem, 0)) if rem > 0
      end
    end

    # Counts bytes passing through so add_file can assert the caller
    # wrote exactly the announced size.
    private class CountingIO < IO
      def initialize(@io : IO)
        @count = 0_i64
      end

      def count : Int64
        @count
      end

      def write(slice : Bytes) : Nil
        @io.write(slice)
        @count += slice.size
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("not readable")
      end
    end

    # --- reader -------------------------------------------------------------

    class Entry
      getter name : String
      getter typeflag : Char
      getter size : Int64
      getter mode : Int32
      getter mtime : Time?

      def initialize(@name : String, @typeflag : Char, @size : Int64,
                     @mode : Int32, @mtime : Time?, @io : IO)
        @pos = 0_i64
      end

      def dir? : Bool
        @typeflag == '5'
      end

      def file? : Bool
        @typeflag == '0' || @typeflag == '\0'
      end

      def each_chunk(chunk : Int32 = 8192, & : Bytes ->) : Nil
        remaining = @size - @pos
        while remaining > 0
          buf = Bytes.new(Math.min(chunk, remaining).to_i32)
          read_bytes = @io.read(buf)
          raise CorruptError.new("unexpected EOF in #{@name}") if read_bytes == 0
          @pos += read_bytes
          remaining -= read_bytes
          yield buf[0, read_bytes]
        end
      end

      def content : Bytes
        raise CorruptError.new("entry too large: #{@name}") if @size > Int32::MAX
        buf = Bytes.new(@size.to_i32)
        @io.read_fully(buf)
        @pos = @size
        buf
      end

      def copy_to(io : IO) : Nil
        each_chunk { |chunk| io.write(chunk) }
      end

      def sha256 : String
        digest = Digest::SHA256.new
        each_chunk { |chunk| digest.update(chunk) }
        digest.hexfinal
      end

      def skip : Nil
        each_chunk { |_| }
        drain_padding
      end

      # tar pads every member's content to a 512-byte boundary
      private def drain_padding : Nil
        rem = (BLOCK - (@size % BLOCK)) % BLOCK
        while rem > 0
          buf = Bytes.new(Math.min(rem, 8192).to_i32)
          n = @io.read(buf)
          raise CorruptError.new("unexpected EOF in #{@name}") if n == 0
          rem -= n
        end
      end
    end

    class Reader
      def initialize(@io : IO)
      end

      # Yields every entry; entries not fully consumed by the block are
      # drained automatically before the next header is read.
      def each(& : Entry ->) : Nil
        loop do
          entry = next_entry || break
          begin
            yield entry
          ensure
            entry.skip
          end
        end
      end

      def next_entry : Entry?
        header = Bytes.new(BLOCK)
        read = @io.read_fully?(header)
        return nil unless read == BLOCK
        # First all-zero block = end of archive (GNU tar semantics).
        return nil if header.all?(&.zero?)

        name = cstring(header, 0, 100)
        mode = octal(header, 100, 8).to_i32
        size = octal(header, 124, 12)
        seconds = octal(header, 136, 12)
        typeflag = header[156].chr
        prefix = cstring(header, 345, 155)

        name = prefix.empty? ? name : "#{prefix}/#{name}"

        mtime = mtime_from(seconds)

        entry = Entry.new(name, typeflag, size, mode, mtime, @io)
        # PAX/GNU extension members are consumed and skipped (P0).
        unless entry.file? || entry.dir?
          entry.skip
          return next_entry
        end
        entry
      end

      private def mtime_from(seconds : Int64) : Time?
        return nil if seconds == 0
        Time.unix(seconds)
      rescue ArgumentError
        nil
      end

      private def cstring(buf : Bytes, offset : Int32, width : Int32) : String
        len = width
        width.times do |i|
          if buf[offset + i] == 0
            len = i
            break
          end
        end
        String.new(buf[offset, len])
      end

      private def octal(buf : Bytes, offset : Int32, width : Int32) : Int64
        s = String.build do |io|
          width.times do |i|
            b = buf[offset + i]
            break if b == 0
            io << b.chr unless b == 32 # space
          end
        end
        s.to_i64?(8) || 0_i64
      end
    end
  end
end

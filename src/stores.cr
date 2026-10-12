# Backup stores — the narrow port of this shard (module interface,
# `include` instead of inheritance, per the repo's contract standard).
# A store owns finished archives: save/list/fetch/delete. P0 ships
# LocalStore (a directory) and MemoryStore (tests / in-process use);
# S3 and friends are P1 implementations of the same port.

module ActiveBackup
  module Store
    # One stored backup archive.
    struct Entry
      getter name : String
      getter size : Int64
      getter created_at : Time?

      def initialize(@name : String, @size : Int64, @created_at : Time? = nil)
      end
    end

    # Saves the archive file at `path` under `name` (the store may move
    # or copy it) and returns the resulting entry.
    abstract def save(name : String, path : String) : Entry

    # All stored backups, oldest first.
    abstract def list : Array(Entry)

    # Materializes the archive as a local file and returns its path
    # (LocalStore: the archive itself; remote stores: a temp download).
    abstract def fetch_path(name : String) : String

    abstract def delete(name : String) : Nil

    abstract def exists?(name : String) : Bool
  end

  class LocalStore
    include Store

    SUFFIX = ".tar.gz"

    def initialize(@dir : String)
      Dir.mkdir_p(@dir)
    end

    def dir : String
      @dir
    end

    def save(name : String, path : String) : Entry
      target = File.join(@dir, name)
      File.rename(path, target)
      Entry.new(name, File.size(target), timestamp_of(name, target))
    end

    def list : Array(Store::Entry)
      Dir.glob(File.join(@dir, "*#{SUFFIX}")).map do |path|
        name = File.basename(path)
        Entry.new(name, File.size(path), timestamp_of(name, path))
      end.sort_by { |e| e.created_at || Time.unix(0) }
    end

    def fetch_path(name : String) : String
      path = File.join(@dir, name)
      raise FileNotFoundError.new(name) unless File.exists?(path)
      path
    end

    def delete(name : String) : Nil
      path = File.join(@dir, name)
      File.delete(path) if File.exists?(path)
    end

    def exists?(name : String) : Bool
      File.exists?(File.join(@dir, name))
    end

    private def timestamp_of(name : String, path : String) : Time?
      if m = name.match(/^backup-(\d{8}T\d{6}Z)/)
        Time.parse_utc(m[1], "%Y%m%dT%H%M%S")
      else
        File.info(path).modification_time
      end
    end
  end

  class FileNotFoundError < Exception
    def initialize(name : String)
      super("no backup named #{name} in store")
    end
  end

  class MemoryStore
    include Store

    @blobs = {} of String => Bytes

    def save(name : String, path : String) : Entry
      @blobs[name] = File.read(path).to_slice
      File.delete(path)
      Entry.new(name, @blobs[name].size.to_i64, Time.utc)
    end

    def list : Array(Store::Entry)
      @blobs.map { |name, bytes| Entry.new(name, bytes.size.to_i64, Time.utc) }
        .sort_by(&.created_at.not_nil!)
    end

    def fetch_path(name : String) : String
      bytes = @blobs[name]? || raise FileNotFoundError.new(name)
      path = File.join(ENV.fetch("TMPDIR", "/tmp"),
                       "active_backup_mem-#{name}")
      File.write(path, bytes)
      path
    end

    def delete(name : String) : Nil
      @blobs.delete(name)
    end

    def exists?(name : String) : Bool
      @blobs.has_key?(name)
    end

    def bytes(name : String) : Bytes
      @blobs[name]? || raise FileNotFoundError.new(name)
    end
  end
end

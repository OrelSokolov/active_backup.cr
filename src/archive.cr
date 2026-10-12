# Backup archive: the on-disk format. One backup = one .tar.gz:
#
#   db.dump                 pg_dump custom-format dump (optional)
#   files/<name>/...        file trees (optional, one prefix per path)
#   manifest.json           always LAST — written once every member's
#                           size and sha256 are known; a truncated
#                           archive therefore never parses
#
# manifest.json:
#   {"format":"crails-active-backup","version":1,"app":...,
#    "created_at":...,"database":...,
#    "roots":{"storage":"/abs/path"},           # files/<name> → source dir
#    "members":{"db.dump":{"kind":"pg_dump-custom","size":N,"sha256":...},
#               "files/storage/a.png":{"kind":"file","size":N,"sha256":...}}}

require "json"
require "compress/gzip"
require "digest"
require "./tar"
require "./pg"

module ActiveBackup
  FORMAT = "crails-active-backup"
  FORMAT_VERSION = 1

  class CorruptBackupError < Exception
  end

  module Archive
    MANIFEST_MEMBER = "manifest.json"
    DB_MEMBER = "db.dump"
    FILES_PREFIX = "files/"

    def self.sha256_file(path : String) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buf = Bytes.new(1 << 16)
        while (n = file.read(buf)) > 0
          digest.update(buf[0, n])
        end
      end
      digest.hexfinal
    end

    # Writes a backup archive to `path`.
    # dirs: pairs of {archive name, source directory}.
    def self.write(path : String, *, database_url : String?,
                   dirs : Array(Tuple(String, String)) = [] of Tuple(String, String),
                   app : String? = nil, now : Time = Time.utc) : Nil
      members = {} of String => Hash(String, JSON::Any)
      roots = {} of String => JSON::Any
      db_tmp : String? = nil

      File.open(path, "w") do |file|
        gz = Compress::Gzip::Writer.new(file)
        writer = Tar::Writer.new(gz)

        if database_url
          db_tmp = temp_path("active_backup_db")
          Pg.dump(database_url, db_tmp)
          size = File.size(db_tmp)
          sha = sha256_file(db_tmp)
          File.open(db_tmp) do |src|
            writer.add_file(DB_MEMBER, size.to_i64) { |io| copy(src, io) }
          end
          members[DB_MEMBER] = {
            "kind" => JSON::Any.new("pg_dump-custom"),
            "size" => JSON::Any.new(size.to_i64),
            "sha256" => JSON::Any.new(sha),
          }
        end

        dirs.each do |name, root|
          next unless File.directory?(root)
          roots[name] = JSON::Any.new(File.expand_path(root))
          writer.add_dir("#{FILES_PREFIX}#{name}")
          walk(root) do |abs, rel, info|
            member = "#{FILES_PREFIX}#{name}/#{rel}"
            if info.directory?
              writer.add_dir(member, info.modification_time)
            else
              size = info.size
              digest = Digest::SHA256.new
              writer.add_file(member, size) do |io|
                copy_with_digest(abs, io, digest)
              end
              members[member] = {
                "kind" => JSON::Any.new("file"),
                "size" => JSON::Any.new(size.to_i64),
                "sha256" => JSON::Any.new(digest.hexfinal),
              }
            end
          end
        end

        manifest = String.build do |io|
          JSON.build(io, indent: 2) do |json|
            json.object do
              json.field "format", FORMAT
              json.field "version", FORMAT_VERSION
              json.field "app", app
              json.field "created_at", now.to_utc.to_rfc3339
              json.field "database", database_url ? Pg::ConnInfo.parse(database_url).database : nil
              json.field "roots", roots
              json.field "members", members
            end
          end
        end
        writer.add_file(MANIFEST_MEMBER, manifest)
        writer.close
        gz.close
      end
    ensure
      if db_tmp && File.exists?(db_tmp)
        File.delete(db_tmp)
      end
    end

    # Restores a backup: verifies member checksums, restores file trees
    # and the database. `roots` overrides manifest destinations
    # ({"storage" => "/new/loc"}); `clean: true` drops objects before
    # recreating them (pg_restore --clean). Returns the manifest.
    def self.restore(path : String, *, database_url : String? = nil,
                     roots : Hash(String, String) = {} of String => String,
                     clean : Bool = false,
                     verify : Bool = true) : JSON::Any
      tmp = temp_path("active_backup_restore")
      Dir.mkdir_p(tmp)
      manifest : JSON::Any? = nil

      Compress::Gzip::Reader.open(path) do |gz|
        Tar::Reader.new(gz).each do |entry|
          case entry.name
          when MANIFEST_MEMBER
            manifest = JSON.parse(String.new(entry.content))
          when DB_MEMBER
            File.open(File.join(tmp, DB_MEMBER), "w") { |f| entry.copy_to(f) }
          when .starts_with?(FILES_PREFIX)
            dest = File.join(tmp, entry.name)
            if entry.dir?
              Dir.mkdir_p(dest)
            else
              Dir.mkdir_p(File.dirname(dest))
              File.open(dest, "w") { |f| entry.copy_to(f) }
            end
          end
        end
      end

      raise CorruptBackupError.new("no manifest in #{path}") unless manifest

      if verify
        manifest.not_nil!["members"].as_h.each do |member, info|
          file = File.join(tmp, member)
          unless File.exists?(file)
            raise CorruptBackupError.new("missing member #{member}")
          end
          if sha256_file(file) != info["sha256"].as_s
            raise CorruptBackupError.new("checksum mismatch for #{member}")
          end
        end
      end

      # file trees
      manifest.not_nil!["roots"].as_h.each do |name, root_json|
        src = File.join(tmp, FILES_PREFIX, name)
        next unless File.directory?(src)
        dest = roots[name]? || root_json.as_s
        Dir.mkdir_p(dest)
        copy_tree(src, dest)
      end

      # database
      db_file = File.join(tmp, DB_MEMBER)
      if database_url && File.exists?(db_file)
        Pg.restore(database_url, db_file, clean: clean)
      end

      manifest.not_nil!
    ensure
      rm_tree(tmp) if tmp && File.exists?(tmp)
    end

    def self.read_manifest(path : String) : JSON::Any
      Compress::Gzip::Reader.open(path) do |gz|
        Tar::Reader.new(gz).each do |entry|
          return JSON.parse(String.new(entry.content)) if entry.name == MANIFEST_MEMBER
        end
      end
      raise CorruptBackupError.new("no manifest in #{path}")
    end

    # --- internals ---------------------------------------------------------

    # Copies a file into the archive member io while hashing. Kept as
    # a separate method: nesting this File.open block inside the
    # add_file block trips a Crystal 1.21 codegen bug (nested block
    # inlining) at the call site.
    def self.copy_with_digest(abs : String, io : IO, digest : Digest) : Nil
      File.open(abs) do |src|
        buf = Bytes.new(1 << 16)
        while (n = src.read(buf)) > 0
          digest.update(buf[0, n])
          io.write(buf[0, n])
        end
      end
    end

    private def self.copy(src : IO, dst : IO) : Nil
      buf = Bytes.new(1 << 16)
      while (n = src.read(buf)) > 0
        dst.write(buf[0, n])
      end
    end

    private def self.copy_tree(src : String, dest : String) : Nil
      Dir.children(src).sort.each do |child|
        s = File.join(src, child)
        d = File.join(dest, child)
        if File.directory?(s)
          Dir.mkdir_p(d)
          copy_tree(s, d)
        else
          File.copy(s, d)
        end
      end
    end

    # Iterative, sorted walk (deterministic member order; recursive
    # blocks cannot yield in Crystal, so a worklist is used instead).
    private def self.walk(root : String, & : String, String, File::Info ->) : Nil
      pending = Deque(Tuple(String, String)).new
      pending << {root, ""}
      while item = pending.shift?
        dir, prefix = item
        children = Dir.children(dir).sort
        children.each do |child|
          abs = File.join(dir, child)
          rel = prefix.empty? ? child : "#{prefix}/#{child}"
          info = File.info(abs)
          yield abs, rel, info
          pending << {abs, rel} if info.directory?
        end
      end
    end

    private def self.temp_path(prefix : String) : String
      File.join(ENV.fetch("TMPDIR", "/tmp"),
                "#{prefix}-#{UUID.random.to_s[0, 12]}")
    end

    private def self.rm_tree(path : String) : Nil
      return unless File.exists?(path)
      if File.directory?(path)
        Dir.children(path).each { |c| rm_tree(File.join(path, c)) }
        Dir.delete(path)
      else
        File.delete(path)
      end
    end
  end
end

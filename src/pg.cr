# PostgreSQL dump/restore through the real pg_dump/pg_restore binaries
# — the wire-compatibility point of this shard: a backup is a genuine
# pg_dump custom-format archive restorable by stock tooling. The
# database URL may carry connection params in the query string
# (crystal-pg style, e.g. `?host=/var/run/postgresql`), which are
# translated into PG* environment variables for the child process.
#
# Binary resolution: on multi-version installs (Debian's
# postgresql-common), the `pg_dump`/`pg_restore` shims may route to a
# client newer than the server — a PG17 pg_restore against a PG16
# server dies on `SET transaction_timeout`. When the server major is
# known, the matching client from /usr/lib/postgresql/<major>/bin is
# preferred; otherwise plain PATH lookup is used.

module ActiveBackup
  class PgToolError < Exception
  end

  module Pg
    struct ConnInfo
      property host : String?
      property port : Int32?
      property user : String?
      property password : String?
      property database : String

      def self.parse(url : String) : ConnInfo
        uri = URI.parse(url)
        info = new(uri.path.to_s.lstrip('/'))
        info.user = uri.user
        info.password = uri.password
        info.host = uri.host.presence
        info.port = uri.port
        # crystal-pg puts libpq params (host/port/...) in the query
        query = HTTP::Params.parse(uri.query || "")
        info.host = query["host"]? if info.host.nil? || info.host.try(&.empty?)
        info.port = query["port"]?.try(&.to_i?) unless info.port
        info
      end

      def initialize(@database : String)
      end

      def env : Hash(String, String)
        e = {} of String => String
        if h = host
          e["PGHOST"] = h unless h.empty?
        end
        e["PGPORT"] = port.to_s if port
        if u = user
          e["PGUSER"] = u
        end
        if p = password
          e["PGPASSWORD"] = p
        end
        e
      end
    end

    @@server_major : String?

    def self.dump_available? : Bool
      tool_ok?(resolve_bin("pg_dump")) && tool_ok?(resolve_bin("pg_restore"))
    end

    # pg_dump -Fc → path. Raises PgToolError on a non-zero exit.
    def self.dump(database_url : String, path : String) : Nil
      info = ConnInfo.parse(database_url)
      err = IO::Memory.new
      status = Process.run(resolve_bin("pg_dump", info), [
        "--format=custom",
        "--no-owner",
        "--no-privileges",
        "--file=#{path}",
        info.database,
      ], env: merge_env(info),
         output: Process::Redirect::Inherit, error: err)
      unless status.success?
        raise PgToolError.new(
          "pg_dump failed (#{status.exit_code}): #{err.to_s}")
      end
    end

    # pg_restore from a custom-format dump at `path` into database_url.
    # `clean: true` adds --clean --if-exists (drop-then-create objects,
    # for restoring over a live database).
    def self.restore(database_url : String, path : String,
                     clean : Bool = false) : Nil
      info = ConnInfo.parse(database_url)
      args = ["--no-owner", "--no-privileges", "--dbname=#{info.database}"]
      args.concat(["--clean", "--if-exists"]) if clean
      args << path
      err = IO::Memory.new
      status = Process.run(resolve_bin("pg_restore", info), args,
        env: merge_env(info),
        output: Process::Redirect::Inherit, error: err)
      # --clean against a fresh database emits harmless "does not exist"
      # notices; pg_restore still reports success. Only real failures
      # (non-zero exit) raise.
      unless status.success?
        raise PgToolError.new(
          "pg_restore failed (#{status.exit_code}): #{err.to_s}")
      end
    end

    # --- binary resolution -------------------------------------------------

    # Prefers /usr/lib/postgresql/<server-major>/bin/<name> when the
    # server major could be detected via psql; falls back to PATH.
    private def self.resolve_bin(name : String,
                                 info : ConnInfo? = nil) : String
      if info
        if major = server_major(info)
          pinned = "/usr/lib/postgresql/#{major}/bin/#{name}"
          return pinned if File.exists?(pinned)
        end
      elsif major = @@server_major
        pinned = "/usr/lib/postgresql/#{major}/bin/#{name}"
        return pinned if File.exists?(pinned)
      end
      name
    end

    # `SHOW server_version_num` through psql, memoized (one psql run
    # per process). Returns e.g. "16" or nil when undetectable.
    private def self.server_major(info : ConnInfo) : String?
      @@server_major ||= begin
        stdout = IO::Memory.new
        status = Process.run("psql",
          ["--dbname=postgres", "-At", "-c", "SHOW server_version_num"],
          env: merge_env(info), output: stdout, error: :close)
        if status.success? && (num = stdout.to_s.strip.to_i?)
          (num // 10000).to_s
        end
      rescue
        nil
      end
    end

    private def self.tool_ok?(bin : String) : Bool
      status = Process.run(bin, ["--version"], output: :close, error: :close)
      status.success?
    rescue
      false
    end

    private def self.merge_env(info : ConnInfo) : Hash(String, String)
      ENV.to_h.merge!(info.env)
    end
  end
end

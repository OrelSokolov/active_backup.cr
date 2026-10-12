# ActiveBackup facade — configuration + the three operations
# (create / restore / prune). Everything is explicit: the database URL
# comes from config or ENV["DATABASE_URL"], file trees from
# config.paths, archives live in config.store.

require "uuid"
require "./stores"
require "./retention"
require "./archive"

module ActiveBackup
  class NotConfiguredError < Exception
  end

  class Config
    # Where finished archives live (LocalStore, S3-store, ...).
    property store : Store? = nil

    # Retention applied after every create and by prune.
    property retention : RetentionPolicy = RetentionPolicy.new

    # PostgreSQL URL; falls back to ENV["DATABASE_URL"].
    property database_url : String? = nil

    # Directories to back up (each becomes a files/<basename>/ tree).
    property paths : Array(String) = [] of String

    # Recorded in the manifest (informational).
    property app : String? = nil
  end

  class_property config : Config { Config.new }

  def self.configure(&) : Nil
    yield config
  end

  def self.store : Store
    config.store || raise NotConfiguredError.new(
      "ActiveBackup.store is not set (ActiveBackup.configure { |c| c.store = ... })")
  end

  def self.resolve_database_url : String?
    config.database_url || ENV["DATABASE_URL"]?
  end

  # Default archive name: backup-<UTC stamp>.tar.gz. Two backups within
  # the same second get a random suffix to avoid clobbering.
  def self.generate_name(now : Time = Time.utc) : String
    base = "backup-#{now.to_utc.to_s("%Y%m%dT%H%M%SZ")}"
    name = "#{base}.tar.gz"
    store_exists = config.store.try(&.exists?(name))
    store_exists ? "#{base}-#{UUID.random.to_s[0, 8]}.tar.gz" : name
  end

  # Creates a backup and returns the store entry.
  def self.create(*, name : String? = nil, now : Time = Time.utc) : Store::Entry
    name ||= generate_name(now)
    dirs = config.paths.map { |p| {File.basename(p), File.expand_path(p)} }
    tmp = File.join(ENV.fetch("TMPDIR", "/tmp"),
                    "active_backup-#{UUID.random.to_s[0, 12]}.tar.gz")
    ActiveSupport::Notifications.instrument("create.active_backup",
      ({"name" => name} of String => ActiveSupport::Any)) do
      Archive.write(tmp, database_url: resolve_database_url,
                    dirs: dirs, app: config.app, now: now)
    end
    entry = store.save(name, tmp)
    prune unless config.retention.disabled?
    entry
  ensure
    File.delete(tmp) if tmp && File.exists?(tmp)
  end

  # Restores a backup by name (default: the newest). `database_url` /
  # `roots` override the manifest; `clean: true` drops objects before
  # recreating them. Returns the manifest.
  def self.restore(name : String? = nil, *, database_url : String? = nil,
                   roots : Hash(String, String) = {} of String => String,
                   clean : Bool = false,
                   verify : Bool = true) : JSON::Any
    name ||= latest_name || raise FileNotFoundError.new("(none)")
    path = store.fetch_path(name)
    ActiveSupport::Notifications.instrument("restore.active_backup",
      ({"name" => name} of String => ActiveSupport::Any)) do
      Archive.restore(path, database_url: database_url || resolve_database_url,
                       roots: roots, clean: clean, verify: verify)
    end
  end

  # Applies the retention policy; returns the deleted names.
  def self.prune(now : Time = Time.utc) : Array(String)
    deleted = config.retention.apply(store.list, now)
    deleted.each { |n| store.delete(n) }
    deleted
  end

  def self.latest_name : String?
    list = store.list
    list.last?.try(&.name)
  end
end

# The CI restore test — the whole point of the shard: a backup must
# survive a real disaster. Flow (all against local PostgreSQL and the
# system GNU tar; skipped when either is unavailable):
#
#   1. seed a database (two tables, binary + unicode data) and a file
#      tree (nested dirs, binary files, unicode names)
#   2. ActiveBackup.create → one .tar.gz in a LocalStore
#   3. system tar reads the archive (format oracle: real tool must
#      list our members)
#   4. DESTROY: drop the database, wipe the files
#   5. ActiveBackup.restore (pg_restore does the database, checksums
#      verified first)
#   6. assert the database and the files are byte-identical to what
#      was seeded

require "spec"
require "uuid"
require "../src/active_backup_cr"

include ActiveBackup

PG_ADMIN = begin
  admin = DB.open(ENV.fetch("ACTIVE_BACKUP_ADMIN_URL", "postgres:///postgres"))
  admin.exec("SELECT 1")
  admin
rescue ex
  nil
end

SPEC_DB = "crails_active_backup_test"
SPEC_URL = "postgres:///#{SPEC_DB}?host=/var/run/postgresql"

TOOLS_OK = Pg.dump_available?
RESTORE_TAR = begin
  Process.run("tar", ["--version"], output: :close).success?
rescue
  false
end

RESTORE_READY = !PG_ADMIN.nil? && TOOLS_OK && RESTORE_TAR

def rm_full(path : String) : Nil
  return unless File.exists?(path)
  if File.directory?(path)
    Dir.children(path).each { |c| rm_full(File.join(path, c)) }
    Dir.delete(path)
  else
    File.delete(path)
  end
end

def recreate_db : Nil
  admin = PG_ADMIN.not_nil!
  admin.exec("DROP DATABASE IF EXISTS #{SPEC_DB}")
  admin.exec("CREATE DATABASE #{SPEC_DB}")
end

def seed_db : Hash(String, Array(String))
  db = DB.open(SPEC_URL)
  db.exec("CREATE TABLE users (id bigserial PRIMARY KEY,
           email text NOT NULL, bio bytea, created_at timestamptz)")
  db.exec("CREATE TABLE notes (id bigserial PRIMARY KEY,
           user_id bigint REFERENCES users(id), body text, tags text[])")
  users = [] of String
  10.times do |i|
    bio = Random::Secure.random_bytes(16 + i)
    db.exec("INSERT INTO users (email, bio, created_at) VALUES ($1, $2, $3)",
      "user-#{i}@пример.рф", bio, Time.utc(2026, 10, 1, 12, 0, 0) + i.minutes)
    users << "user-#{i}@пример.рф"
  end
  notes = [] of String
  25.times do |i|
    body = "заметка №#{i} — " + ("x" * (i % 7))
    db.exec("INSERT INTO notes (user_id, body, tags) VALUES ($1, $2, $3)",
      (i % 10) + 1, body, %w[alpha beta] + ["тег-#{i}"])
    notes << body
  end
  db.close
  {"users" => users, "notes" => notes}
end

def db_state : Hash(String, Array(Array(String)))
  queries = {
    "users" => "SELECT id::text, email, encode(bio, 'hex'), created_at::text " \
               "FROM users ORDER BY id",
    "notes" => "SELECT id::text, user_id::text, body, tags::text " \
               "FROM notes ORDER BY id",
  }
  db = DB.open(SPEC_URL)
  state = {} of String => Array(Array(String))
  queries.each do |table, sql|
    rows = [] of Array(String)
    db.query(sql) do |rs|
      rs.each do
        row = [] of String
        rs.column_count.times { row << rs.read(String) }
        rows << row
      end
    end
    state[table] = rows
  end
  db.close
  state
end

def seed_files(root : String) : Nil
  Dir.mkdir_p(File.join(root, "ab/cd"))
  File.write(File.join(root, "hello.txt"), "file content\n")
  File.write(File.join(root, "бинарь-данные.bin"),
    Random::Secure.random_bytes(4096))
  File.write(File.join(root, "ab/cd/deep.png"),
    Random::Secure.random_bytes(65536))
end

def files_state(root : String) : Hash(String, String)
  state = {} of String => String
  Dir.glob(File.join(root, "**/*")).sort.each do |path|
    next if File.directory?(path)
    digest = Digest::SHA256.new
    File.open(path) do |file|
      buf = Bytes.new(1 << 16)
      while (n = file.read(buf)) > 0
        digest.update(buf[0, n])
      end
    end
    state[path] = digest.hexfinal
  end
  state
end

describe "backup → destroy → restore (CI)" do
  next unless RESTORE_READY

  workdir = File.join(ENV.fetch("TMPDIR", "/tmp"),
                      "ab_restore-#{UUID.random.to_s[0, 8]}")
  backups = File.join(workdir, "backups")
  storage = File.join(workdir, "storage")

  it "round-trips database and files through a real disaster" do
    # 1. seed
    recreate_db
    seed = seed_db
    Dir.mkdir_p(storage)
    seed_files(storage)
    files_before = files_state(storage)
    db_before = db_state

    ActiveBackup.configure do |c|
      c.store = LocalStore.new(backups)
      c.database_url = SPEC_URL
      c.paths = [storage]
      c.app = "restore_spec"
      c.retention = RetentionPolicy.new # disabled: keep everything
    end

    # 2. backup
    entry = ActiveBackup.create(name: "backup-20260101T000000Z.tar.gz")
    entry.name.should eq "backup-20260101T000000Z.tar.gz"
    entry.size.should be > 0

    # 3. system tar lists the archive members (format oracle)
    listing = IO::Memory.new
    Process.run("tar", ["-tzf", File.join(backups, entry.name)],
      output: listing).success?.should be_true
    members = listing.to_s.split('\n', remove_empty: true)
    members.should contain "manifest.json"
    members.should contain "db.dump"
    members.select(&.starts_with?("files/storage/")).sort.should eq [
      "files/storage/", "files/storage/ab/", "files/storage/ab/cd/",
      "files/storage/ab/cd/deep.png", "files/storage/бинарь-данные.bin",
      "files/storage/hello.txt",
    ].sort

    manifest = Archive.read_manifest(File.join(backups, entry.name))
    manifest["format"].as_s.should eq "crails-active-backup"
    manifest["version"].as_i.should eq 1
    manifest["app"].as_s.should eq "restore_spec"
    manifest["database"].as_s.should eq SPEC_DB
    manifest["members"].as_h.has_key?("db.dump").should be_true
    manifest["members"].as_h["db.dump"]["sha256"].as_s.size.should eq 64

    # 4. destroy everything
    PG_ADMIN.not_nil!.exec("DROP DATABASE #{SPEC_DB}")
    PG_ADMIN.not_nil!.exec("CREATE DATABASE #{SPEC_DB}")
    rm_full(storage)

    # 5. restore (into the same empty database and path)
    ActiveBackup.restore("backup-20260101T000000Z.tar.gz")

    # 6. verify
    db_state.should eq db_before
    files_state(storage).should eq files_before

    # restore is idempotent over the restored state with clean: true
    ActiveBackup.restore("backup-20260101T000000Z.tar.gz", clean: true)
    db_state.should eq db_before
  ensure
    rm_full(workdir)
    begin
      PG_ADMIN.not_nil!.exec("DROP DATABASE IF EXISTS #{SPEC_DB}")
    rescue
    end
  end

  it "detects corruption via member checksums" do
    recreate_db
    seed_db
    Dir.mkdir_p(storage)
    seed_files(storage)
    rm_full(storage) # not part of this case
    ActiveBackup.configure do |c|
      c.store = LocalStore.new(backups)
      c.database_url = SPEC_URL
      c.paths = [] of String
      c.retention = RetentionPolicy.new
    end
    ActiveBackup.create(name: "corrupt-me.tar.gz")

    # flip one byte inside the db.dump member
    path = File.join(backups, "corrupt-me.tar.gz")
    raw = File.read(path).to_slice.dup
    i = raw.size // 2
    raw[i] = (raw[i] ^ 0xFF).to_u8!
    File.write(path, raw)

    expect_raises(Exception) { ActiveBackup.restore("corrupt-me.tar.gz") }
  ensure
    rm_full(workdir)
    begin
      PG_ADMIN.not_nil!.exec("DROP DATABASE IF EXISTS #{SPEC_DB}")
    rescue
    end
  end
end

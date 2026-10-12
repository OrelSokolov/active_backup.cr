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
SYSTEM_TAR = begin
  Process.run("tar", ["--version"], output: :close).success?
rescue
  false
end

RESTORE_READY = !PG_ADMIN.nil? && TOOLS_OK && SYSTEM_TAR

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

describe "s" do
  workdir = "/tmp/s1"
  backups = File.join(workdir, "backups")
  storage = File.join(workdir, "storage")
  it "t" do
    recreate_db
    seed_db
    Dir.mkdir_p(storage)
    seed_files(storage)
    rm_full(storage) # not part of this case
    ActiveBackup.configure do |c|
  end
end

# Store port implementations + retention policy specs.

require "spec"
require "uuid"
require "../src/stores"
require "../src/retention"

include ActiveBackup

def write_archive(dir : String, name : String, size : Int32 = 32) : String
  path = File.join(dir, name)
  File.write(path, Random::Secure.random_bytes(size))
  path
end

def rm_tree(path : String) : Nil
  return unless File.exists?(path)
  if File.directory?(path)
    Dir.children(path).each { |c| rm_tree(File.join(path, c)) }
    Dir.delete(path)
  else
    File.delete(path)
  end
end

def ret_entry(name : String, time : Time) : Store::Entry
  Store::Entry.new(name, 10_i64, time)
end

describe LocalStore do
  it "saves, lists, fetches and deletes archives" do
    dir = File.join(ENV.fetch("TMPDIR", "/tmp"), "ab_store-#{UUID.random.to_s[0, 8]}")
    store = LocalStore.new(dir)
    File.directory?(dir).should be_true

    a = write_archive(dir, "src-a.tar.gz")
    b = write_archive(dir, "src-b.tar.gz")
    e1 = store.save("backup-20260101T000000Z.tar.gz", a)
    e2 = store.save("backup-20260102T000000Z.tar.gz", b)

    e1.name.should eq "backup-20260101T000000Z.tar.gz"
    e1.created_at.should eq Time.utc(2026, 1, 1)
    e2.created_at.should eq Time.utc(2026, 1, 2)

    store.list.map(&.name).should eq [
      "backup-20260101T000000Z.tar.gz", "backup-20260102T000000Z.tar.gz"]
    store.exists?("backup-20260101T000000Z.tar.gz").should be_true
    File.exists?(a).should be_false # save moves the file

    store.fetch_path("backup-20260101T000000Z.tar.gz")
      .should eq File.join(dir, "backup-20260101T000000Z.tar.gz")
    expect_raises(FileNotFoundError) { store.fetch_path("nope.tar.gz") }

    store.delete("backup-20260101T000000Z.tar.gz")
    store.exists?("backup-20260101T000000Z.tar.gz").should be_false
  ensure
    rm_tree(dir) if dir
  end

  it "falls back to file mtime for non-standard names" do
    dir = File.join(ENV.fetch("TMPDIR", "/tmp"), "ab_store-#{UUID.random.to_s[0, 8]}")
    store = LocalStore.new(dir)
    store.save("manual-copy.tar.gz", write_archive(dir, "tmp-manual.tar.gz"))
    store.list.first.created_at.not_nil!.should be_close(Time.utc, 5.seconds)
  ensure
    rm_tree(dir) if dir
  end
end

describe MemoryStore do
  it "round-trips archives in memory" do
    dir = File.join(ENV.fetch("TMPDIR", "/tmp"), "ab_mem-#{UUID.random.to_s[0, 8]}")
    Dir.mkdir_p(dir)
    store = MemoryStore.new
    data = Random::Secure.random_bytes(100)
    File.write(File.join(dir, "tmp.tar.gz"), data)
    store.save("backup-20260103T030000Z.tar.gz", File.join(dir, "tmp.tar.gz"))

    store.list.size.should eq 1
    store.bytes("backup-20260103T030000Z.tar.gz").should eq data
    File.exists?(File.join(dir, "tmp.tar.gz")).should be_false

    fetched = store.fetch_path("backup-20260103T030000Z.tar.gz")
    File.read(fetched).to_slice.should eq data
    store.delete("backup-20260103T030000Z.tar.gz")
    store.list.size.should eq 0
  ensure
    rm_tree(dir) if dir
  end
end

describe RetentionPolicy do
  now = Time.utc(2026, 10, 6, 18, 0, 0)


  it "keeps everything when disabled" do
    entries = [
      ret_entry("a", now - 30.days),
      ret_entry("b", now - 2.days),
      ret_entry("c", now),
    ]
    RetentionPolicy.new.apply(entries, now).should be_empty
  end

  it "always keeps the newest backup" do
    entries = (1..20).map { |i| ret_entry("b#{i}", now - i.days) }
    RetentionPolicy.new(keep_days: 1).apply(entries, now).should eq(
      (2..20).map { |i| "b#{i}" }) # b1 is both newest and Oct-5 day-best
  end

  it "keep_last retains the N most recent" do
    entries = (1..5).map { |i| ret_entry("b#{i}", now - i.days) }
    RetentionPolicy.new(keep_last: 2).apply(entries, now)
      .should eq ["b3", "b4", "b5"]
  end

  it "keep_days retains the newest backup per UTC day" do
    entries = [
      ret_entry("mon-1", Time.utc(2026, 10, 5, 8, 0)),
      ret_entry("mon-2", Time.utc(2026, 10, 5, 20, 0)),
      ret_entry("tue-1", Time.utc(2026, 10, 6, 6, 0)),
      ret_entry("tue-2", now), # newest overall
      ret_entry("old", Time.utc(2026, 9, 20, 6, 0)),
    ]
    RetentionPolicy.new(keep_days: 2).apply(entries, now)
      .should eq(["mon-1", "tue-1", "old"])
    # keep set: tue-2 (newest + Oct-6 day-best) and mon-2 (Oct-5 day-best)
  end

  it "never deletes entries without a timestamp" do
    entries = [
      Store::Entry.new("unknown", 10_i64, nil),
      ret_entry("b1", now),
    ]
    RetentionPolicy.new(keep_last: 1).apply(entries, now).should be_empty
  end
end

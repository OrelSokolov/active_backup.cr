# ustar writer/reader unit spec + two-way compatibility with the
# system GNU tar (the wire-format oracle for this shard: our archives
# must be readable by real `tar`, and real `tar` archives by us).

require "spec"
require "digest"
require "uuid"
require "random"
require "../src/tar"

include ActiveBackup

def build_tar(& : Tar::Writer ->) : Bytes
  io = IO::Memory.new
  writer = Tar::Writer.new(io)
  yield writer
  writer.close
  io.to_slice
end

# Entries are streaming (valid only inside `each`): materialize what
# the tests need during iteration.
struct MaterializedEntry
  property content : Bytes = Bytes.new(0)
  getter name : String
  getter typeflag : Char
  getter mode : Int32
  getter size : Int64

  def initialize(@name, @typeflag, @mode, @size)
  end

  def dir? : Bool
    @typeflag == '5'
  end
end

def tar_entries(data : Bytes) : Hash(String, MaterializedEntry)
  entries = {} of String => MaterializedEntry
  Tar::Reader.new(IO::Memory.new(data)).each do |e|
    me = MaterializedEntry.new(e.name, e.typeflag, e.mode, e.size)
    me.content = e.content unless e.dir?
    entries[e.name] = me
  end
  entries
end

def sha256_file(path : String) : String
  digest = Digest::SHA256.new
  File.open(path) do |file|
    buf = Bytes.new(8192)
    while (n = file.read(buf)) > 0
      digest.update(buf[0, n])
    end
  end
  digest.hexfinal
end

SYSTEM_TAR = begin
  status = Process.run("tar", ["--version"], output: :close)
  status.success?
rescue
  false
end

# Minimal tempdir helper (File.tempdir is not in this stdlib version).
def spec_tmpdir(prefix : String) : String
  dir = File.join(ENV.fetch("TMPDIR", "/tmp"),
                  "#{prefix}-#{UUID.random.to_s[0, 8]}")
  Dir.mkdir_p(dir)
  dir
end

def rm_r(path : String) : Nil
  return unless File.exists?(path)
  if File.directory?(path)
    Dir.children(path).each { |c| rm_r(File.join(path, c)) }
    Dir.delete(path)
  else
    File.delete(path)
  end
end

describe Tar::Writer do
  it "roundtrips files and dirs through Reader" do
    binary = Bytes.new(1500) { |i| (i % 251).to_u8 }
    data = build_tar do |w|
      w.add_dir("files")
      w.add_file("files/hello.txt", "hello\n")
      w.add_file("files/бинарь.bin", binary)
      w.add_file("files/empty", Bytes.new(0))
    end

    entries = tar_entries(data)
    entries.keys.should contain "files/"
    entries["files/hello.txt"].content.should eq "hello\n".to_slice
    entries["files/бинарь.bin"].content.should eq binary
    entries["files/empty"].content.should eq Bytes.new(0)
    entries["files/hello.txt"].mode.should eq 0o644
    entries["files/"].dir?.should be_true
  end

  it "pads to 512-byte blocks and ends with two zero blocks" do
    data = build_tar do |w|
      w.add_file("a.txt", "abc")
    end
    # header block + one padded data block + two zero end blocks
    data.size.should eq 512 * 4
  end

  it "splits long names into the ustar prefix field" do
    long_dir = "d" * 80
    long_name = "#{long_dir}/" + "f" * 60 + ".txt"
    data = build_tar do |w|
      w.add_file(long_name, "deep")
    end
    entries = tar_entries(data)
    entries[long_name].content.should eq "deep".to_slice
  end

  it "raises on names that cannot fit ustar fields" do
    expect_raises(Tar::HeaderError) do
      build_tar { |w| w.add_file("x" * 300, "data") }
    end
  end

  it "raises when the block writes fewer bytes than announced" do
    expect_raises(Tar::HeaderError) do
      build_tar { |w| w.add_file("a.txt", 10_i64) { |io| io.write("short".to_slice) } }
    end
  end
end

describe "system tar compatibility" do
  next unless SYSTEM_TAR

  it "system tar lists and extracts archives produced by Writer" do
    binary = Bytes.new(1500) { |i| (i % 251).to_u8 }
    dir = spec_tmpdir("tar_spec")
    archive = File.join(dir, "ours.tar")
    File.open(archive, "w") do |file|
      writer = Tar::Writer.new(file)
      writer.add_dir("files")
      writer.add_file("files/hello.txt", "hello\n")
      writer.add_file("files/blob.bin", binary)
      writer.close
    end

    # tar -t must list exactly our members
    listing = IO::Memory.new
    status = Process.run("tar", ["-tf", archive], output: listing)
    status.success?.should be_true
    listing.to_s.split('\n', remove_empty: true).sort.should eq(
      ["files/", "files/blob.bin", "files/hello.txt"])

    # tar -x must restore the exact bytes
    outdir = File.join(dir, "x"); Dir.mkdir_p(outdir)
    status = Process.run("tar", ["-xf", archive, "-C", outdir])
    status.success?.should be_true
    File.read(File.join(outdir, "files/hello.txt")).should eq "hello\n"
    File.read(File.join(outdir, "files/blob.bin")).to_slice.should eq binary
  ensure
    rm_r(dir) if dir
  end

  it "Reader reads archives produced by GNU tar (oracle fixture)" do
    fixture = File.join(__DIR__, "../oracle/fixtures/gnu.tar")
    entries = {} of String => MaterializedEntry
    File.open(fixture) do |file|
      Tar::Reader.new(file).each do |e|
        me = MaterializedEntry.new(e.name, e.typeflag, e.mode, e.size)
        me.content = e.content unless e.dir?
        entries[e.name] = me
      end
    end
    entries["hello.txt"].content.should eq "hello tar\n".to_slice
    entries["sub/"].dir?.should be_true
    entries["sub/deep.txt"].content.should eq "deep file\n".to_slice
    entries["sub/nested.bin"].size.should eq 2048
    sha256_file(File.join(__DIR__, "../oracle/fixtures/gnu_src/sub/nested.bin")).should eq(
      Digest::SHA256.new.update(entries["sub/nested.bin"].content).hexfinal)
  end
end

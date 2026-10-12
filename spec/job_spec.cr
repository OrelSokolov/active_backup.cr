# BackupJob through ActiveJob: enqueue lands in the test adapter, and
# perform_now runs a full backup cycle (create + retention). Uses a
# files-only backup (no PostgreSQL needed) so the job semantics are
# testable anywhere; the database path is covered by restore_spec.

require "spec"
require "uuid"
require "../src/active_backup_cr"

include ActiveBackup

def rm_path(path : String) : Nil
  return unless File.exists?(path)
  if File.directory?(path)
    Dir.children(path).each { |c| rm_path(File.join(path, c)) }
    Dir.delete(path)
  else
    File.delete(path)
  end
end

JOB_OK = begin
  ActiveJob.adapter = ActiveJob::TestAdapter.new
  true
rescue
  false
end

describe ActiveBackup::BackupJob do
  next unless JOB_OK

  it "is enqueued through the adapter and runs the backup cycle" do
    workdir = File.join(ENV.fetch("TMPDIR", "/tmp"),
                        "ab_job-#{UUID.random.to_s[0, 8]}")
    storage = File.join(workdir, "storage")
    backups = File.join(workdir, "backups")
    Dir.mkdir_p(storage)
    File.write(File.join(storage, "a.txt"), "job backup")

    ActiveBackup.configure do |c|
      c.store = LocalStore.new(backups)
      c.database_url = nil
      c.paths = [storage]
      c.app = "job_spec"
      c.retention = RetentionPolicy.new(keep_last: 2)
    end

    adapter = ActiveJob.adapter.as(ActiveJob::TestAdapter)
    adapter.enqueued_jobs.clear

    BackupJob.perform_later
    adapter.enqueued_jobs.size.should eq 1
    adapter.enqueued_jobs.first.job_class.should eq "ActiveBackup::BackupJob"
    ActiveBackup.store.list.size.should eq 0 # not executed yet

    # create some history so retention has something to prune
    ActiveBackup.create(name: "backup-20260101T000000Z.tar.gz",
                        now: Time.utc(2026, 1, 1))
    ActiveBackup.create(name: "backup-20260102T000000Z.tar.gz",
                        now: Time.utc(2026, 1, 2))

    result = BackupJob.new.perform
    result.should eq "ok"

    names = ActiveBackup.store.list.map(&.name)
    # the job created one more archive, retention (keep_last: 2) pruned
    # the oldest, newest backup always kept
    names.size.should eq 2
    names.should_not contain "backup-20260101T000000Z.tar.gz"

    manifest = Archive.read_manifest(File.join(backups, names.last))
    manifest["app"].as_s.should eq "job_spec"
    manifest["members"].as_h.keys.should contain "files/storage/a.txt"
  ensure
    rm_path(workdir) if workdir
  end
end

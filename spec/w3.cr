require "spec"
require "../src/active_backup_cr"
include ActiveBackup

describe "w3" do
  it "t" do
    Archive.write("/tmp/w3.tar.gz", database_url: nil,
                  dirs: [] of Tuple(String, String), app: nil, now: Time.utc)
  end
end

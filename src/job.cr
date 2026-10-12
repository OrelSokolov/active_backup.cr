# ActiveJob bridge: the recurring backup job. Apps register it with
# their scheduler, e.g. a SolidQueue recurring task (cron semantics of
# ActiveJob::Cron):
#
#   # in the app's scheduler setup
#   task = ActiveJob::SolidQueue::RecurringTask.new(
#     "active_backup", "ActiveBackup::BackupJob", "0 4 * * *")
#   adapter.schedule_recurring([task])
#
# perform = one backup cycle: create the archive, apply retention.

module ActiveBackup
  class BackupJob < ActiveJob::Base
    def perform
      ActiveBackup.create
      ActiveBackup.prune
      "ok"
    end
  end
end

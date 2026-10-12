# Retention policy — which backups survive pruning. Deterministic,
# time-derived rules (no randomness), so the spec pins exact outcomes:
#
#   keep_last: n — always keep the n most recent backups.
#   keep_days: d — for each of the last d UTC days (including today),
#                  keep the newest backup taken that day.
#
# The single newest backup is always kept regardless of the rules.
# Entries without a timestamp are never deleted (deleting backups we
# cannot date is the dangerous direction). Both rules default to 0 =
# disabled.

module ActiveBackup
  class RetentionPolicy
    getter keep_last : Int32
    getter keep_days : Int32

    def initialize(@keep_last = 0, @keep_days = 0)
    end

    def disabled? : Bool
      @keep_last <= 0 && @keep_days <= 0
    end

    # Returns the names to delete from `entries` (all backups, any
    # order; entries without created_at are kept and ignored).
    def apply(entries : Array(Store::Entry), now : Time = Time.utc) : Array(String)
      return [] of String if disabled?

      timed = entries.select(&.created_at).sort_by(&.created_at.not_nil!).reverse
      return [] of String if timed.empty?

      keep = Set(String).new
      keep << timed.first.name # newest always survives

      timed.first(@keep_last).each { |e| keep << e.name } if @keep_last > 0

      if @keep_days > 0
        @keep_days.times do |offset|
          day = (now - offset.days)
          y, m, d = {day.year, day.month, day.day}
          day_best = timed.find do |e|
            t = e.created_at.not_nil!
            t.year == y && t.month == m && t.day == d
          end
          keep << day_best.name if day_best
        end
      end

      entries.select(&.created_at).map(&.name)
        .select { |n| !keep.includes?(n) }
    end
  end
end

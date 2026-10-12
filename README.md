# active_backup.cr

Database and file backups for CRails — **an original CRails component,
not a port**: Rails core has no backup facility, so there is no Ruby
original to mirror. One `ActiveBackup.create` produces a single
`.tar.gz` (ustar + gzip) containing a `pg_dump` custom-format database
dump, the backed-up directory trees (e.g. the ActiveStorage disk root)
and a trailing `manifest.json` with sha256 + size of every member.
Restore verifies checksums, copies files back to their roots and runs
`pg_restore`.

The oracle, per the project's rules, is **two-way interoperability
with the real tools**: archives must be listed and unpacked by the
system GNU tar, dumps must restore with the real `pg_restore` — and
conversely our reader parses archives created by GNU tar
(`oracle/fixtures/gnu.tar`). Suite: **18/18**.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  active_backup_cr:
    github: OrelSokolov/active_backup.cr
```

```sh
shards install
```

Depends on `active_support.cr` (Notifications), `active_job.cr`
(BackupJob) and `active_record.cr`. Requires `pg_dump`/`pg_restore`
(server-version-pinned) and GNU tar in the environment.

## Usage

```crystal
ActiveBackup.configure do |c|
  c.store = ActiveBackup::LocalStore.new("backups")
  c.database_url = "postgres:///app_prod?host=/var/run/postgresql"
  c.paths = ["storage"]        # ActiveStorage disk root etc.
  c.retention = ActiveBackup::RetentionPolicy.new(
    keep_last: 14, keep_days: 30)
end

ActiveBackup.create    # → Store::Entry
ActiveBackup.restore   # newest; name:/clean:/roots:/database_url: overrides
ActiveBackup.prune     # → Array(String) of deleted names
```

Recurring backups: `ActiveBackup::BackupJob < ActiveJob::Base`
(perform = create + prune), register it with the app's scheduler
(`ActiveJob::SolidQueue::RecurringTask`). Events
`create.active_backup` / `restore.active_backup` are published to
ActiveSupport::Notifications.

## Feature comparison

There is no original gem to compare against, so the table compares
with the de-facto stack this shard replaces: `pg_dump`/`pg_restore` +
`tar` + cron + hand-rolled retention scripts.

| Feature | Usual stack (pg_dump + tar + cron) | active_backup.cr | Status |
|---|---|---|---|
| Single-archive backup (db dump + file trees + manifest) | assemble by hand | `ActiveBackup.create` → one `.tar.gz` | ✅ |
| Integrity: sha256 + size per member, manifest written last (truncated archive fails to parse) | no | `manifest.json` verified on restore | ✅ |
| GNU tar interop (list/unpack our archives; read GNU tar archives) | n/a | both directions, oracle-tested | ✅ |
| `pg_dump`/`pg_restore` custom format, `clean: true` → `--clean --if-exists` | manual flags | handled | ✅ |
| pg tool version pinning (multiple installed server versions) | manual | auto-resolve `/usr/lib/postgresql/<major>/bin` | ✅ |
| Pluggable stores (`save/list/fetch_path/delete/exists?`) | write your own | `Store` module-interface; Local, Memory (S3 — P1) | ✅ |
| Retention `keep_last` / `keep_days` (newest per UTC day, newest always kept) | script it | `RetentionPolicy` | ✅ |
| Scheduled recurring backups | cron | `BackupJob` + ActiveJob recurring tasks | ✅ |
| Instrumentation | none | `create./restore.active_backup` Notifications | ✅ |
| Byte-exact restore test in CI (seed db + files → backup → drop → restore → compare) | rare | `spec/restore_spec.cr` | ✅ |
| Symlinks / ACLs in backed-up trees | tar does it | not included (P2) | ❌ |
| Incremental backups, encryption | tar/extra tooling | P2 (AES-GCM over MessageEncryptor planned) | ❌ |
| `crails backup:*` CLI commands | — | P1 (call the API from a rake task/job for now) | ❌ |

## Deviations & Crystal-specific notes

- Tar writer is plain ustar: no symlinks, no PAX/GNU long names
  (unknown typeflags are skipped by the reader), names ≤ 255 bytes
  (ustar prefix field).
- Database URL resolution is explicit: `configure` value →
  `ENV["DATABASE_URL"]` — no magic.
- Full details and the pinned-pg-binaries rationale: `PLAN.md`
  (Russian).

## Testing

```sh
crystal spec   # restore spec needs a local PostgreSQL + GNU tar, else skips
```

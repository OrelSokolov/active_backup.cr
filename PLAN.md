# active_backup.cr — бэкапы БД/файлов + restore-тест в CI

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Дифференциатор (Фаза 3, Iteration 14 корневого PLAN.md): не порт гема —
интерфейс с нуля. Оракул по AGENTS.md — двусторонняя совместимость
с настоящими инструментами: архив должен читаться системным GNU tar,
дамп БД — восстанавливаться настоящим pg_restore, и наоборот
(наш Reader читает архивы, созданные GNU tar — фикстура
oracle/fixtures/gnu.tar).

## Что делает

- **Бэкап** = один `.tar.gz` (ustar + gzip):
  `db.dump` (pg_dump custom-format) + `files/<name>/...` (деревья
  каталогов, обычно ActiveStorage disk-root) + `manifest.json`
  (пишется ПОСЛЕДНИМ — обрезанный архив не распарсится; содержит
  sha256+size каждого члена, roots-маппинг, app, created_at).
- **Restore**: распаковка во временный каталог → сверка sha256 всех
  членов с манифестом → файлы копируются в корни из манифеста
  (переопределяются `roots:`) → БД восстанавливается pg_restore
  (`clean: true` = --clean --if-exists).
- **Сторы** — узкий порт `ActiveBackup::Store` (module-interface,
  `include`): `save/list/fetch_path/delete/exists?`. P0: LocalStore
  (каталог), MemoryStore (тесты). S3 — P1 на том же порту.
- **Retention**: `keep_last: n` + `keep_days: d` (новейший бэкап
  каждого из последних d UTC-дней). Всегда сохраняется самый свежий;
  бэкапы без таймстемпа не удаляются никогда.
- **Recurring**: `ActiveBackup::BackupJob < ActiveJob::Base`
  (perform = create + prune). Регистрация в шедулере приложения —
  `ActiveJob::SolidQueue::RecurringTask.new("active_backup",
  "ActiveBackup::BackupJob", "0 4 * * *")` + `adapter.
  schedule_recurring`. События `create.active_backup` /
  `restore.active_backup` в ActiveSupport::Notifications.

## API

```crystal
ActiveBackup.configure do |c|
  c.store = ActiveBackup::LocalStore.new("backups") # или S3-стор (P1)
  c.database_url = "postgres:///app_prod?host=/var/run/postgresql"
  c.paths = ["storage"]        # ActiveStorage disk root и др.
  c.retention = ActiveBackup::RetentionPolicy.new(
    keep_last: 14, keep_days: 30)
end

ActiveBackup.create              # → Store::Entry
ActiveBackup.restore             # новейший; name:/clean:/roots:/database_url:
ActiveBackup.prune               # → Array(String) удалённых
```

Резолв URL БД: `config.database_url` → `ENV["DATABASE_URL"]` (явность
вместо магии; `DB::Database` не хранит uri публично).

## Оракул/спеки (18/18, `crystal spec`)

- `spec/tar_spec.cr` — ustar writer/reader: roundtrip, prefix-поля,
  чексам, побайтовая раскладка; **системный tar** листит/распаковывает
  наши архивы; наш Reader читает GNU-tar-фикстуру (oracle/fixtures).
- `spec/stores_spec.cr` — LocalStore (save=move, mtime-fallback),
  MemoryStore; retention: keep_last/keep_days/новейший/без-времени.
- `spec/restore_spec.cr` — **restore-тест в CI**: сидинг БД (bytea,
  unicode, timestamptz, массивы) + файлов (вложенность, бинарники,
  unicode-имена) → create → `tar -tzf` (оракул формата) → DROP
  DATABASE + rm -rf → restore → побайтовая сверка БД и файлов;
  повторный restore с `clean: true`; порча байта → CorruptBackupError.
  Скипается без локального PG/pg_dump/tar.
- `spec/job_spec.cr` — BackupJob: perform_later в TestAdapter,
  perform_now = цикл create+prune.

## Отклонения/решения

- **Pinned-бинари PG**: Debian postgresql-common при нескольких
  версиях гоняет pg_dump 17 к серверу 16 (custom-format 1.16 не
  читается 16-м pg_restore; pg_restore 17 падает на
  `SET transaction_timeout`). Pg резолвит `/usr/lib/postgresql/
  <server-major>/bin/{pg_dump,pg_restore}` (мажор детектится одним
  `psql SHOW server_version_num`, мемоизируется), иначе PATH.
- **Обход бага Crystal 1.21**: вложенный блок (`File.open` внутри
  yield-блока `add_file`) в месте вызова роняет codegen — внутренний
  copy-with-hash вынесен в `Archive.copy_with_digest`.
- tar: без symlink/PAX/GNU-длинных-имён (reader молча пропускает
  неизвестные typeflag'и); имена ≤255 байт (prefix-поле ustar).
- symlinks в бэкапимых деревьях не включаются (P2), как и
  инкрементальные бэкапы/шифрование (P2).
- `crails`-CLI (backup:create/restore/list) — P1: приложение
  вызывает API из rake-таски/джобы; railties не зависит от шарды.

## P1/P2

- P1: S3-стор (порт Store), `crails backup:*`-команды, метрики в
  manifest (длительность, размеры), уведомления об ошибках.
- P2: инкрементальные бэкапы, шифрование архива (AES-GCM поверх
  active_support MessageEncryptor), symlink/ACL, restore-драй-ран.

## Зависимости

active_support_cr (Notifications), active_job_cr (BackupJob),
active_record_cr (экосистема; в ядре шарды не используется).
Инструменты окружения: pg_dump/pg_restore (версия сервера), GNU tar.

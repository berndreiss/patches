#! /bin/bash

rm -fr temp_db
$base_bin/pg_ctl -D temp_db init
$base_bin/pg_ctl -D temp_db -l temp_db.log -o "-c shared_buffers=128kB -c track_io_timing=on" start
$base_bin/psql -f /var/lib/postgresql/test_script.sql
$base_bin/pg_ctl -D temp_db stop
rm -fr temp_db
$patch_bin/pg_ctl -D temp_db init
$patch_bin/pg_ctl -D temp_db -l temp_db.log -o "-c shared_buffers=128kB -c track_io_timing=on" start
$patch_bin/psql -f /var/lib/postgresql/test_script.sql
$patch_bin/pg_ctl -D temp_db stop

function bench() {
    printenv PG;
    pkill -9 postgres
    rm -fr temp_db
    $PG/initdb temp_db
    $PG/pg_ctl -D temp_db -l temp_db.log -o "-c shared_buffers=128kB -c track_io_timing=on" start
    $PG/pgbench -i -s 100 postgres
    $PG/pgbench -S -T 60 postgres > /dev/null
    $PG/pgbench -S -T 7200 postgres
    $PG/pg_ctl -D temp_db stop
}

for i in {1..3}; do
    PG=$base_bin bench
    PG=$patch_bin bench
    PG=$patch_bin bench
    PG=$base_bin bench
done

#!/usr/bin/env bash
# Runs the StrideMate database test suite against a throw-away PostgreSQL database.
#
#   scripts/test_db.sh                 # uses $DATABASE_URL (a server you can create databases on)
#   PGHOST=/tmp/pg PGPORT=54329 PGUSER=postgres scripts/test_db.sh
#   scripts/test_db.sh --load          # also runs the 15,000-member load test
#
# Requires psql and a PostgreSQL 15+ server. The tests apply a small Supabase shim
# (auth.users, auth.uid(), roles) then every migration, then the test files.
set -euo pipefail
cd "$(dirname "$0")/.."
DB="stridemate_test_$$"
ADMIN_URL="${DATABASE_URL:-}"
run_admin() { if [[ -n "$ADMIN_URL" ]]; then psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q "$@"; else psql -d postgres -v ON_ERROR_STOP=1 -q "$@"; fi; }
run_db() {
  if [[ -n "$ADMIN_URL" ]]; then psql "${ADMIN_URL%/*}/$DB" -v ON_ERROR_STOP=1 -q -X "$@"
  else psql -d "$DB" -v ON_ERROR_STOP=1 -q -X "$@"; fi
}
cleanup() { run_admin -c "drop database if exists $DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

run_admin -c "create database $DB"
run_db -f supabase/tests/00_supabase_shim.sql 2>&1 | grep -v -E "wal_level|HINT" || true
for f in supabase/migrations/*.sql; do
  run_db -f "$f" 2>&1 | grep -v "pg_cron not available" || true
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "Migration failed: $f"; exit 1; }
done
echo "Migrations applied: $(ls supabase/migrations/*.sql | wc -l)"
run_db -f supabase/tests/01_helpers.sql
status=0
for f in supabase/tests/[1-9]*.sql; do
  echo "== $f"
  if ! run_db -f "$f" 2>&1 | sed -n 's/.*NOTICE:  \(PASS.*\)/  \1/p; s/.*ERROR:  \(.*\)/  FAIL: \1/p' | tee /tmp/sm_test_out.$$; then status=1; fi
  if grep -q "FAIL" /tmp/sm_test_out.$$; then status=1; fi
done
if [[ "${1:-}" == "--load" ]]; then
  echo "== supabase/tests/load/large_group_load_test.sql"
  run_db -f supabase/tests/load/large_group_load_test.sql 2>&1 | sed -n 's/.*NOTICE:  //p; s/.*ERROR:  \(.*\)/FAIL: \1/p' | tee /tmp/sm_load_out.$$
  grep -q "FAIL" /tmp/sm_load_out.$$ && status=1
fi
rm -f /tmp/sm_test_out.$$ /tmp/sm_load_out.$$
[[ $status -eq 0 ]] && echo "ALL DATABASE TESTS PASSED" || echo "DATABASE TESTS FAILED"
exit $status

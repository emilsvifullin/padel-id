#!/usr/bin/env bash
# Runs the Padel ID database test-suite. Each test runs in its own transaction
# that is rolled back, so tests are independent and leave no data behind.
# Connection is taken from standard libpq environment variables (PGHOST,
# PGPORT, PGUSER, PGPASSWORD, PGDATABASE).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

for f in "$ROOT"/supabase/tests/*.sql; do
  "${PSQL[@]}" -f "$f" >/dev/null || { echo "failed to load $f"; exit 1; }
done

mapfile -t TESTS < <("${PSQL[@]}" -At -c "select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'tests' and p.proname like 'test\_%' order by 1")
pass=0; fail=0
for t in "${TESTS[@]}"; do
  out=$("${PSQL[@]}" -c "begin; select tests.$t(); rollback;" 2>&1)
  if [ $? -eq 0 ]; then
    pass=$((pass+1)); echo "ok   $t"
  else
    fail=$((fail+1)); echo "FAIL $t"; echo "$out" | grep -E 'ERROR|DETAIL|CONTEXT' | head -6 | sed 's/^/     /'
  fi
done
"${PSQL[@]}" -c "drop schema if exists tests cascade" >/dev/null 2>&1
echo "database tests: $pass passed, $fail failed"
[ $fail -eq 0 ]

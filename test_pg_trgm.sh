#!/usr/bin/env bash

echo "=== Testing pg_trgm Extension ==="

echo "1. Checking if pg_trgm extension exists..."
docker compose exec database psql -U postgres -d dhis -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_trgm';"

echo ""
echo "2. Testing pg_trgm functionality..."
docker compose exec database psql -U postgres -d dhis -c "SELECT 'test' % 'test' as similarity_test;"

echo ""
echo "3. Testing if dhis user can use pg_trgm..."
docker compose exec database psql -U dhis -d dhis -c "SELECT 'test' % 'testing' as dhis_user_test;" 2>/dev/null && echo "✓ dhis user can use pg_trgm" || echo "✗ dhis user cannot use pg_trgm"

echo ""
echo "4. Checking all installed extensions..."
docker compose exec database psql -U postgres -d dhis -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"

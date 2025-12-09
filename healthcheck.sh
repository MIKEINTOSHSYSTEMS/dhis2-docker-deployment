#!/usr/bin/env bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_green() { echo -e "${GREEN}$1${NC}"; }
echo_red() { echo -e "${RED}$1${NC}"; }
echo_yellow() { echo -e "${YELLOW}$1${NC}"; }

# Load environment
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs) 2>/dev/null
fi

echo "=== DHIS2 Health Check ==="

echo "1. Container Status:"
docker compose ps 2>/dev/null || echo_yellow "  Docker compose not available"

echo ""
echo "2. Checking services:"
services=("database" "app" "traefik")
for service in "${services[@]}"; do
    status=$(docker compose ps $service 2>/dev/null | grep -o "Up\|Exit\|healthy\|unhealthy" | head -1)
    if [ "$status" = "Up" ] || [ "$status" = "healthy" ]; then
        echo_green "  ✓ $service is $status"
    elif [ "$status" = "unhealthy" ]; then
        echo_yellow "  ⚠ $service is $status"
    else
        echo_red "  ✗ $service is not running"
    fi
done

echo ""
echo "3. Checking database connection:"
if docker compose exec database pg_isready -U postgres >/dev/null 2>&1; then
    echo_green "  ✓ Database is accepting connections"
    
    # Check if dhis user can connect
    if PGPASSWORD="${POSTGRES_DB_PASSWORD}" docker compose exec -T database psql -U "${POSTGRES_DB_USERNAME}" -d "${POSTGRES_DB}" -c "SELECT 1;" >/dev/null 2>&1; then
        echo_green "  ✓ dhis user can connect to database"
    else
        echo_red "  ✗ dhis user cannot connect to database"
    fi
else
    echo_red "  ✗ Database is not accepting connections"
fi

echo ""
echo "4. Checking application API:"
if curl -f http://localhost:8080/api/system/info >/dev/null 2>&1; then
    echo_green "  ✓ Application API is accessible"
elif docker compose ps app 2>/dev/null | grep -q "Up"; then
    echo_yellow "  ⚠ Application is running but API may not be ready"
else
    echo_red "  ✗ Application is not running"
fi

echo ""
echo "5. Quick Actions:"
echo "   - View logs:        docker compose logs -f"
echo "   - Restart all:      docker compose restart"
echo "   - Stop all:         docker compose down"
echo "   - Full restart:     ./cleanrestart.sh"

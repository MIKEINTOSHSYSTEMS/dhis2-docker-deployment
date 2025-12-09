#!/usr/bin/env bash
# debug-docker-compose.sh

echo "=== Debugging Docker Compose ==="

# Check Docker Compose version
echo "1. Docker Compose version:"
docker compose version

# Check .env variables
echo -e "\n2. Important .env variables:"
grep -E "^(APP_HOSTNAME|POSTGRES|DHIS2)" .env | head -10

# Try to validate docker-compose.yml
echo -e "\n3. Validating docker-compose.yml..."
docker compose config 2>&1 | head -20

# Check if port 5432 is available
echo -e "\n4. Checking port 5432:"
netstat -tulpn | grep :5432 || echo "Port 5432 is free"

# Check Docker networks
echo -e "\n5. Docker networks:"
docker network ls

# Try to start database with verbose output
echo -e "\n6. Trying to start database with debug:"
docker compose up database --build 2>&1 | tail -20
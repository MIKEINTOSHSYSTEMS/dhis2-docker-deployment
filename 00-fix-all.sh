#!/usr/bin/env bash
set -e

# Stop and remove everything
docker compose down -v

# Remove old init scripts
rm init-scripts/*.sh

# Create fixed init scripts

# Script 01: Create database and user (run as postgres)
cat > init-scripts/01-create-database-user.sh << 'EOF'
#!/usr/bin/env bash
set -e

# Create the database user
psql -v -U postgres -d postgres -c "CREATE USER $POSTGRES_DB_USERNAME WITH PASSWORD '$POSTGRES_DB_PASSWORD';"

# Create the database with the user as owner
psql -v -U postgres -d postgres -c "CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_DB_USERNAME;"

# Grant all privileges on the database
psql -v -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_DB_USERNAME;"

# Connect to the new database to grant schema permissions
psql -v -U postgres -d "$POSTGRES_DB" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $POSTGRES_DB_USERNAME;"
psql -v -U postgres -d "$POSTGRES_DB" -c "ALTER SCHEMA public OWNER TO $POSTGRES_DB_USERNAME;"
EOF

# Script 02: Add PostGIS extension (MUST run as postgres, not dhis user)
cat > init-scripts/02-create-postgis.sh << 'EOF'
#!/usr/bin/env bash
set -e

# Add PostGIS to the database - MUST run as postgres
psql -v -U postgres -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS postgis;"
psql -v -U postgres -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"
psql -v -U postgres -d "$POSTGRES_DB" -c "SELECT PostGIS_Version();"
EOF

# Script 03: Create metrics user
cat > init-scripts/03-create-metrics-user.sh << 'EOF'
#!/usr/bin/env bash
set -e

# Create metrics user
psql -v -U postgres -d postgres -c "CREATE USER $POSTGRES_METRICS_USERNAME WITH PASSWORD '$POSTGRES_METRICS_PASSWORD';"
psql -v -U postgres -d postgres -c "GRANT pg_monitor TO $POSTGRES_METRICS_USERNAME;"
psql -v -U postgres -d postgres -c "GRANT CONNECT ON DATABASE $POSTGRES_DB TO $POSTGRES_METRICS_USERNAME;"
EOF

# Make scripts executable
chmod +x init-scripts/*.sh

# Start fresh
echo "Starting fresh setup..."
docker compose up -d

echo "Setup complete! Check logs with: docker compose logs app"
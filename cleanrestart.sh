#!/usr/bin/env bash

echo "==============================================="
echo "DHIS2 Docker - Complete Clean Restart Script"
echo "==============================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[x]${NC} $1"
}

# Function to check if a command succeeded
check_status() {
    if [ $? -eq 0 ]; then
        print_status "$1"
    else
        print_error "$2"
        exit 1
    fi
}

# Function to wait for container to be healthy
wait_for_healthy() {
    local container=$1
    local timeout=$2
    local interval=5
    local elapsed=0
    
    print_status "Waiting for $container to be healthy (timeout: ${timeout}s)..."
    
    while [ $elapsed -lt $timeout ]; do
        if docker compose ps $container | grep -q "(healthy)"; then
            print_status "$container is healthy!"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for $container to be healthy"
    docker compose logs $container
    return 1
}

# Function to execute SQL command
exec_psql() {
    local sql="$1"
    docker compose exec database psql -U postgres -d dhis -c "$sql"
}

# Step 1: Stop and remove everything
print_status "Step 1: Stopping and removing all containers, volumes, and networks..."
docker compose down -v
check_status "All containers, volumes, and networks removed" "Failed to stop and remove containers"

# Step 2: Clean up init scripts directory
print_status "Step 2: Cleaning up init scripts directory..."
rm -rf init-scripts
mkdir -p init-scripts
check_status "Init scripts directory cleaned" "Failed to clean init scripts directory"

# Step 3: Create robust init scripts
print_status "Step 3: Creating robust initialization scripts..."

# Create a single SQL file approach - more reliable than shell scripts
cat > init-scripts/init.sql << 'EOF'
-- DHIS2 Database Initialization Script
-- This runs as the postgres superuser during container initialization

-- Create the dhis user if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'dhis') THEN
        CREATE USER dhis WITH ENCRYPTED PASSWORD 'uYKjkPnaUT3X7F-pA0iXkHTmad==FSrD';
    END IF;
END
$$;

-- Create the database if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dhis') THEN
        CREATE DATABASE dhis OWNER dhis;
    END IF;
END
$$;

-- Connect to the dhis database
\c dhis

-- Grant all privileges to dhis user on the database
GRANT ALL PRIVILEGES ON DATABASE dhis TO dhis;

-- Ensure dhis user owns the public schema
ALTER SCHEMA public OWNER TO dhis;
GRANT ALL PRIVILEGES ON SCHEMA public TO dhis;
GRANT CREATE ON SCHEMA public TO dhis;

-- Install PostGIS and other required extensions
-- Must be installed as superuser (postgres)
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- Set default privileges for the dhis user
-- This ensures all future tables, sequences, and functions created by dhis get proper permissions
ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public GRANT ALL ON TABLES TO dhis;
ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public GRANT ALL ON SEQUENCES TO dhis;
ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public GRANT ALL ON FUNCTIONS TO dhis;
ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public GRANT ALL ON TYPES TO dhis;

-- Also set default privileges for postgres creating objects for dhis
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO dhis;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO dhis;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO dhis;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO dhis;

-- Create metrics user if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'metrics') THEN
        CREATE USER metrics WITH ENCRYPTED PASSWORD 'oivg70=9kfWoZS=ezj1Pu79=ny857aZR';
    END IF;
END
$$;

-- Grant necessary privileges to metrics user
GRANT pg_monitor TO metrics;
GRANT CONNECT ON DATABASE dhis TO metrics;

-- Set search_path for the dhis user
ALTER ROLE dhis SET search_path TO public;

-- Verify setup
SELECT 'Database setup complete' as status;
SELECT PostGIS_Version() as postgis_version;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('postgis', 'pg_trgm', 'btree_gin');
EOF

check_status "SQL initialization script created" "Failed to create SQL script"

# Also create shell scripts as backup with proper error handling
cat > init-scripts/01-setup-database.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo "Running database setup script..."

# Create dhis user if it doesn't exist
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$POSTGRES_DB_USERNAME') THEN
            CREATE USER $POSTGRES_DB_USERNAME WITH ENCRYPTED PASSWORD '$POSTGRES_DB_PASSWORD';
        END IF;
    END
    \$\$;
EOSQL

# Create dhis database if it doesn't exist
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '$POSTGRES_DB') THEN
            CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_DB_USERNAME;
        END IF;
    END
    \$\$;
EOSQL

# Grant privileges
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_DB_USERNAME;"

# Connect to dhis database and set up schema
psql -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" <<-EOSQL
    ALTER SCHEMA public OWNER TO $POSTGRES_DB_USERNAME;
    GRANT ALL PRIVILEGES ON SCHEMA public TO $POSTGRES_DB_USERNAME;
    GRANT CREATE ON SCHEMA public TO $POSTGRES_DB_USERNAME;
    
    -- Set default privileges
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public GRANT ALL ON TABLES TO $POSTGRES_DB_USERNAME;
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public GRANT ALL ON SEQUENCES TO $POSTGRES_DB_USERNAME;
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public GRANT ALL ON FUNCTIONS TO $POSTGRES_DB_USERNAME;
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public GRANT ALL ON TYPES TO $POSTGRES_DB_USERNAME;
    
    -- Also for postgres creating objects
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $POSTGRES_DB_USERNAME;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $POSTGRES_DB_USERNAME;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO $POSTGRES_DB_USERNAME;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO $POSTGRES_DB_USERNAME;
EOSQL

echo "Database setup complete"
EOF

cat > init-scripts/02-install-extensions.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo "Installing required extensions..."

# Install as postgres superuser
psql -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" <<-EOSQL
    -- PostGIS extensions
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS postgis_topology;
    CREATE EXTENSION IF NOT EXISTS postgis_raster;
    CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
    CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
    
    -- DHIS2 required extensions
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS btree_gin;
    
    -- Verify installation
    SELECT 'Extensions installed successfully' as message;
    SELECT extname, extversion FROM pg_extension WHERE extname IN ('postgis', 'pg_trgm', 'btree_gin');
EOSQL

echo "Extensions installation complete"
EOF

cat > init-scripts/03-create-metrics-user.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo "Creating metrics user..."

psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$POSTGRES_METRICS_USERNAME') THEN
            CREATE USER $POSTGRES_METRICS_USERNAME WITH ENCRYPTED PASSWORD '$POSTGRES_METRICS_PASSWORD';
        END IF;
    END
    \$\$;
    
    GRANT pg_monitor TO $POSTGRES_METRICS_USERNAME;
    GRANT CONNECT ON DATABASE $POSTGRES_DB TO $POSTGRES_METRICS_USERNAME;
EOSQL

echo "Metrics user created"
EOF

# Make shell scripts executable
chmod +x init-scripts/*.sh
check_status "Shell scripts created and made executable" "Failed to create shell scripts"

# Step 4: Start the database first
print_status "Step 4: Starting database container..."
docker compose up database -d
check_status "Database container started" "Failed to start database container"

# Step 5: Wait for database to be healthy
wait_for_healthy database 60

# Step 6: Manually verify and fix database setup (robust approach)
print_status "Step 6: Verifying and finalizing database setup..."

# Check if init scripts ran successfully
print_status "Checking if init scripts ran..."
docker compose logs database | grep -i "CREATE\|GRANT\|PostGIS\|pg_trgm\|ERROR\|FATAL" | tail -30

# Install ALL required extensions as postgres superuser
print_status "Installing ALL required extensions (must be done as postgres superuser)..."

# Install PostGIS extensions
print_status "Installing PostGIS extensions..."
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis;"
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis_raster;"
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;"
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;"

# Install DHIS2 required extensions
print_status "Installing pg_trgm extension (required by DHIS2)..."
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

print_status "Installing btree_gin extension..."
docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS btree_gin;"

# Verify all extensions are installed
print_status "Verifying all extensions are installed..."
docker compose exec database psql -U postgres -d dhis -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
check_status "Extensions verified" "Failed to verify extensions"

# Ensure dhis user has proper permissions and default privileges
print_status "Ensuring dhis user has proper permissions and default privileges..."
docker compose exec database psql -U postgres -d dhis -c "
    -- Ensure dhis owns the schema
    ALTER SCHEMA public OWNER TO dhis;
    
    -- Grant schema permissions
    GRANT ALL PRIVILEGES ON SCHEMA public TO dhis;
    GRANT CREATE ON SCHEMA public TO dhis;
    
    -- Grant CREATE privilege on database for extension creation
    GRANT CREATE ON DATABASE dhis TO dhis;
    
    -- Set default privileges for objects created by dhis
    ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
    GRANT ALL ON TABLES TO dhis;
    
    ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
    GRANT ALL ON SEQUENCES TO dhis;
    
    ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
    GRANT ALL ON FUNCTIONS TO dhis;
    
    ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
    GRANT ALL ON TYPES TO dhis;
    
    -- Also set default privileges for postgres creating objects for dhis
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON TABLES TO dhis;
    
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON SEQUENCES TO dhis;
    
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON FUNCTIONS TO dhis;
    
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON TYPES TO dhis;
    
    -- Set search path
    ALTER ROLE dhis SET search_path TO public;
"
check_status "Permissions and default privileges granted" "Failed to grant permissions"

# Create metrics user if not exists
print_status "Creating metrics user..."
docker compose exec database psql -U postgres -c "
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'metrics') THEN
            CREATE USER metrics WITH ENCRYPTED PASSWORD 'oivg70=9kfWoZS=ezj1Pu79=ny857aZR';
        END IF;
    END
    \$\$;
    
    GRANT pg_monitor TO metrics;
    GRANT CONNECT ON DATABASE dhis TO metrics;
"
check_status "Metrics user configured" "Failed to configure metrics user"

# Verify pg_trgm is installed and accessible
print_status "Verifying pg_trgm extension is properly installed..."
docker compose exec database psql -U postgres -d dhis -c "
    SELECT 'pg_trgm installed: ' || (SELECT extversion FROM pg_extension WHERE extname = 'pg_trgm') as status;
    
    -- Test pg_trgm functionality
    SELECT 'test' % 'test' as pg_trgm_test;
"
check_status "pg_trgm verified" "pg_trgm not working properly"

# Step 7: Verify database setup
print_status "Step 7: Verifying database setup..."

print_status "Listing users and their privileges..."
docker compose exec database psql -U postgres -c "\du"

print_status "Listing databases..."
docker compose exec database psql -U postgres -c "\l"

print_status "Checking schema permissions..."
docker compose exec database psql -U postgres -d dhis -c "\dn+"

print_status "Checking all extensions..."
docker compose exec database psql -U postgres -d dhis -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"

print_status "Checking dhis user privileges..."
docker compose exec database psql -U postgres -d dhis -c "
    SELECT 
        grantee,
        privilege_type,
        table_schema,
        table_name
    FROM information_schema.role_table_grants 
    WHERE grantee = 'dhis'
    LIMIT 10;
"

# Step 8: Fix hosts file for nip.io domains (for local development)
print_status "Step 8: Setting up local DNS resolution..."
if ! grep -q "dhis2-127-0-0-1.nip.io" /etc/hosts 2>/dev/null; then
    print_warning "Consider adding to /etc/hosts (run with sudo):"
    echo "127.0.0.1 dhis2-127-0-0-1.nip.io"
    echo "127.0.0.1 grafana.dhis2-127-0-0-1.nip.io"
    echo "127.0.0.1 glowroot.dhis2-127-0-0-1.nip.io"
    print_warning "Command: sudo bash -c 'echo \"127.0.0.1 dhis2-127-0-0-1.nip.io\" >> /etc/hosts'"
    print_warning "Command: sudo bash -c 'echo \"127.0.0.1 grafana.dhis2-127-0-0-1.nip.io\" >> /etc/hosts'"
    print_warning "Command: sudo bash -c 'echo \"127.0.0.1 glowroot.dhis2-127-0-0-1.nip.io\" >> /etc/hosts'"
fi

# Step 9: Start the full application
print_status "Step 9: Starting DHIS2 application..."
docker compose up -d
check_status "DHIS2 application started" "Failed to start DHIS2 application"

# Step 10: Wait for application to be healthy (give it more time)
print_status "Step 10: Waiting for DHIS2 application to be healthy (this may take 3-5 minutes)..."
wait_for_healthy app 300

# Step 11: Final verification
print_status "Step 11: Final verification..."

print_status "Checking all containers..."
docker compose ps

print_status "Checking application logs for startup..."
docker compose logs app --tail=50 | grep -i -A5 -B5 "started\|ready\|pg_trgm\|PostGIS\|error\|exception\|warn"

print_status "Checking database connection from app..."
if docker compose exec app curl -f http://localhost:8080/api/system/info 2>/dev/null; then
    print_status "✓ API is accessible"
else
    print_warning "API not accessible yet, checking logs..."
    docker compose logs app --tail=20
fi

# Step 12: Display access information
echo ""
echo "==============================================="
echo "DHIS2 Setup Complete!"
echo "==============================================="
echo ""
echo "Access URLs:"
echo "  DHIS2 Application: https://dhis2-127-0-0-1.nip.io"
echo "  Grafana:           https://grafana.dhis2-127-0-0-1.nip.io"
echo ""
echo "Credentials:"
echo "  DHIS2 Admin:"
echo "    Username: admin"
echo "    Password: $(grep DHIS2_ADMIN_PASSWORD .env | cut -d= -f2)"
echo ""
echo "  Grafana:"
echo "    Username: admin"
echo "    Password: $(grep GRAFANA_ADMIN_PASSWORD .env | cut -d= -f2)"
echo ""
echo "Database Extensions Installed:"
docker compose exec database psql -U postgres -d dhis -c "SELECT extname FROM pg_extension ORDER BY extname;" 2>/dev/null | grep -v extname | grep -v "\-\-" | sed 's/^/  - /'
echo ""
echo "Useful commands:"
echo "  View logs:              docker compose logs -f"
echo "  View app logs:          docker compose logs app -f"
echo "  View database logs:     docker compose logs database -f"
echo "  Stop all:               docker compose down"
echo "  Restart app:            docker compose restart app"
echo "  Check container status: docker compose ps"
echo "  Health check:           ./healthcheck.sh"
echo "  Quick fixes:            ./quickfix.sh [option]"
echo ""
echo "Note: If you encounter certificate errors, add the following"
echo "to your /etc/hosts file (requires sudo):"
echo "  127.0.0.1 dhis2-127-0-0-1.nip.io"
echo "  127.0.0.1 grafana.dhis2-127-0-0-1.nip.io"
echo "  127.0.0.1 glowroot.dhis2-127-0-0-1.nip.io"
echo ""
echo "==============================================="

# Step 13: Create a health check script for future use
print_status "Creating health check script..."
cat > healthcheck.sh << 'EOF'
#!/usr/bin/env bash

echo "=== DHIS2 Health Check ==="

# Check containers
echo "1. Checking containers..."
docker compose ps

echo ""
echo "2. Checking database extensions..."
docker compose exec database psql -U postgres -d dhis -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('postgis', 'pg_trgm', 'btree_gin');" 2>/dev/null || echo "Database not accessible"

echo ""
echo "3. Checking pg_trgm extension..."
if docker compose exec database psql -U postgres -d dhis -c "SELECT 'test' % 'test' as pg_trgm_test;" 2>/dev/null | grep -q "t"; then
    echo "✓ pg_trgm extension is working"
else
    echo "✗ pg_trgm extension may not be installed or working"
fi

echo ""
echo "4. Checking application..."
if docker compose exec app curl -f http://localhost:8080/api/system/info > /dev/null 2>&1; then
    echo "✓ Application is running and API is accessible"
else
    echo "✗ Application may not be fully started"
    echo "   Check logs: docker compose logs app --tail=50"
fi

echo ""
echo "5. Recent logs (last 10 lines)..."
docker compose logs --tail=10
EOF

chmod +x healthcheck.sh
print_status "Health check script created: ./healthcheck.sh"

# Step 14: Create a quick fix script for common issues
print_status "Creating quick fix script..."
cat > quickfix.sh << 'EOF'
#!/usr/bin/env bash

echo "=== DHIS2 Quick Fix ==="

case "$1" in
    "extensions")
        echo "Installing/Repairing all required extensions..."
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis;"
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS postgis_raster;"
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS btree_gin;"
        echo "✓ Extensions installed"
        ;;
    "permissions")
        echo "Fixing database permissions..."
        docker compose exec database psql -U postgres -d dhis -c "
            ALTER SCHEMA public OWNER TO dhis;
            GRANT ALL PRIVILEGES ON SCHEMA public TO dhis;
            GRANT CREATE ON SCHEMA public TO dhis;
            GRANT CREATE ON DATABASE dhis TO dhis;
            
            ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
            GRANT ALL ON TABLES TO dhis;
            
            ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
            GRANT ALL ON SEQUENCES TO dhis;
            
            ALTER DEFAULT PRIVILEGES FOR ROLE dhis IN SCHEMA public 
            GRANT ALL ON FUNCTIONS TO dhis;
        "
        echo "✓ Permissions fixed"
        ;;
    "pg_trgm")
        echo "Specifically fixing pg_trgm extension..."
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
        docker compose exec database psql -U postgres -d dhis -c "GRANT CREATE ON DATABASE dhis TO dhis;"
        echo "✓ pg_trgm extension fixed"
        ;;
    "restart")
        echo "Restarting application..."
        docker compose restart app
        echo "✓ Application restarted"
        ;;
    "logs")
        echo "Showing recent logs..."
        docker compose logs --tail=100
        ;;
    "recreate")
        echo "Recreating containers..."
        docker compose up -d --force-recreate
        echo "✓ Containers recreated"
        ;;
    "full")
        echo "Running full fix (extensions + permissions + restart)..."
        docker compose exec database psql -U postgres -d dhis -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
        docker compose exec database psql -U postgres -d dhis -c "GRANT CREATE ON DATABASE dhis TO dhis;"
        docker compose exec database psql -U postgres -d dhis -c "ALTER SCHEMA public OWNER TO dhis;"
        docker compose restart app
        echo "✓ Full fix applied"
        ;;
    *)
        echo "Usage: $0 {extensions|permissions|pg_trgm|restart|logs|recreate|full}"
        echo ""
        echo "  extensions  - Install/repair all required extensions"
        echo "  permissions - Fix database permissions"
        echo "  pg_trgm     - Specifically fix pg_trgm extension"
        echo "  restart     - Restart the application"
        echo "  logs        - Show recent logs"
        echo "  recreate    - Recreate containers"
        echo "  full        - Run full fix (extensions + permissions + restart)"
        exit 1
        ;;
esac
EOF

chmod +x quickfix.sh
print_status "Quick fix script created: ./quickfix.sh"

# Step 15: Create a test script to verify pg_trgm is working
print_status "Creating pg_trgm test script..."
cat > test_pg_trgm.sh << 'EOF'
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
EOF

chmod +x test_pg_trgm.sh
print_status "pg_trgm test script created: ./test_pg_trgm.sh"

echo ""
print_status "Setup complete! Important notes:"
print_warning "1. The pg_trgm extension MUST be installed as the postgres superuser"
print_warning "2. The dhis user needs CREATE privilege on the database to use extensions"
print_warning "3. If pg_trgm errors persist, run: ./quickfix.sh pg_trgm"
print_warning "4. Then run: ./quickfix.sh restart"
echo ""
print_status "Run these commands to verify:"
echo "  ./healthcheck.sh      - Check overall health"
echo "  ./test_pg_trgm.sh     - Specifically test pg_trgm"
echo "  ./quickfix.sh full    - Apply all fixes if needed"
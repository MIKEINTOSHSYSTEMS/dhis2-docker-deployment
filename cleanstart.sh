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
        return 1
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
        if docker compose ps $container 2>/dev/null | grep -q "(healthy)"; then
            print_status "$container is healthy!"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for $container to be healthy"
    docker compose logs $container --tail=50 2>/dev/null || echo "Could not fetch logs"
    return 1
}

# Function to load environment variables
load_env_variables() {
    if [ -f .env ]; then
        # Clean the .env file of Windows line endings
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix .env 2>/dev/null
        elif command -v sed >/dev/null 2>&1; then
            sed -i 's/\r$//' .env 2>/dev/null
        fi
        
        # Load environment variables
        export $(grep -v '^#' .env | xargs) 2>/dev/null
        
        # Set defaults for required variables
        export APP_HOSTNAME="${APP_HOSTNAME:-dhis.merqconsultancy.org}"
        export POSTGRES_DB="${POSTGRES_DB:-dhis}"
        export POSTGRES_DB_USERNAME="${POSTGRES_DB_USERNAME:-dhis}"
        export POSTGRES_DB_PASSWORD="${POSTGRES_DB_PASSWORD:-dhis}"
        export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
        export POSTGRES_VERSION="${POSTGRES_VERSION:-16-master}"
        export DHIS2_VERSION="${DHIS2_VERSION:-42}"
        export DHIS2_ADMIN_USERNAME="${DHIS2_ADMIN_USERNAME:-admin}"
        export DHIS2_MONITOR_USERNAME="${DHIS2_MONITOR_USERNAME:-monitor}"
        export POSTGRES_METRICS_USERNAME="${POSTGRES_METRICS_USERNAME:-metrics}"
        export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
        
        # Validate required variables
        local required_vars=("APP_HOSTNAME" "POSTGRES_DB" "POSTGRES_DB_USERNAME" "POSTGRES_DB_PASSWORD" "POSTGRES_PASSWORD")
        for var in "${required_vars[@]}"; do
            if [ -z "${!var+x}" ]; then
                print_error "Required environment variable $var is not set"
                exit 1
            fi
        done
        
        print_status "Environment variables loaded successfully"
        print_status "Database: ${POSTGRES_DB}, User: ${POSTGRES_DB_USERNAME}"
        print_status "DB Password (first 10 chars): ${POSTGRES_DB_PASSWORD:0:10}..."
    else
        print_error ".env file not found!"
        exit 1
    fi
}

# Function to execute SQL command directly (simpler approach)
exec_sql() {
    local sql="$1"
    local db="${2:-postgres}"
    
    print_status "Executing SQL: ${sql:0:50}..."
    
    # Use docker exec directly with timeout
    if docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres -d '$db' -c \"$sql\"" 2>&1; then
        return 0
    else
        # If that fails, try alternative approach
        print_warning "First SQL attempt failed, trying alternative..."
        if docker compose exec database bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres -d '$db' -c '$sql'" 2>&1; then
            return 0
        else
            print_warning "SQL command may have failed: ${sql:0:50}..."
            return 1
        fi
    fi
}

# Function to check if database exists
check_database_exists() {
    print_status "Checking if database ${POSTGRES_DB} exists..."
    
    local result
    result=$(docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres -t -c \"SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}';\" 2>/dev/null" | tr -d '[:space:]')
    
    if [ "$result" = "1" ]; then
        print_status "Database ${POSTGRES_DB} exists"
        return 0
    else
        print_warning "Database ${POSTGRES_DB} does not exist or cannot be checked"
        return 1
    fi
}

# Function to check if user exists
check_user_exists() {
    local username="$1"
    print_status "Checking if user ${username} exists..."
    
    local result
    result=$(docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres -t -c \"SELECT 1 FROM pg_roles WHERE rolname = '${username}';\" 2>/dev/null" | tr -d '[:space:]')
    
    if [ "$result" = "1" ]; then
        print_status "User ${username} exists"
        return 0
    else
        print_warning "User ${username} does not exist or cannot be checked"
        return 1
    fi
}

# Function to check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running or current user doesn't have permissions"
        exit 1
    fi
    print_status "Docker is running"
}

# Function to clean up Docker resources
cleanup_docker_resources() {
    print_status "Cleaning up Docker resources..."
    
    # Stop and remove all containers
    docker compose down -v --remove-orphans 2>/dev/null || true
    
    # Remove dangling networks
    docker network prune -f 2>/dev/null || true
    
    # Clean up volumes that might be causing issues
    docker volume rm -f dhis2-docker-deployment_postgres 2>/dev/null || true
    docker volume rm -f dhis2-docker-deployment_dhis2 2>/dev/null || true
    
    print_status "Docker resources cleaned up"
}

# Function to create proper init scripts with correct passwords
create_init_scripts() {
    print_status "Creating initialization scripts..."
    
    rm -rf init-scripts 2>/dev/null || true
    mkdir -p init-scripts
    
    # Create init script with correct password from .env
    cat > init-scripts/01-create-user-db.sh << EOF
#!/bin/bash
set -e

echo "Creating DHIS2 database and user..."

# Wait for PostgreSQL to start
until pg_isready -U postgres; do
    sleep 2
done

# Create dhis user with correct password from environment
psql -U postgres -c "CREATE USER ${POSTGRES_DB_USERNAME} WITH ENCRYPTED PASSWORD '${POSTGRES_DB_PASSWORD}';" 2>/dev/null || echo "User may already exist"

# Create dhis database
psql -U postgres -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_DB_USERNAME};" 2>/dev/null || echo "Database may already exist"

echo "User and database created"
EOF

    # Create script to install extensions
    cat > init-scripts/02-install-extensions.sh << 'EOF'
#!/bin/bash
set -e

echo "Installing database extensions..."

# Install as postgres superuser
psql -U postgres -d "$POSTGRES_DB" <<-EOSQL
    -- Install PostGIS extensions
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS postgis_topology;
    CREATE EXTENSION IF NOT EXISTS postgis_raster;
    CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
    CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
    
    -- Install DHIS2 required extensions
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS btree_gin;
    
    -- Set schema permissions
    ALTER SCHEMA public OWNER TO $POSTGRES_DB_USERNAME;
    GRANT ALL PRIVILEGES ON SCHEMA public TO $POSTGRES_DB_USERNAME;
    GRANT CREATE ON SCHEMA public TO $POSTGRES_DB_USERNAME;
    
    -- Grant CREATE privilege on database
    GRANT CREATE ON DATABASE $POSTGRES_DB TO $POSTGRES_DB_USERNAME;
    
    -- Set default privileges
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public 
    GRANT ALL ON TABLES TO $POSTGRES_DB_USERNAME;
    
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public 
    GRANT ALL ON SEQUENCES TO $POSTGRES_DB_USERNAME;
    
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public 
    GRANT ALL ON FUNCTIONS TO $POSTGRES_DB_USERNAME;
    
    ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_DB_USERNAME IN SCHEMA public 
    GRANT ALL ON TYPES TO $POSTGRES_DB_USERNAME;
    
    -- Set search path
    ALTER ROLE $POSTGRES_DB_USERNAME SET search_path TO public;
    
    -- Verify installation
    SELECT 'Extensions installed successfully' as message;
    SELECT extname, extversion FROM pg_extension WHERE extname IN ('postgis', 'pg_trgm', 'btree_gin');
EOSQL

echo "Extensions installed"
EOF

    # Create metrics user script
    cat > init-scripts/03-create-metrics-user.sh << 'EOF'
#!/bin/bash
set -e

echo "Creating metrics user..."

psql -U postgres <<-EOSQL
    CREATE USER $POSTGRES_METRICS_USERNAME WITH ENCRYPTED PASSWORD '$POSTGRES_METRICS_PASSWORD';
    
    GRANT pg_monitor TO $POSTGRES_METRICS_USERNAME;
    GRANT CONNECT ON DATABASE $POSTGRES_DB TO $POSTGRES_METRICS_USERNAME;
EOSQL

echo "Metrics user created"
EOF
    
    chmod +x init-scripts/*.sh
    print_status "Init scripts created with correct passwords"
}

# Function to start database with retry logic
start_database() {
    print_status "Starting database container..."
    
    # Clean up any existing postgres volume
    docker volume rm -f dhis2-docker-deployment_postgres 2>/dev/null || true
    
    # Start database only
    if docker compose up database -d; then
        print_status "Database container started successfully"
    else
        print_error "Failed to start database with docker compose"
        return 1
    fi
    
    # Wait for database to be healthy
    if wait_for_healthy database 120; then
        print_status "Database is healthy and ready"
        return 0
    else
        print_error "Database failed to become healthy"
        return 1
    fi
}

# Function to manually install extensions after database is running (FIXED PASSWORD)
install_database_extensions() {
    print_status "Installing database extensions manually..."
    
    # Wait a bit for database to be fully ready
    print_status "Waiting for database to be fully ready..."
    sleep 5
    
    # First, ensure we can connect to postgres
    print_status "Testing database connection..."
    if ! docker compose exec -T database pg_isready -U postgres; then
        print_error "Cannot connect to database"
        return 1
    fi
    
    # Create database if it doesn't exist
    print_status "Ensuring database ${POSTGRES_DB} exists..."
    if ! check_database_exists; then
        print_status "Creating database ${POSTGRES_DB}..."
        exec_sql "CREATE DATABASE ${POSTGRES_DB};"
        sleep 2
    else
        print_status "Database ${POSTGRES_DB} already exists"
    fi
    
    # Create user if it doesn't exist (WITH CORRECT PASSWORD)
    print_status "Ensuring user ${POSTGRES_DB_USERNAME} exists..."
    if ! check_user_exists "${POSTGRES_DB_USERNAME}"; then
        print_status "Creating user ${POSTGRES_DB_USERNAME} with correct password..."
        exec_sql "CREATE USER ${POSTGRES_DB_USERNAME} WITH ENCRYPTED PASSWORD '${POSTGRES_DB_PASSWORD}';"
    else
        print_status "User ${POSTGRES_DB_USERNAME} already exists"
        # Update password if it exists but might be wrong
        print_status "Updating password for user ${POSTGRES_DB_USERNAME}..."
        exec_sql "ALTER USER ${POSTGRES_DB_USERNAME} WITH ENCRYPTED PASSWORD '${POSTGRES_DB_PASSWORD}';"
    fi
    
    # Grant privileges
    print_status "Granting privileges..."
    exec_sql "GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_DB_USERNAME};"
    exec_sql "ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_DB_USERNAME};"
    
    # Install extensions in the dhis database
    print_status "Installing PostGIS extension..."
    exec_sql "CREATE EXTENSION IF NOT EXISTS postgis;" "${POSTGRES_DB}"
    
    print_status "Installing pg_trgm extension (required by DHIS2)..."
    exec_sql "CREATE EXTENSION IF NOT EXISTS pg_trgm;" "${POSTGRES_DB}"
    
    print_status "Installing btree_gin extension..."
    exec_sql "CREATE EXTENSION IF NOT EXISTS btree_gin;" "${POSTGRES_DB}"
    
    print_status "Installing additional PostGIS extensions..."
    exec_sql "CREATE EXTENSION IF NOT EXISTS postgis_topology;" "${POSTGRES_DB}"
    exec_sql "CREATE EXTENSION IF NOT EXISTS postgis_raster;" "${POSTGRES_DB}"
    exec_sql "CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;" "${POSTGRES_DB}"
    exec_sql "CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;" "${POSTGRES_DB}"
    
    # Set schema ownership and permissions
    print_status "Setting schema permissions..."
    exec_sql "ALTER SCHEMA public OWNER TO ${POSTGRES_DB_USERNAME};" "${POSTGRES_DB}"
    exec_sql "GRANT ALL PRIVILEGES ON SCHEMA public TO ${POSTGRES_DB_USERNAME};" "${POSTGRES_DB}"
    exec_sql "GRANT CREATE ON SCHEMA public TO ${POSTGRES_DB_USERNAME};" "${POSTGRES_DB}"
    
    # Grant CREATE privilege on database
    exec_sql "GRANT CREATE ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_DB_USERNAME};" "${POSTGRES_DB}"
    
    # Set default privileges
    print_status "Setting default privileges..."
    exec_sql "
    ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_DB_USERNAME} IN SCHEMA public 
    GRANT ALL ON TABLES TO ${POSTGRES_DB_USERNAME};
    
    ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_DB_USERNAME} IN SCHEMA public 
    GRANT ALL ON SEQUENCES TO ${POSTGRES_DB_USERNAME};
    
    ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_DB_USERNAME} IN SCHEMA public 
    GRANT ALL ON FUNCTIONS TO ${POSTGRES_DB_USERNAME};
    
    ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_DB_USERNAME} IN SCHEMA public 
    GRANT ALL ON TYPES TO ${POSTGRES_DB_USERNAME};
    " "${POSTGRES_DB}"
    
    # Also set default privileges for postgres creating objects
    exec_sql "
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON TABLES TO ${POSTGRES_DB_USERNAME};
    
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON SEQUENCES TO ${POSTGRES_DB_USERNAME};
    
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON FUNCTIONS TO ${POSTGRES_DB_USERNAME};
    
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL ON TYPES TO ${POSTGRES_DB_USERNAME};
    " "${POSTGRES_DB}"
    
    # Set search path
    exec_sql "ALTER ROLE ${POSTGRES_DB_USERNAME} SET search_path TO public;" "${POSTGRES_DB}"
    
    # Create metrics user
    print_status "Creating metrics user..."
    if ! check_user_exists "${POSTGRES_METRICS_USERNAME}"; then
        exec_sql "CREATE USER ${POSTGRES_METRICS_USERNAME} WITH ENCRYPTED PASSWORD '${POSTGRES_METRICS_PASSWORD:-metrics}';"
    else
        exec_sql "ALTER USER ${POSTGRES_METRICS_USERNAME} WITH ENCRYPTED PASSWORD '${POSTGRES_METRICS_PASSWORD:-metrics}';"
    fi
    
    exec_sql "GRANT pg_monitor TO ${POSTGRES_METRICS_USERNAME};"
    exec_sql "GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_METRICS_USERNAME};"
    
    # Verify installation
    print_status "Verifying extensions..."
    exec_sql "SELECT 'Installed extensions:' as info; SELECT extname, extversion FROM pg_extension ORDER BY extname;" "${POSTGRES_DB}"
    
    print_status "Verifying pg_trgm functionality..."
    exec_sql "SELECT 'pg_trgm test:' as info, 'test' % 'test' as result;" "${POSTGRES_DB}"
    
    # Verify the dhis user can connect with correct password
    print_status "Verifying dhis user can connect with correct password..."
    if docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_DB_PASSWORD}' psql -U '${POSTGRES_DB_USERNAME}' -d '${POSTGRES_DB}' -c 'SELECT 1;'" 2>&1 | grep -q "1 row"; then
        print_status "✓ dhis user can connect with correct password"
    else
        print_error "✗ dhis user cannot connect with provided password"
        print_warning "Check that the password in .env file is correct"
        return 1
    fi
    
    print_status "Database extensions installed successfully"
    return 0
}

# Function to verify database setup
verify_database_setup() {
    print_status "Verifying database setup..."
    
    # Wait a moment for database to be fully ready
    sleep 2
    
    # Check if pg_trgm is installed
    print_status "Checking pg_trgm extension..."
    local result
    result=$(docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres -d '${POSTGRES_DB}' -t -c \"SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm';\" 2>/dev/null" | tr -d '[:space:]')
    
    if [ "$result" = "1" ]; then
        print_status "✓ pg_trgm extension is installed"
    else
        print_error "✗ pg_trgm extension is NOT installed!"
        return 1
    fi
    
    # Verify pg_trgm functionality
    print_status "Testing pg_trgm functionality..."
    if docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres -d '${POSTGRES_DB}' -t -c \"SELECT 'test' % 'test';\" 2>/dev/null" | grep -q "t"; then
        print_status "✓ pg_trgm extension is working"
    else
        print_error "✗ pg_trgm extension may not be working properly"
        return 1
    fi
    
    # Verify dhis user can connect
    print_status "Verifying dhis user authentication..."
    if docker compose exec -T database bash -c "PGPASSWORD='${POSTGRES_DB_PASSWORD}' psql -U '${POSTGRES_DB_USERNAME}' -d '${POSTGRES_DB}' -t -c 'SELECT 1;' 2>/dev/null" | tr -d '[:space:]' | grep -q "1"; then
        print_status "✓ dhis user authentication is working"
    else
        print_error "✗ dhis user authentication failed!"
        print_warning "Password mismatch between .env and database"
        return 1
    fi
    
    print_status "Database verification completed successfully"
    return 0
}

# Function to start application
start_application() {
    print_status "Starting DHIS2 application..."
    
    # Start traefik init first
    print_status "Starting traefik initialization..."
    docker compose up traefik-init -d 2>/dev/null || print_warning "Traefik init may have issues"
    sleep 3
    
    # Stop any existing app container first
    docker compose stop app 2>/dev/null || true
    docker compose rm -f app 2>/dev/null || true
    
    # Start the main services
    print_status "Starting app and traefik..."
    if docker compose up -d app traefik; then
        print_status "Application services started"
    else
        print_error "Failed to start application with docker compose"
        print_status "Trying to start services individually..."
        
        # Start services one by one
        for service in traefik app; do
            print_status "Starting $service..."
            docker compose up -d "$service" 2>/dev/null || print_warning "Failed to start $service"
            sleep 3
        done
    fi
    
    # Wait for application to be healthy
    print_status "Waiting for application to be healthy (this may take 3-5 minutes)..."
    if wait_for_healthy app 300; then
        print_status "✓ Application is healthy!"
    else
        print_warning "⚠ Application taking longer than expected to start"
        print_status "Checking application logs for errors..."
        docker compose logs app --tail=50 2>/dev/null | grep -i "error\|exception\|fail\|fatal\|cannot" || echo "No obvious errors in logs"
    fi
}

# Function to start monitoring services
start_monitoring_services() {
    print_status "Starting monitoring services..."
    
    # Wait for app to be ready before starting monitoring
    sleep 10
    
    # Start update-admin-password first (depends on app)
    print_status "Updating admin password..."
    docker compose up update-admin-password -d 2>/dev/null || print_warning "Failed to start update-admin-password"
    
    # Wait for it to complete
    sleep 15
    
    # Start create-monitoring-user
    print_status "Creating monitoring user..."
    docker compose up create-monitoring-user -d 2>/dev/null || print_warning "Failed to start create-monitoring-user"
    
    # Wait for it to complete
    sleep 15
    
    # Start monitoring services
    local services=("grafana" "prometheus" "postgres-exporter" "node-exporter" "cadvisor")
    
    for service in "${services[@]}"; do
        print_status "Starting $service..."
        docker compose up -d "$service" 2>/dev/null || print_warning "Failed to start $service"
        sleep 2
    done
    
    print_status "Monitoring services started"
}

# Function to display final information
display_final_info() {
    echo ""
    echo "==============================================="
    echo "DHIS2 Setup Complete!"
    echo "==============================================="
    echo ""
    echo "Access URLs:"
    echo "  DHIS2 Application: https://${APP_HOSTNAME}"
    echo "  Grafana:           https://grafana.${APP_HOSTNAME}"
    echo "  Traefik Dashboard: https://traefik.${APP_HOSTNAME}"
    echo "  Traefik API:       http://127.0.0.1:8080"
    echo ""
    echo "Credentials:"
    echo "  DHIS2 Admin:"
    echo "    Username: ${DHIS2_ADMIN_USERNAME}"
    echo "    Password: ${DHIS2_ADMIN_PASSWORD:-check .env file}"
    echo ""
    echo "  DHIS2 Monitor:"
    echo "    Username: ${DHIS2_MONITOR_USERNAME}"
    echo "    Password: ${DHIS2_MONITOR_PASSWORD:-check .env file}"
    echo ""
    echo "  Grafana:"
    echo "    Username: admin"
    echo "    Password: ${GRAFANA_ADMIN_PASSWORD}"
    echo ""
    echo "  Database:"
    echo "    Host: localhost:5432"
    echo "    Database: ${POSTGRES_DB}"
    echo "    Username: ${POSTGRES_DB_USERNAME}"
    echo "    Password: ${POSTGRES_DB_PASSWORD}"
    echo "    Admin user: postgres"
    echo "    Admin password: ${POSTGRES_PASSWORD}"
    echo ""
    echo "Container Status:"
    docker compose ps 2>/dev/null | head -20 || echo "  Could not get container status"
    echo ""
    echo "Useful Commands:"
    echo "  View logs:              docker compose logs -f"
    echo "  View app logs:          docker compose logs app -f"
    echo "  View database logs:     docker compose logs database -f"
    echo "  Stop all:               docker compose down"
    echo "  Restart app:            docker compose restart app"
    echo "  Check container status: docker compose ps"
    echo "  Health check:           ./healthcheck.sh"
    echo ""
    echo "Note: If you encounter certificate errors, add to /etc/hosts:"
    echo "  127.0.0.1 ${APP_HOSTNAME}"
    echo "  127.0.0.1 grafana.${APP_HOSTNAME}"
    echo "  127.0.0.1 traefik.${APP_HOSTNAME}"
    echo ""
    echo "==============================================="
}

# Function to create utility scripts
create_utility_scripts() {
    print_status "Creating utility scripts..."
    
    # Health check script
    cat > healthcheck.sh << 'EOF'
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
EOF

    # Quick fix script
    cat > quickfix.sh << 'EOF'
#!/usr/bin/env bash

echo "=== DHIS2 Quick Fix ==="

case "$1" in
    "restart")
        echo "Restarting all services..."
        docker compose restart
        echo "✓ Services restarted"
        ;;
    "database")
        echo "Restarting database..."
        docker compose restart database
        sleep 5
        echo "✓ Database restarted"
        ;;
    "app")
        echo "Restarting application..."
        docker compose restart app
        echo "✓ Application restarted"
        ;;
    "logs")
        echo "Showing recent logs..."
        docker compose logs --tail=100
        ;;
    "full")
        echo "Performing full restart..."
        docker compose down
        docker compose up -d
        echo "✓ Full restart completed"
        ;;
    *)
        echo "Usage: $0 {restart|database|app|logs|full}"
        echo ""
        echo "  restart   - Restart all services"
        echo "  database  - Restart only database"
        echo "  app       - Restart only application"
        echo "  logs      - Show recent logs"
        echo "  full      - Full restart (down then up)"
        exit 1
        ;;
esac
EOF

    chmod +x healthcheck.sh quickfix.sh
    print_status "Utility scripts created"
}

# Main execution
main() {
    echo ""
    print_status "Starting DHIS2 clean restart process..."
    echo ""
    
    # Check Docker is running
    check_docker
    
    # Load environment variables
    load_env_variables
    
    # Step 1: Clean up Docker resources
    cleanup_docker_resources
    
    # Step 2: Create init scripts with correct passwords
    create_init_scripts
    
    # Step 3: Start database
    print_status "=== Step 1: Starting Database ==="
    if ! start_database; then
        print_error "Failed to start database. Exiting."
        exit 1
    fi
    
    # Step 4: Manually install extensions with correct password
    print_status ""
    print_status "=== Step 2: Setting Up Database ==="
    if ! install_database_extensions; then
        print_error "Database setup failed. Check password in .env file."
        print_warning "Make sure POSTGRES_DB_PASSWORD in .env matches what the app expects"
        exit 1
    fi
    
    # Step 5: Verify database setup
    print_status ""
    print_status "=== Step 3: Verifying Database ==="
    if ! verify_database_setup; then
        print_error "Database verification failed. Exiting."
        exit 1
    fi
    
    # Step 6: Start application
    print_status ""
    print_status "=== Step 4: Starting Application ==="
    start_application
    
    # Step 7: Start monitoring services
    print_status ""
    print_status "=== Step 5: Starting Monitoring Services ==="
    start_monitoring_services
    
    # Step 8: Create utility scripts
    print_status ""
    print_status "=== Step 6: Creating Utility Scripts ==="
    create_utility_scripts
    
    # Step 9: Display final information
    print_status ""
    print_status "=== Step 7: Finalizing Setup ==="
    display_final_info
    
    print_status ""
    print_status "Setup process completed!"
    print_status "Run './healthcheck.sh' to verify everything is working."
    print_status ""
    print_status "If the app is still not healthy, check:"
    print_status "1. Run: docker compose logs app --tail=50"
    print_status "2. Verify password in .env file is correct"
    print_status "3. Try restarting just the app: docker compose restart app"
}

# Run main function
main "$@"
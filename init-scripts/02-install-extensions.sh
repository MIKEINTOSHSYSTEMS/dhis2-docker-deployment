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

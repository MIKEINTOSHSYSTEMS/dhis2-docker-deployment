#!/bin/bash
set -e

echo "Creating DHIS2 database and user..."

# Wait for PostgreSQL to start
until pg_isready -U postgres; do
    sleep 2
done

# Create dhis user with correct password from environment
psql -U postgres -c "CREATE USER dhis WITH ENCRYPTED PASSWORD 'uYKjkPnaUT3X7F-pA0iXkHTmad==FSrD';" 2>/dev/null || echo "User may already exist"

# Create dhis database
psql -U postgres -c "CREATE DATABASE dhis OWNER dhis;" 2>/dev/null || echo "Database may already exist"

echo "User and database created"

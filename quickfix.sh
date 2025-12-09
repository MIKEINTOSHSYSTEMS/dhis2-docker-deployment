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

#!/usr/bin/env bash

echo "Fixing line endings in .env file..."

if [ -f .env ]; then
    # Check if file has Windows line endings
    if file .env | grep -q "CRLF"; then
        echo "Converting Windows line endings to Unix..."
        
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix .env
            echo "✓ Converted using dos2unix"
        elif command -v sed >/dev/null 2>&1; then
            sed -i 's/\r$//' .env
            echo "✓ Converted using sed"
        else
            # Manual conversion
            cat .env | tr -d '\r' > .env.tmp && mv .env.tmp .env
            echo "✓ Converted using tr"
        fi
    else
        echo "✓ File already has Unix line endings"
    fi
    
    # Test loading the file
    if source .env 2>/dev/null; then
        echo "✓ .env file loads successfully"
    else
        echo "⚠ .env file still has issues, creating a clean version..."
        # Create a clean version
        cat .env | tr -d '\r' | grep -v '^#' | grep '=' > .env.clean
        mv .env .env.backup
        mv .env.clean .env
        echo "✓ Created clean .env file (backup saved as .env.backup)"
    fi
else
    echo "Error: .env file not found!"
    exit 1
fi
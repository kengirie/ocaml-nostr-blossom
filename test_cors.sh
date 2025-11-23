#!/bin/bash

# Start the server in the background
echo "Starting server..."
./_build/default/bin/main.exe &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "Testing OPTIONS (Preflight)..."
curl -v -X OPTIONS http://localhost:8082/upload 2>&1 | grep "Access-Control-Allow-Origin: *"
curl -v -X OPTIONS http://localhost:8082/upload 2>&1 | grep "Access-Control-Allow-Methods"

echo "Testing GET (CORS)..."
# Create a dummy file first
echo "test content" > test_file.txt
UPLOAD_RESP=$(curl -s -X PUT --data-binary @test_file.txt http://localhost:8082/upload)
HASH=$(echo $UPLOAD_RESP | grep -o '"sha256":"[^"]*"' | cut -d'"' -f4)

if [ -n "$HASH" ]; then
    echo "Uploaded file hash: $HASH"
    curl -v http://localhost:8082/$HASH 2>&1 | grep "Access-Control-Allow-Origin: *"
else
    echo "Upload failed, cannot test GET CORS"
fi

# Cleanup
kill $SERVER_PID
rm test_file.txt

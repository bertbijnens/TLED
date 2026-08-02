#!/bin/bash
# Serve the web installer locally for testing
# Note: Web Serial requires HTTPS, so this won't work for actual flashing
# but it's useful for testing the UI

# Use a TLED-specific port (8742) to avoid service worker collisions with
# other ESP Web Tools projects running on the same machine (e.g. localhost:8080).
PORT=8742

echo "Starting local server at http://localhost:$PORT"
echo "Note: Web Serial requires HTTPS, so flashing won't work locally"
echo "      This is just for testing the UI"
echo ""
echo "Press Ctrl+C to stop"

cd "$(dirname "$0")"
python3 -m http.server $PORT --bind 0.0.0.0

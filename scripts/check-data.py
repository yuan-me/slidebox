"""Check bookmarks and cache clearing using only a local HTTP fixture."""
import http.server
import os
from pathlib import Path
import subprocess
import threading

root = Path(__file__).resolve().parent.parent


class Fixture(http.server.BaseHTTPRequestHandler):
    cache_requests = 0

    def do_GET(self):
        if self.path == '/cached.txt':
            Fixture.cache_requests += 1
            body = str(Fixture.cache_requests).encode()
            content_type = 'text/plain'
        elif self.path == '/custom.png':
            body = (root / 'Assets/deepseek.png').read_bytes()
            content_type = 'image/png'
        else:
            body = b'<html><head><link rel="icon" href="/custom.png"></head><body>Local data check</body></html>'
            content_type = 'text/html'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'max-age=3600' if self.path == '/cached.txt' else 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(
            [str(root / 'dist/Slidebox.app/Contents/MacOS/Slidebox'), '--data-self-test'],
            env={**os.environ, 'SLIDEBOX_ICON_FIXTURE': f'http://127.0.0.1:{server.server_port}/'},
            check=True, timeout=90,
        )
    finally:
        server.shutdown()

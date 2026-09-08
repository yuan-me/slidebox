"""Build first, then run with Python 3. Checks icons and public login pages."""
import http.server
import os
from pathlib import Path
import subprocess
import threading

root = Path(__file__).resolve().parent.parent


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        icon = self.path == '/custom.png'
        body = (root / 'Assets/deepseek.png').read_bytes() if icon else b'<html><head><link rel="icon" href="/custom.png"></head><body>Icon test</body></html>'
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if icon else 'text/html')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(
            [str(root / 'dist/Slidebox.app/Contents/MacOS/Slidebox'), '--browser-self-test'],
            env={**os.environ, 'SLIDEBOX_ICON_FIXTURE': f'http://127.0.0.1:{server.server_port}/'},
            check=True, timeout=180,
        )
    finally:
        server.shutdown()

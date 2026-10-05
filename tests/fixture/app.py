"""The application the tests deploy: serves version.txt, or refuses to start when the commit carries `broken`."""

import http.server
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

if os.path.exists(os.path.join(ROOT, "broken")):
    sys.exit("broken on purpose")

with open(os.path.join(ROOT, "version.txt")) as f:
    VERSION = f.read().strip().encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(VERSION)))
        self.end_headers()
        self.wfile.write(VERSION)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()

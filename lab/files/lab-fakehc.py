"""Stand-in for healthchecks.io inside the lab: an HTTPS server that records
every ping (path and body) to /var/log/lab-fakehc.log, one line each."""
import http.server, ssl, sys, time

LOG = "/var/log/lab-fakehc.log"

class Handler(http.server.BaseHTTPRequestHandler):
    def _record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode(errors="replace") if length else ""
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} {body}\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")
    do_GET = do_POST = do_HEAD = _record
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()

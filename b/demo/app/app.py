from http.server import BaseHTTPRequestHandler, HTTPServer
import time

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            # simple Prometheus-style metrics
            metrics = [
                'demo_requests_total{path="/"} 42',
                'demo_app_info{version="1.0.0"} 1'
            ]
            body = "\n".join(metrics) + "\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"hello from demo app (ca-central-1)\n")
    def log_message(self, format, *args):
        return

def run():
    port = 8000
    server = HTTPServer(('', port), Handler)
    print(f"Starting server on :{port}")
    server.serve_forever()

if __name__ == "__main__":
    run()

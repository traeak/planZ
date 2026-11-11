# The web server of tools/nettest.sh, on the host's loopback address.
#
# usage: nettestd.py directory certificate key
#
# Serves the directory over plain HTTP on one port and over TLS 1.2 on
# one port for each cipher suite below, so each kind of record
# protection the kernel's TLS device has is used.  Prints a line
# "name port" for each as it starts listening; the ports are whatever
# is free.
import functools, http.server, ssl, sys, threading

SUITES = {
    'chacha': 'ECDHE-RSA-CHACHA20-POLY1305',
    'gcm': 'ECDHE-RSA-AES128-GCM-SHA256',
    'cbc': 'ECDHE-RSA-AES128-SHA256',
}


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass


def serve(name, directory, ctx):
    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=directory))
    if ctx is not None:
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(name, httpd.server_address[1], flush=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()


directory, cert, key = sys.argv[1:4]
serve('http', directory, None)
for name, suite in SUITES.items():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.set_ciphers(suite)
    serve(name, directory, ctx)
threading.Event().wait()

#!/usr/bin/env python3
"""Start a real pyftpdlib FTP server for integration tests.

Usage: python3 Tools/ci/ftp_test_server.py [port] [root]

The server mirrors what a PS4 FTP server exposes (plain FTP, passive mode) so the app's
`FTPClient` can be validated end-to-end against a real implementation instead of mocks.
"""
import os
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2121
ROOT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/ftproot"
os.makedirs(ROOT, exist_ok=True)

authorizer = DummyAuthorizer()
# Full read/write access on a throwaway directory.
authorizer.add_user("ps4", "ps4", ROOT, perm="elradfmwMT")
authorizer.add_anonymous(ROOT, perm="elr")

handler = FTPHandler
handler.authorizer = authorizer
handler.passive_ports = range(50000, 50050)
handler.permit_foreign_addresses = True

if __name__ == "__main__":
    print(f"FTP test server listening on 0.0.0.0:{PORT} (root {ROOT})", flush=True)
    FTPServer(("0.0.0.0", PORT), handler).serve_forever()

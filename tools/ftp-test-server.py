#!/usr/bin/env python3
# FTP / FTPS server for tools/run-tests.sh (pyftpdlib).
#
# Usage: ftp-test-server.py port root user password [--tls cert key] [--no-mlsd]
#
# --no-mlsd hides MLSD / MLST, so the client has to parse LIST output.
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer

port, root, user, password = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
args = sys.argv[5:]

authorizer = DummyAuthorizer()
authorizer.add_user(user, password, root, perm="elradfmwMT")

handler = FTPHandler
if "--tls" in args:
    i = args.index("--tls")
    handler = TLS_FTPHandler
    handler.certfile = args[i + 1]
    handler.keyfile = args[i + 2]
    handler.tls_control_required = True
    handler.tls_data_required = True

class Handler(handler):
    pass

Handler.authorizer = authorizer
Handler.passive_ports = range(40000, 40100)
if "--no-mlsd" in args:
    Handler.proto_cmds = {k: v for k, v in handler.proto_cmds.items() if k not in ("MLSD", "MLST")}

server = FTPServer(("127.0.0.1", port), Handler)
server.serve_forever()

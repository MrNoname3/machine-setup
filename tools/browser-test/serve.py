#!/usr/bin/env python3
"""The test pages on 127.0.0.1: serve.py PORT WWW-DIR MEDIA-DIR serves
WWW-DIR, and MEDIA-DIR under /media/."""
import functools, http.server, os, sys

port, www, media = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        if path.startswith("/media/"):
            return os.path.join(media, os.path.basename(path.split("?", 1)[0]))
        return super().translate_path(path)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=www)).serve_forever()

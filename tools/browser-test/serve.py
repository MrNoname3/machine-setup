#!/usr/bin/env python3
"""The test pages on 127.0.0.1: serve.py PORT WWW-DIR MEDIA-DIR serves
WWW-DIR, and MEDIA-DIR under /media/, with byte ranges, which a browser needs
to seek in a video."""
import functools, http.server, os, sys

port, www, media = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        if path.startswith("/media/"):
            return os.path.join(media, os.path.basename(path.split("?", 1)[0]))
        return super().translate_path(path)

    def send_head(self):
        rng, path = self.headers.get("Range", ""), self.translate_path(self.path)
        if not rng.startswith("bytes=") or "," in rng or not os.path.isfile(path):
            self.left = None
            return super().send_head()
        size = os.path.getsize(path)
        first, _, last = rng[6:].partition("-")
        start = int(first) if first else max(0, size - int(last))
        end = min(int(last), size - 1) if first and last else size - 1
        if start >= size:
            self.send_error(416)
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.left = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        if self.left is None:
            return super().copyfile(source, outputfile)
        while self.left > 0:
            chunk = source.read(min(1 << 16, self.left))
            if not chunk:
                break
            outputfile.write(chunk)
            self.left -= len(chunk)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=www)).serve_forever()

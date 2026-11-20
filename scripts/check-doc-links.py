"""Check local link targets in the rendered documentation site."""

import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit


class PageLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.extend(value for key, value in attrs if key == "href" and value)


def main():
    site = Path(sys.argv[1])
    base = sys.argv[2].rstrip("/")
    failed = False
    for page in sorted(site.rglob("*.html")):
        relative = page.relative_to(site).as_posix()
        page_url = f"{base}/{relative}".removesuffix("index.html")
        parser = PageLinks()
        parser.feed(page.read_text(encoding="utf-8"))
        for href in dict.fromkeys(parser.links):
            link = urlsplit(href)
            if link.scheme or link.netloc or not link.path:
                continue
            path = unquote(urlsplit(urljoin(page_url, href)).path)
            if path == base:
                path += "/"
            if not path.startswith(base + "/"):
                print(f"{relative}: {href} leaves the published site")
                failed = True
                continue
            target = site / path.removeprefix(base + "/")
            if target.is_dir():
                target /= "index.html"
            if not target.is_file():
                print(f"{relative}: {href} has no rendered target")
                failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())

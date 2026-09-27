#!/usr/bin/env python3
# Writes the Sparkle appcast for one release: the app checks
# https://github.com/selimozbas/zeonvnc/releases/latest/download/appcast.xml,
# so the newest release carries the only entry that matters.
#
# Usage: tools/make-appcast.py <dmg> <sign_update output> <min macOS> <notes.md>
import email.utils
import html
import os
import re
import sys

dmg, signature, min_os, notes_file = sys.argv[1:5]
m = re.match(r"ZeonVNC-([0-9.]+)\.dmg$", os.path.basename(dmg))
if not m:
    sys.exit(f"unexpected DMG name {dmg}")
short = m.group(1)
url = f"https://github.com/selimozbas/zeonvnc/releases/download/v{short}/{os.path.basename(dmg)}"
if not re.fullmatch(r'\s*sparkle:edSignature="[^"]+"\s+length="\d+"\s*', signature):
    sys.exit(f"unexpected sign_update output: {signature!r}")

# The CHANGELOG section as simple HTML: headings, bullet lists, paragraphs
out, in_list = [], False
for line in open(notes_file, encoding="utf-8").read().splitlines():
    text = html.escape(line.strip())
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    if line.startswith("- "):
        if not in_list:
            out.append("<ul>")
            in_list = True
        out.append("<li>" + text[2:])
    elif line.startswith("  ") and in_list and text:
        out[-1] += " " + text
    else:
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.startswith("#"):
            out.append("<h3>" + text.lstrip("#").strip() + "</h3>")
        elif text:
            out.append("<p>" + text + "</p>")
if in_list:
    out.append("</ul>")
notes = "\n".join(out).replace("]]>", "]]&gt;")

# The DMG name drops a trailing ".0" (0.4.0 -> ZeonVNC-0.4.dmg); the app has 0.4.0
version = short if short.count(".") == 2 else short + ".0"
print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ZeonVNC</title>
    <link>https://github.com/selimozbas/zeonvnc</link>
    <language>en</language>
    <item>
      <title>ZeonVNC {short}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{url}" {signature.strip()} type="application/octet-stream"/>
    </item>
  </channel>
</rss>""")

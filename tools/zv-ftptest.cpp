// Zeon Remote - FTP / FTPS check against a local server: log in, make a
// folder, upload, list, stat, download and compare, rename, delete.
//
// Usage: zv-ftptest host port user password plain|explicit|implicit localfile
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>
#include <vector>

#include "ZVFtpConnection.h"

static int failed(ZVFtpConnection& c, const char* what)
{
  printf("FAIL %s: %s\n", what, c.error().c_str());
  return 1;
}

static std::string readFile(const char* path)
{
  std::string s;
  FILE* f = fopen(path, "rb");
  if (!f)
    return s;
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
    s.append(buf, n);
  fclose(f);
  return s;
}

int main(int argc, char** argv)
{
  setvbuf(stdout, nullptr, _IOLBF, 0);
  if (argc != 7) {
    fprintf(stderr, "usage: zv-ftptest host port user password plain|explicit|implicit localfile\n");
    return 2;
  }
  std::string mode = argv[5];
  ZVFtpConnection::Security sec = mode == "explicit" ? ZVFtpConnection::ExplicitTLS
                                : mode == "implicit" ? ZVFtpConnection::ImplicitTLS
                                                     : ZVFtpConnection::Plain;
  const char* local = argv[6];
  ZVFtpConnection c;
  bool certSeen = false;
  if (!c.connect(argv[1], atoi(argv[2]), sec, [&](const std::string& id, const std::string& subject) {
        printf("certificate %s %s\n", id.c_str(), subject.c_str());
        certSeen = id.size() == 5 + 64;
        return true;
      }))
    return failed(c, "connect");
  if (sec != ZVFtpConnection::Plain && (!certSeen || !c.isSecure())) {
    printf("FAIL: no TLS\n");
    return 1;
  }

  // Wrong password first: must be reported as a login failure
  if (c.login(argv[3], std::string(argv[4]) + "x") || !c.loginFailed()) {
    printf("FAIL: a wrong password was not rejected\n");
    return 1;
  }
  printf("wrong password rejected\n");
  if (!c.isConnected() && !c.connect(argv[1], atoi(argv[2]), sec, nullptr))
    return failed(c, "reconnect");
  if (!c.login(argv[3], argv[4]))
    return failed(c, "login");

  std::string home;
  if (!c.currentDirectory(&home))
    return failed(c, "pwd");
  printf("home %s\n", home.c_str());
  std::string dir = (home == "/" ? "" : home) + "/zv test dir";
  (void)c.removeFile(dir + "/copy ç.bin");
  (void)c.removeFile(dir + "/renamed.bin");
  (void)c.removeDirectory(dir);
  if (!c.makeDirectory(dir))
    return failed(c, "mkdir");

  std::string remote = dir + "/copy ç.bin";
  int fd = open(local, O_RDONLY);
  uint64_t lastProgress = 0;
  bool ok = c.upload(fd, remote, [&](uint64_t n) { lastProgress = n; }, nullptr);
  close(fd);
  if (!ok)
    return failed(c, "upload");
  std::string original = readFile(local);
  if (lastProgress != original.size()) {
    printf("FAIL: upload progress %llu of %zu\n", (unsigned long long)lastProgress, original.size());
    return 1;
  }

  std::vector<ZVFtpConnection::Entry> entries;
  if (!c.list(dir, &entries))
    return failed(c, "list");
  bool found = false;
  for (auto& e : entries) {
    printf("  %s%s %llu %ld\n", e.name.c_str(), e.isDirectory ? "/" : "", (unsigned long long)e.size,
           (long)e.modified);
    found = found || (e.name == "copy ç.bin" && e.size == original.size() && !e.isDirectory);
  }
  if (!found) {
    printf("FAIL: uploaded file not listed with the right size\n");
    return 1;
  }

  ZVFtpConnection::Entry st;
  if (!c.stat(remote, &st) || st.size != original.size())
    return failed(c, "stat");
  if (c.stat(dir + "/missing", &st) || !c.notFound()) {
    printf("FAIL: stat of a missing file\n");
    return 1;
  }
  if (!c.stat(dir, &st) || !st.isDirectory)
    return failed(c, "stat dir");

  char tmp[] = "/tmp/zv-ftptest-XXXXXX";
  int out = mkstemp(tmp);
  ok = c.download(remote, out, nullptr, nullptr);
  close(out);
  std::string copy = readFile(tmp);
  unlink(tmp);
  if (!ok)
    return failed(c, "download");
  if (copy != original) {
    printf("FAIL: downloaded file differs (%zu bytes)\n", copy.size());
    return 1;
  }

  // A cancelled download stops and leaves the connection usable
  std::atomic<bool> cancel(false);
  out = open("/dev/null", O_WRONLY);
  ok = c.download(remote, out, [&](uint64_t) { cancel = true; }, &cancel);
  close(out);
  if (ok || !c.noop()) {
    printf("FAIL: cancelled download (ok %d, connection %s)\n", ok, c.error().c_str());
    return 1;
  }

  if (!c.rename(remote, dir + "/renamed.bin"))
    return failed(c, "rename");
  if (!c.removeFile(dir + "/renamed.bin"))
    return failed(c, "delete");
  if (!c.removeDirectory(dir))
    return failed(c, "rmdir");
  c.close();
  printf("OK %s\n", mode.c_str());
  return 0;
}

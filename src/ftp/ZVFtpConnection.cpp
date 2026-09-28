// Zeon Remote - FTP / FTPS control connection (see ZVFtpConnection.h)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include "ZVFtpConnection.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

static const int kTimeoutSeconds = 30;

static std::string sslError()
{
  unsigned long e = ERR_get_error();
  if (e == 0)
    return "TLS error";
  char buf[256];
  ERR_error_string_n(e, buf, sizeof(buf));
  ERR_clear_error();
  return buf;
}

// Connects with a timeout; returns the socket or -1 (error in *err)
static int connectTCP(const std::string& host, int port, std::string* err)
{
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo* res = nullptr;
  std::string portStr = std::to_string(port);
  int gai = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
  if (gai != 0) {
    *err = "Unknown host " + host + ": " + gai_strerror(gai);
    return -1;
  }
  int fd = -1;
  int lastErr = 0;
  for (struct addrinfo* ai = res; ai && fd < 0; ai = ai->ai_next) {
    int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s < 0)
      continue;
    int one = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int flags = fcntl(s, F_GETFL);
    fcntl(s, F_SETFL, flags | O_NONBLOCK);
    int rc = ::connect(s, ai->ai_addr, ai->ai_addrlen);
    if (rc < 0 && errno == EINPROGRESS) {
      struct pollfd p = { s, POLLOUT, 0 };
      rc = poll(&p, 1, kTimeoutSeconds * 1000);
      if (rc == 1) {
        socklen_t len = sizeof(lastErr);
        getsockopt(s, SOL_SOCKET, SO_ERROR, &lastErr, &len);
        rc = lastErr == 0 ? 0 : -1;
      } else {
        lastErr = rc == 0 ? ETIMEDOUT : errno;
        rc = -1;
      }
    } else if (rc < 0) {
      lastErr = errno;
    }
    if (rc == 0) {
      fcntl(s, F_SETFL, flags);
      struct timeval tv = { kTimeoutSeconds, 0 };
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
      setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
      fd = s;
    } else {
      ::close(s);
    }
  }
  freeaddrinfo(res);
  if (fd < 0)
    *err = "Unable to connect to " + host + ":" + portStr + ": " + strerror(lastErr);
  return fd;
}

static ssize_t sockSend(int fd, SSL* ssl, const void* data, size_t len)
{
  if (ssl) {
    int n = SSL_write(ssl, data, (int)len);
    return n > 0 ? n : -1;
  }
#ifdef MSG_NOSIGNAL
  return send(fd, data, len, MSG_NOSIGNAL);
#else
  return send(fd, data, len, 0);
#endif
}

static ssize_t sockRecv(int fd, SSL* ssl, void* data, size_t len)
{
  if (ssl) {
    int n = SSL_read(ssl, data, (int)len);
    if (n > 0)
      return n;
    int e = SSL_get_error(ssl, n);
    return e == SSL_ERROR_ZERO_RETURN ? 0 : -1;
  }
  return recv(fd, data, len, 0);
}

static bool sendBuffer(int fd, SSL* ssl, const char* data, size_t len)
{
  while (len > 0) {
    ssize_t n = sockSend(fd, ssl, data, len);
    if (n <= 0) {
      if (n < 0 && !ssl && errno == EINTR)
        continue;
      return false;
    }
    data += n;
    len -= (size_t)n;
  }
  return true;
}

// "20240131120000[.123]" (UTC) -> time_t
static time_t parseTimestamp(const std::string& s)
{
  if (s.size() < 14)
    return 0;
  struct tm t;
  memset(&t, 0, sizeof(t));
  if (sscanf(s.c_str(), "%4d%2d%2d%2d%2d%2d", &t.tm_year, &t.tm_mon, &t.tm_mday,
             &t.tm_hour, &t.tm_min, &t.tm_sec) != 6)
    return 0;
  t.tm_year -= 1900;
  t.tm_mon -= 1;
  return timegm(&t);
}

ZVFtpConnection::ZVFtpConnection()
  : fd_(-1), ctx_(nullptr), ssl_(nullptr), lastCode_(0), loginFailed_(false),
    hasMLSD_(false), hasMLST_(false), hasEPSV_(true), hasMFMT_(false), utf8_(false)
{
}

ZVFtpConnection::~ZVFtpConnection()
{
  close();
}

bool ZVFtpConnection::fail(const std::string& message)
{
  error_ = message;
  return false;
}

void ZVFtpConnection::close()
{
  if (ssl_) {
    SSL_shutdown(ssl_);
    SSL_free(ssl_);
    ssl_ = nullptr;
  }
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
  if (ctx_) {
    SSL_CTX_free(ctx_);
    ctx_ = nullptr;
  }
  rbuf_.clear();
}

bool ZVFtpConnection::sendAll(const std::string& data)
{
  if (fd_ < 0)
    return fail("Not connected");
  if (!sendBuffer(fd_, ssl_, data.data(), data.size())) {
    close();
    return fail("The connection was closed");
  }
  return true;
}

bool ZVFtpConnection::readLine(std::string* line)
{
  for (;;) {
    size_t nl = rbuf_.find('\n');
    if (nl != std::string::npos) {
      *line = rbuf_.substr(0, nl);
      rbuf_.erase(0, nl + 1);
      if (!line->empty() && line->back() == '\r')
        line->pop_back();
      return true;
    }
    char buf[4096];
    ssize_t n = sockRecv(fd_, ssl_, buf, sizeof(buf));
    if (n <= 0) {
      close();
      return fail(n == 0 ? "The server closed the connection" : "No answer from the server");
    }
    rbuf_.append(buf, (size_t)n);
  }
}

bool ZVFtpConnection::readReply(int* code, std::string* text)
{
  std::string line;
  if (!readLine(&line))
    return false;
  if (line.size() < 3 || !isdigit((unsigned char)line[0]))
    return fail("Unexpected answer from the server: " + line);
  std::string all = line;
  if (line.size() > 3 && line[3] == '-') {
    std::string end = line.substr(0, 3) + " ";
    do {
      if (!readLine(&line))
        return false;
      all += "\n" + line;
    } while (line.compare(0, 4, end) != 0);
  }
  lastCode_ = atoi(all.substr(0, 3).c_str());
  if (code)
    *code = lastCode_;
  if (text)
    *text = all;
  return true;
}

bool ZVFtpConnection::command(const std::string& cmd, int* code, std::string* text)
{
  int c = 0;
  std::string t;
  if (!sendAll(cmd + "\r\n") || !readReply(&c, &t))
    return false;
  if (code)
    *code = c;
  if (text)
    *text = t;
  if (c >= 400) {
    std::string msg = t.size() > 4 ? t.substr(4) : t;
    error_ = msg;
  }
  return c < 400;
}

bool ZVFtpConnection::connect(const std::string& host, int port, Security security, VerifyFn verify)
{
  close();
  loginFailed_ = false;
  std::string err;
  fd_ = connectTCP(host, port, &err);
  if (fd_ < 0)
    return fail(err);

  // Data connections go to the address of the control connection
  struct sockaddr_storage ss;
  socklen_t len = sizeof(ss);
  char addr[INET6_ADDRSTRLEN] = "";
  if (getpeername(fd_, (struct sockaddr*)&ss, &len) == 0) {
    if (ss.ss_family == AF_INET)
      inet_ntop(AF_INET, &((struct sockaddr_in*)&ss)->sin_addr, addr, sizeof(addr));
    else if (ss.ss_family == AF_INET6)
      inet_ntop(AF_INET6, &((struct sockaddr_in6*)&ss)->sin6_addr, addr, sizeof(addr));
  }
  host_ = addr[0] ? addr : host;

  if (security == ImplicitTLS && !startTLS(host, verify))
    return false;

  int code;
  std::string text;
  if (!readReply(&code, &text))
    return false;
  if (code != 220) {
    close();
    return fail("The server refused the connection: " + text);
  }
  welcome_ = text;

  if (security == ExplicitTLS) {
    if (!command("AUTH TLS", &code, &text)) {
      close();
      return fail("The server does not support FTPS (AUTH TLS): " + text);
    }
    if (!startTLS(host, verify))
      return false;
  }
  if (ssl_) {
    // Encrypt the data connections too
    if (!command("PBSZ 0") || !command("PROT P")) {
      std::string e = error_;
      close();
      return fail("The server refused encrypted data connections: " + e);
    }
  }
  return true;
}

bool ZVFtpConnection::startTLS(const std::string& host, VerifyFn verify)
{
  ctx_ = SSL_CTX_new(TLS_client_method());
  if (!ctx_) {
    close();
    return fail(sslError());
  }
  // Older NAS boxes still speak TLS 1.0; trust comes from the certificate
  // fingerprint the user accepted, not from the CA chain
  SSL_CTX_set_min_proto_version(ctx_, TLS1_VERSION);
  SSL_CTX_set_security_level(ctx_, 1);
  SSL_CTX_set_session_cache_mode(ctx_, SSL_SESS_CACHE_CLIENT);
  ssl_ = SSL_new(ctx_);
  SSL_set_fd(ssl_, fd_);
  if (!host.empty() && !isdigit((unsigned char)host[0]) && host.find(':') == std::string::npos)
    SSL_set_tlsext_host_name(ssl_, host.c_str());
  if (SSL_connect(ssl_) != 1) {
    std::string e = sslError();
    SSL_free(ssl_);
    ssl_ = nullptr;
    close();
    return fail("TLS handshake failed: " + e);
  }

  X509* cert = SSL_get1_peer_certificate(ssl_);
  if (!cert) {
    close();
    return fail("The server sent no certificate");
  }
  unsigned char* der = nullptr;
  int derLen = i2d_X509(cert, &der);
  unsigned char md[EVP_MAX_MD_SIZE];
  unsigned int mdLen = 0;
  EVP_Digest(der, (size_t)derLen, md, &mdLen, EVP_sha256(), nullptr);
  OPENSSL_free(der);
  char subject[512];
  X509_NAME_oneline(X509_get_subject_name(cert), subject, sizeof(subject));
  X509_free(cert);

  std::string identity = "x509:";
  static const char* hex = "0123456789abcdef";
  for (unsigned i = 0; i < mdLen; i++) {
    identity += hex[md[i] >> 4];
    identity += hex[md[i] & 15];
  }
  if (verify && !verify(identity, subject)) {
    close();
    return fail("The server's certificate was not accepted.");
  }
  return true;
}

bool ZVFtpConnection::login(const std::string& user, const std::string& password)
{
  loginFailed_ = false;
  int code;
  std::string text;
  std::string u = user.empty() ? "anonymous" : user;
  if (!command("USER " + u, &code, &text)) {
    loginFailed_ = code == 530;
    return false;
  }
  if (code == 331 || code == 332) {
    if (!command("PASS " + password, &code, &text)) {
      loginFailed_ = code == 530 || code == 430;
      return false;
    }
  }
  if (code != 230 && code != 202)
    return fail("Login failed: " + text);

  if (command("FEAT", &code, &text)) {
    std::string upper = text;
    std::transform(upper.begin(), upper.end(), upper.begin(), ::toupper);
    hasMLSD_ = upper.find("\n MLSD") != std::string::npos || upper.find("\nMLSD") != std::string::npos ||
               upper.find(" MLST") != std::string::npos;
    hasMLST_ = upper.find(" MLST") != std::string::npos;
    hasMFMT_ = upper.find(" MFMT") != std::string::npos;
    utf8_ = upper.find(" UTF8") != std::string::npos;
  }
  if (utf8_)
    (void)command("OPTS UTF8 ON");
  if (!command("TYPE I"))
    return false;
  return true;
}

bool ZVFtpConnection::noop()
{
  return command("NOOP");
}

bool ZVFtpConnection::currentDirectory(std::string* path)
{
  int code;
  std::string text;
  if (!command("PWD", &code, &text))
    return false;
  size_t a = text.find('"');
  if (a == std::string::npos) {
    *path = "/";
    return true;
  }
  std::string p;
  for (size_t i = a + 1; i < text.size(); i++) {
    if (text[i] == '"') {
      if (i + 1 < text.size() && text[i + 1] == '"') {
        p += '"';
        i++;
        continue;
      }
      break;
    }
    p += text[i];
  }
  *path = p.empty() ? "/" : p;
  return true;
}

// Opens a passive data connection and sends cmd (RETR, STOR, MLSD, LIST).
// Returns the data socket after the server's preliminary reply, or -1.
int ZVFtpConnection::openData(const std::string& cmd, SSL** dataSsl, int* code)
{
  *dataSsl = nullptr;
  int port = -1;
  int c;
  std::string text;
  if (hasEPSV_) {
    if (command("EPSV", &c, &text)) {
      size_t a = text.find("(|||");
      if (a != std::string::npos)
        port = atoi(text.c_str() + a + 4);
    } else if (fd_ < 0) {
      return -1;
    } else {
      hasEPSV_ = false;
    }
  }
  if (port <= 0) {
    if (!command("PASV", &c, &text))
      return -1;
    size_t a = text.find('(');
    int h1, h2, h3, h4, p1, p2;
    if (a == std::string::npos ||
        sscanf(text.c_str() + a + 1, "%d,%d,%d,%d,%d,%d", &h1, &h2, &h3, &h4, &p1, &p2) != 6) {
      fail("Unexpected passive mode answer: " + text);
      return -1;
    }
    port = p1 * 256 + p2;   // the address given is ignored (NAT)
  }

  std::string err;
  int dfd = connectTCP(host_, port, &err);
  if (dfd < 0) {
    fail("Unable to open the data connection: " + err);
    return -1;
  }
  if (!command(cmd, &c, &text) || (c != 125 && c != 150)) {
    if (code)
      *code = c;
    ::close(dfd);
    if (c < 400)
      fail("Unexpected answer: " + text);
    return -1;
  }
  if (ssl_) {
    SSL* s = SSL_new(ctx_);
    SSL_set_fd(s, dfd);
    // Many servers require the data connection to resume the control
    // connection's TLS session
    SSL_SESSION* session = SSL_get1_session(ssl_);
    if (session) {
      SSL_set_session(s, session);
      SSL_SESSION_free(session);
    }
    if (SSL_connect(s) != 1) {
      fail("TLS on the data connection failed: " + sslError());
      SSL_free(s);
      ::close(dfd);
      int ignored;
      (void)readReply(&ignored, nullptr);
      return -1;
    }
    *dataSsl = s;
  }
  return dfd;
}

bool ZVFtpConnection::finishData(int dfd, SSL* dataSsl, bool writing)
{
  if (writing) {
    // Tell the server the file is complete, then wait for it to close: the
    // server may have sent data we haven't read (TLS session tickets), and
    // closing with unread data resets the connection, which can lose the
    // end of the file
    if (dataSsl)
      SSL_shutdown(dataSsl);
    ::shutdown(dfd, SHUT_WR);
    char drain[4096];
    while (recv(dfd, drain, sizeof(drain), 0) > 0) {
    }
  }
  if (dataSsl)
    SSL_free(dataSsl);
  ::close(dfd);
  int code;
  std::string text;
  if (!readReply(&code, &text))
    return false;
  if (code >= 400)
    return fail(text.size() > 4 ? text.substr(4) : text);
  return true;
}

bool ZVFtpConnection::list(const std::string& path, std::vector<Entry>* entries)
{
  entries->clear();
  SSL* ds;
  int code = 0;
  bool mlsd = hasMLSD_;
  int dfd = openData(std::string(mlsd ? "MLSD " : "LIST -a ") + path, &ds, &code);
  if (dfd < 0 && !mlsd && code >= 500 && fd_ >= 0)
    dfd = openData("LIST " + path, &ds, &code);
  if (dfd < 0)
    return false;

  std::string data;
  char buf[16384];
  for (;;) {
    ssize_t n = sockRecv(dfd, ds, buf, sizeof(buf));
    if (n <= 0)
      break;
    data.append(buf, (size_t)n);
  }
  if (!finishData(dfd, ds, false))
    return false;

  size_t pos = 0;
  while (pos < data.size()) {
    size_t nl = data.find('\n', pos);
    std::string line = data.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
    pos = nl == std::string::npos ? data.size() : nl + 1;
    if (!line.empty() && line.back() == '\r')
      line.pop_back();
    Entry e;
    if ((mlsd ? parseMLSD(line, &e) : parseLIST(line, &e)) && e.name != "." && e.name != "..")
      entries->push_back(e);
  }
  return true;
}

bool ZVFtpConnection::parseMLSD(const std::string& line, Entry* e)
{
  size_t sp = line.find(' ');
  if (sp == std::string::npos)
    return false;
  e->name = line.substr(sp + 1);
  std::string facts = line.substr(0, sp);
  std::string type;
  size_t i = 0;
  while (i < facts.size()) {
    size_t semi = facts.find(';', i);
    std::string fact = facts.substr(i, semi == std::string::npos ? std::string::npos : semi - i);
    i = semi == std::string::npos ? facts.size() : semi + 1;
    size_t eq = fact.find('=');
    if (eq == std::string::npos)
      continue;
    std::string key = fact.substr(0, eq), value = fact.substr(eq + 1);
    std::transform(key.begin(), key.end(), key.begin(), ::tolower);
    if (key == "type") {
      type = value;
      std::transform(type.begin(), type.end(), type.begin(), ::tolower);
    } else if (key == "size" || key == "sizd") {
      e->size = strtoull(value.c_str(), nullptr, 10);
    } else if (key == "modify") {
      e->modified = parseTimestamp(value);
    } else if (key == "unix.mode") {
      e->permissions = (unsigned)strtoul(value.c_str(), nullptr, 8);
    }
  }
  if (type == "cdir" || type == "pdir")
    return false;
  e->isDirectory = type == "dir";
  e->isLink = type.find("symlink") != std::string::npos || type.find("slink") != std::string::npos;
  if (e->isLink && type.find("dir") != std::string::npos)
    e->isDirectory = true;
  return !e->name.empty();
}

// Unix ("drwxr-xr-x 2 user group 4096 Jan  1 12:00 name") and DOS / IIS
// ("01-31-24  03:15PM  <DIR>  name") directory listings
bool ZVFtpConnection::parseLIST(const std::string& line, Entry* e)
{
  if (line.empty() || line.compare(0, 5, "total") == 0)
    return false;

  // Split off the first n whitespace separated fields
  auto fields = [&](int n, std::vector<std::string>* out, size_t* rest) {
    size_t i = 0;
    for (int f = 0; f < n; f++) {
      while (i < line.size() && isspace((unsigned char)line[i])) i++;
      size_t start = i;
      while (i < line.size() && !isspace((unsigned char)line[i])) i++;
      if (start == i)
        return false;
      out->push_back(line.substr(start, i - start));
    }
    if (i < line.size())
      i++;   // one separating space; names may start with more
    *rest = i;
    return true;
  };

  std::vector<std::string> f;
  size_t rest = 0;
  if (isdigit((unsigned char)line[0])) {
    if (!fields(3, &f, &rest))
      return false;
    while (rest < line.size() && line[rest] == ' ') rest++;
    e->name = line.substr(rest);
    e->isDirectory = f[2] == "<DIR>";
    if (!e->isDirectory)
      e->size = strtoull(f[2].c_str(), nullptr, 10);
    int mo, d, y, h, mi;
    char ampm[3] = "";
    if (sscanf(f[0].c_str(), "%d-%d-%d", &mo, &d, &y) == 3 &&
        sscanf(f[1].c_str(), "%d:%d%2s", &h, &mi, ampm) >= 2) {
      struct tm t;
      memset(&t, 0, sizeof(t));
      t.tm_year = (y < 70 ? y + 2000 : y < 100 ? y + 1900 : y) - 1900;
      t.tm_mon = mo - 1;
      t.tm_mday = d;
      if ((ampm[0] == 'P' || ampm[0] == 'p') && h < 12) h += 12;
      if ((ampm[0] == 'A' || ampm[0] == 'a') && h == 12) h = 0;
      t.tm_hour = h;
      t.tm_min = mi;
      t.tm_isdst = -1;
      e->modified = mktime(&t);
    }
    return !e->name.empty();
  }

  if (!fields(8, &f, &rest))
    return false;
  const std::string& perms = f[0];
  if (perms.size() < 10)
    return false;
  e->isDirectory = perms[0] == 'd';
  e->isLink = perms[0] == 'l';
  unsigned mode = 0;
  for (int i = 0; i < 9; i++)
    if (perms[1 + i] != '-')
      mode |= 1u << (8 - i);
  e->permissions = mode;
  e->size = strtoull(f[4].c_str(), nullptr, 10);
  e->name = line.substr(rest);
  if (e->isLink) {
    size_t arrow = e->name.find(" -> ");
    if (arrow != std::string::npos)
      e->name = e->name.substr(0, arrow);
  }

  static const char* months[] = { "jan", "feb", "mar", "apr", "may", "jun",
                                  "jul", "aug", "sep", "oct", "nov", "dec" };
  std::string mon = f[5];
  std::transform(mon.begin(), mon.end(), mon.begin(), ::tolower);
  int m = -1;
  for (int i = 0; i < 12; i++)
    if (mon.compare(0, 3, months[i]) == 0)
      m = i;
  if (m >= 0) {
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_mon = m;
    t.tm_mday = atoi(f[6].c_str());
    t.tm_isdst = -1;
    time_t now = time(nullptr);
    struct tm today;
    localtime_r(&now, &today);
    if (f[7].find(':') != std::string::npos) {
      // "12:00": within the last year
      sscanf(f[7].c_str(), "%d:%d", &t.tm_hour, &t.tm_min);
      t.tm_year = today.tm_year;
      if (m > today.tm_mon + 1)
        t.tm_year--;
    } else {
      t.tm_year = atoi(f[7].c_str()) - 1900;
    }
    e->modified = mktime(&t);
  }
  return !e->name.empty();
}

bool ZVFtpConnection::stat(const std::string& path, Entry* entry)
{
  int code;
  std::string text;
  if (hasMLST_) {
    if (!command("MLST " + path, &code, &text))
      return false;
    // 250-Listing path\n type=file;size=1; path\n250 End
    size_t a = text.find('\n');
    while (a != std::string::npos) {
      size_t b = text.find('\n', a + 1);
      std::string line = text.substr(a + 1, b == std::string::npos ? std::string::npos : b - a - 1);
      if (!line.empty() && line[0] == ' ' && parseMLSD(line.substr(1), entry)) {
        size_t slash = path.find_last_of('/');
        entry->name = slash == std::string::npos ? path : path.substr(slash + 1);
        return true;
      }
      a = b;
    }
    return fail("Unexpected MLST answer");
  }

  // Without MLST: look the name up in its folder
  size_t slash = path.find_last_of('/');
  std::string dir = slash == std::string::npos ? "." : (slash == 0 ? "/" : path.substr(0, slash));
  std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
  std::vector<Entry> entries;
  if (!list(dir, &entries))
    return false;
  for (auto& e : entries) {
    if (e.name == name) {
      *entry = e;
      return true;
    }
  }
  lastCode_ = 550;
  return fail("No such file or folder");
}

bool ZVFtpConnection::download(const std::string& path, int fd, ProgressFn progress,
                               const std::atomic<bool>* cancel)
{
  SSL* ds;
  int dfd = openData("RETR " + path, &ds, nullptr);
  if (dfd < 0)
    return false;
  std::vector<char> buf(256 * 1024);
  uint64_t done = 0;
  bool ok = true;
  for (;;) {
    if (cancel && *cancel) {
      ok = false;
      error_ = "Cancelled";
      break;
    }
    ssize_t n = sockRecv(dfd, ds, buf.data(), buf.size());
    if (n < 0) {
      ok = false;
      error_ = "The data connection broke";
      break;
    }
    if (n == 0)
      break;
    const char* p = buf.data();
    ssize_t left = n;
    while (left > 0) {
      ssize_t w = ::write(fd, p, (size_t)left);
      if (w <= 0) {
        ok = false;
        error_ = std::string("Unable to write the file: ") + strerror(errno);
        break;
      }
      p += w;
      left -= w;
    }
    if (!ok)
      break;
    done += (uint64_t)n;
    if (progress)
      progress(done);
  }
  std::string err = error_;
  bool finished = finishData(dfd, ds, false);
  if (!ok) {
    error_ = err;
    return false;
  }
  return finished;
}

bool ZVFtpConnection::upload(int fd, const std::string& path, ProgressFn progress,
                             const std::atomic<bool>* cancel)
{
  SSL* ds;
  int dfd = openData("STOR " + path, &ds, nullptr);
  if (dfd < 0)
    return false;
  std::vector<char> buf(256 * 1024);
  uint64_t done = 0;
  bool ok = true;
  for (;;) {
    if (cancel && *cancel) {
      ok = false;
      error_ = "Cancelled";
      break;
    }
    ssize_t n = ::read(fd, buf.data(), buf.size());
    if (n < 0) {
      ok = false;
      error_ = std::string("Unable to read the file: ") + strerror(errno);
      break;
    }
    if (n == 0)
      break;
    if (!sendBuffer(dfd, ds, buf.data(), (size_t)n)) {
      ok = false;
      error_ = "The data connection broke";
      break;
    }
    done += (uint64_t)n;
    if (progress)
      progress(done);
  }
  std::string err = error_;
  bool finished = finishData(dfd, ds, true);
  if (!ok) {
    error_ = err;
    return false;
  }
  return finished;
}

bool ZVFtpConnection::makeDirectory(const std::string& path)
{
  return command("MKD " + path);
}

bool ZVFtpConnection::removeDirectory(const std::string& path)
{
  return command("RMD " + path);
}

bool ZVFtpConnection::removeFile(const std::string& path)
{
  return command("DELE " + path);
}

bool ZVFtpConnection::rename(const std::string& from, const std::string& to)
{
  int code = 0;
  if (!command("RNFR " + from, &code))
    return false;
  if (code != 350)
    return fail("Unexpected answer to RNFR");
  return command("RNTO " + to);
}

bool ZVFtpConnection::setModified(const std::string& path, time_t when)
{
  if (!hasMFMT_ || when <= 0)
    return false;
  struct tm t;
  gmtime_r(&when, &t);
  char stamp[32];
  strftime(stamp, sizeof(stamp), "%Y%m%d%H%M%S", &t);
  return command(std::string("MFMT ") + stamp + " " + path);
}

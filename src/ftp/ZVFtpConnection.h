// Zeon Remote - FTP / FTPS control connection. Plain C++ on POSIX sockets
// and OpenSSL, so the headless test client also builds on Linux.
//
// All calls block; use one connection per thread (the app runs it on a
// serial queue). Recursive transfers, conflicts and progress are built on
// top of this in ZVFTPClient.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#ifndef __ZV_FTP_CONNECTION_H__
#define __ZV_FTP_CONNECTION_H__

#include <stdint.h>
#include <time.h>

#include <atomic>
#include <functional>
#include <string>
#include <vector>

typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_session_st SSL_SESSION;

class ZVFtpConnection {
public:
  enum Security {
    Plain,          // no encryption
    ExplicitTLS,    // AUTH TLS on the normal port (FTPES), the usual FTPS
    ImplicitTLS,    // TLS from the first byte (port 990)
  };

  struct Entry {
    std::string name;
    bool isDirectory = false;
    bool isLink = false;
    uint64_t size = 0;
    time_t modified = 0;      // 0 = unknown
    unsigned permissions = 0; // 0 = unknown
  };

  // Called after the TLS handshake and before the user name and password
  // are sent. identity is "x509:<sha256 of the certificate>". Return true
  // to continue.
  typedef std::function<bool(const std::string& identity, const std::string& subject)> VerifyFn;
  // Bytes transferred so far in the current file
  typedef std::function<void(uint64_t bytes)> ProgressFn;

  ZVFtpConnection();
  ~ZVFtpConnection();

  bool connect(const std::string& host, int port, Security security, VerifyFn verify);
  // false with loginFailed() when the server rejected the credentials
  bool login(const std::string& user, const std::string& password);
  void close();

  bool isConnected() const { return fd_ >= 0; }
  bool isSecure() const { return ssl_ != nullptr; }
  bool loginFailed() const { return loginFailed_; }
  // Peer address of the control connection (for the device's MAC address)
  int controlSocket() const { return fd_; }

  const std::string& error() const { return error_; }
  const std::string& welcome() const { return welcome_; }

  bool currentDirectory(std::string* path);
  bool list(const std::string& path, std::vector<Entry>* entries);
  // Information about one path; false with notFound() when it doesn't exist
  bool stat(const std::string& path, Entry* entry);
  bool notFound() const { return lastCode_ == 550 || lastCode_ == 450; }

  bool download(const std::string& path, int fd, ProgressFn progress,
                const std::atomic<bool>* cancel);
  bool upload(int fd, const std::string& path, ProgressFn progress,
              const std::atomic<bool>* cancel);

  bool makeDirectory(const std::string& path);
  bool removeDirectory(const std::string& path);
  bool removeFile(const std::string& path);
  bool rename(const std::string& from, const std::string& to);
  bool setModified(const std::string& path, time_t when);

  // Keeps an idle connection open
  bool noop();

private:
  bool command(const std::string& cmd, int* code = nullptr, std::string* text = nullptr);
  bool readReply(int* code, std::string* text);
  bool readLine(std::string* line);
  bool sendAll(const std::string& data);
  bool startTLS(const std::string& host, VerifyFn verify);
  int openData(const std::string& cmd, SSL** dataSsl, int* code);
  bool finishData(int dfd, SSL* dataSsl, bool writing);
  bool fail(const std::string& message);

  static bool parseMLSD(const std::string& line, Entry* e);
  static bool parseLIST(const std::string& line, Entry* e);

  int fd_;
  SSL_CTX* ctx_;
  SSL* ssl_;
  std::string host_;
  std::string rbuf_;
  std::string error_;
  std::string welcome_;
  int lastCode_;
  bool loginFailed_;
  bool hasMLSD_;
  bool hasMLST_;
  bool hasEPSV_;
  bool hasMFMT_;
  bool utf8_;
};

#endif

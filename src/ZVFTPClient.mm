// Zeon Remote - FTP and FTPS client (see ZVFTPClient.h)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#import "ZVFTPClient.h"
#import "ZVNetUtil.h"
#include "ftp/ZVFtpConnection.h"

static NSString* const kErrorDomain = @"ZeonRemote.FTP";

// File names are sent in the composed form Linux and most servers expect
static std::string remoteName(NSString* name)
{
  return name.precomposedStringWithCanonicalMapping.UTF8String ?: "";
}

static std::string joinPath(const std::string& dir, const std::string& name)
{
  if (dir.empty() || dir == "/")
    return "/" + name;
  if (dir.back() == '/')
    return dir + name;
  return dir + "/" + name;
}

static NSString* nsstr(const std::string& s)
{
  NSString* r = [NSString stringWithUTF8String:s.c_str()];
  if (!r)
    r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSISOLatin1StringEncoding];
  return r ?: @"";
}

@implementation ZVFTPClient {
  dispatch_queue_t _queue;
  std::unique_ptr<ZVFtpConnection> _conn;   // queue only
  std::atomic<bool> _cancel;
  NSString* _usedPassword;                  // queue only, for reconnecting
  NSString* _host;
  NSString* _homeDirectory;
  NSString* _deviceMAC;
  NSString* _hostKeyFingerprint;
  NSString* _passwordToRemember;
}

@synthesize conflictHandler = _conflictHandler;

- (instancetype)initWithHost:(NSString*)host port:(int)port security:(ZVFTPSecurity)security
{
  self = [super init];
  if (self) {
    _host = [host copy];
    _port = port > 0 ? port : (security == ZVFTPImplicitTLS ? 990 : 21);
    _security = security;
    _queue = dispatch_queue_create("com.zeonremote.ftp", DISPATCH_QUEUE_SERIAL);
    _conn.reset(new ZVFtpConnection());
    _cancel = false;
  }
  return self;
}

- (NSString*)host { return _host; }
- (NSString*)homeDirectory { return _homeDirectory; }
- (NSString*)deviceMAC { return _deviceMAC; }
- (NSString*)hostKeyFingerprint { return _hostKeyFingerprint; }
- (NSString*)passwordToRemember { return _passwordToRemember; }

- (void)onMain:(dispatch_block_t)block
{
  dispatch_async(dispatch_get_main_queue(), block);
}

- (NSError*)errorWithMessage:(NSString*)message
{
  return [NSError errorWithDomain:kErrorDomain code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSError*)connectionError:(NSString*)what
{
  NSString* detail = nsstr(_conn->error());
  return [self errorWithMessage:detail.length ? [NSString stringWithFormat:@"%@: %@", what, detail] : what];
}

- (NSError*)cancelledError
{
  return [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
}

#pragma mark Connection (queue)

- (ZVFtpConnection::Security)connectionSecurity
{
  switch (_security) {
  case ZVFTPExplicitTLS: return ZVFtpConnection::ExplicitTLS;
  case ZVFTPImplicitTLS: return ZVFtpConnection::ImplicitTLS;
  default:               return ZVFtpConnection::Plain;
  }
}

- (BOOL)openOnQueue:(NSError**)error
{
  __weak ZVFTPClient* weakSelf = self;
  NSString* identity = nil;   // captured by reference: not __block (lambda)
  bool ok = _conn->connect(_host.UTF8String ?: "", _port, [self connectionSecurity],
                           [weakSelf, &identity](const std::string& ident, const std::string& subject) {
    ZVFTPClient* s = weakSelf;
    if (!s)
      return false;
    identity = nsstr(ident);
    NSString* subj = nsstr(subject);
    __block BOOL trusted = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      trusted = [s.delegate ftpClient:s trustCertificate:identity subject:subj];
    });
    return trusted ? true : false;
  });
  if (!ok) {
    *error = identity && !_conn->isConnected() && _conn->error().find("not accepted") != std::string::npos
               ? [self cancelledError]
               : [self connectionError:[NSString stringWithFormat:@"Unable to connect to %@", _host]];
    return NO;
  }
  _hostKeyFingerprint = identity;
  if (!_deviceMAC)
    _deviceMAC = ZVMACAddressOfPeer(_conn->controlSocket());
  return YES;
}

- (BOOL)connectOnQueue:(NSError**)error
{
  if (![self openOnQueue:error])
    return NO;

  NSString* user = _username;
  NSMutableArray<NSString*>* candidates = [NSMutableArray array];
  if (_offeredPassword.length)
    [candidates addObject:_offeredPassword];
  if (user.length && [self.delegate respondsToSelector:@selector(ftpClientSavedPassword:)]) {
    __block NSString* saved = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ saved = [self.delegate ftpClientSavedPassword:self]; });
    if (saved.length && ![candidates containsObject:saved])
      [candidates addObject:saved];
  }
  if ([user isEqualToString:@"anonymous"] || [user isEqualToString:@"ftp"])
    [candidates addObject:@"zeonremote@"];

  BOOL failed = NO;
  for (;;) {
    NSString* password = nil;
    BOOL remember = NO;
    if (user.length && candidates.count) {
      password = candidates.firstObject;
      [candidates removeObjectAtIndex:0];
    } else {
      __block NSString* u = user;
      __block NSString* p = nil;
      __block BOOL r = NO;
      __block BOOL ok = NO;
      BOOL f = failed;
      dispatch_sync(dispatch_get_main_queue(), ^{
        ok = [self.delegate ftpClient:self wantsPasswordForUser:&u password:&p remember:&r failed:f];
      });
      if (!ok) {
        _conn->close();
        *error = [self cancelledError];
        return NO;
      }
      user = u;
      password = p ?: @"";
      remember = r;
    }

    if (!_conn->isConnected() && ![self openOnQueue:error])
      return NO;
    if (_conn->login(user.UTF8String ?: "", password.UTF8String ?: "")) {
      _username = user;
      _usedPassword = password;
      _passwordToRemember = remember ? password : nil;
      break;
    }
    if (!_conn->loginFailed()) {
      *error = [self connectionError:@"Login failed"];
      _conn->close();
      return NO;
    }
    failed = YES;
  }

  std::string home;
  _homeDirectory = _conn->currentDirectory(&home) ? nsstr(home) : @"/";
  return YES;
}

// Runs a block on the queue after making sure we're connected; an idle
// connection the server closed is reopened with the same login
- (void)withConnection:(void (^)(NSError* error))block
{
  dispatch_async(_queue, ^{
    NSError* error = nil;
    if (self->_conn->isConnected() && !self->_conn->noop())
      self->_conn->close();
    if (!self->_conn->isConnected()) {
      if (self->_usedPassword) {
        if ([self openOnQueue:&error] &&
            !self->_conn->login(self->_username.UTF8String ?: "", self->_usedPassword.UTF8String ?: ""))
          error = [self connectionError:@"Login failed"];
      } else {
        [self connectOnQueue:&error];
      }
    }
    block(error);
  });
}

- (BOOL)isConnected
{
  return _homeDirectory != nil;
}

- (void)connect:(void (^)(NSError*))completion
{
  dispatch_async(_queue, ^{
    NSError* error = nil;
    if (!self->_conn->isConnected())
      [self connectOnQueue:&error];
    [self onMain:^{ completion(error); }];
  });
}

- (void)disconnect
{
  _cancel = true;
  dispatch_async(_queue, ^{
    self->_conn->close();
  });
}

- (void)cancelTransfer
{
  _cancel = true;
}

#pragma mark Listing

- (NSArray<ZVRemoteFile*>*)listOnQueue:(const std::string&)path error:(NSError**)error
{
  std::vector<ZVFtpConnection::Entry> entries;
  if (!_conn->list(path, &entries)) {
    *error = [self connectionError:@"Unable to list the folder"];
    return nil;
  }
  NSMutableArray* files = [NSMutableArray array];
  for (auto& e : entries) {
    ZVRemoteFile* f = [[ZVRemoteFile alloc] init];
    f.name = nsstr(e.name);
    f.path = nsstr(joinPath(path, e.name));
    f.isDirectory = e.isDirectory;
    f.isSymlink = e.isLink;
    f.size = e.size;
    f.modified = e.modified ? [NSDate dateWithTimeIntervalSince1970:e.modified] : nil;
    f.permissions = e.permissions;
    [files addObject:f];
  }
  [files sortUsingComparator:^NSComparisonResult(ZVRemoteFile* a, ZVRemoteFile* b) {
    if (a.isDirectory != b.isDirectory)
      return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
    return [a.name localizedStandardCompare:b.name];
  }];
  return files;
}

- (void)listDirectory:(NSString*)path
           completion:(void (^)(NSArray<ZVRemoteFile*>*, NSError*))completion
{
  [self withConnection:^(NSError* error) {
    NSArray* files = nil;
    if (!error)
      files = [self listOnQueue:remoteName(path) error:&error];
    [self onMain:^{ completion(error ? nil : files, error); }];
  }];
}

- (void)directoryExists:(NSString*)path completion:(void (^)(BOOL))completion
{
  [self withConnection:^(NSError* error) {
    ZVFtpConnection::Entry e;
    BOOL exists = !error && self->_conn->stat(remoteName(path), &e) && e.isDirectory;
    [self onMain:^{ completion(exists); }];
  }];
}

#pragma mark Transfers (queue)

- (ZVConflictAction)askConflict:(ZVTransferConflict*)conflict
{
  ZVConflictAction (^handler)(ZVTransferConflict*) = _conflictHandler;
  if (!handler)
    return ZVConflictReplace;
  __block ZVConflictAction action = ZVConflictStop;
  dispatch_sync(dispatch_get_main_queue(), ^{ action = handler(conflict); });
  return action;
}

// "name 2.ext", "name 3.ext", ... that doesn't exist on the server
- (std::string)uniqueRemotePath:(const std::string&)path
{
  NSString* p = nsstr(path);
  NSString* dir = [p stringByDeletingLastPathComponent];
  NSString* name = [p lastPathComponent];
  NSString* base = [name stringByDeletingPathExtension];
  NSString* ext = [name pathExtension];
  for (int i = 2; i < 10000; i++) {
    NSString* n = [NSString stringWithFormat:@"%@ %d", base, i];
    if (ext.length)
      n = [n stringByAppendingPathExtension:ext];
    std::string candidate = joinPath(remoteName(dir), remoteName(n));
    ZVFtpConnection::Entry e;
    if (!_conn->stat(candidate, &e) && _conn->notFound())
      return candidate;
  }
  return path;
}

- (void)reportProgress:(ZVTransferProgress)p block:(void (^)(ZVTransferProgress))block
                  last:(CFAbsoluteTime*)last force:(BOOL)force
{
  if (!block)
    return;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (!force && now - *last < 0.1)
    return;
  *last = now;
  NSString* name = p.currentName;   // keep it alive for the block
  [self onMain:^{
    ZVTransferProgress q = p;
    q.currentName = name;
    block(q);
  }];
}

- (void)uploadURLs:(NSArray<NSURL*>*)urls toDirectory:(NSString*)directory
          progress:(void (^)(ZVTransferProgress))progress
        completion:(void (^)(NSError*))completion
{
  _cancel = false;
  [self withConnection:^(NSError* error) {
    if (!error)
      [self uploadOnQueue:urls toDirectory:directory progress:progress error:&error];
    [self onMain:^{ completion(error); }];
  }];
}

- (BOOL)uploadOnQueue:(NSArray<NSURL*>*)urls toDirectory:(NSString*)directory
             progress:(void (^)(ZVTransferProgress))progress error:(NSError**)error
{
  NSFileManager* fm = [NSFileManager defaultManager];

  // Work out everything that has to be created first
  std::vector<std::string> dirs;
  std::vector<std::pair<NSURL*, std::string>> files;
  unsigned long long total = 0;
  for (NSURL* url in urls) {
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:url.path isDirectory:&isDir])
      continue;
    std::string target = joinPath(remoteName(directory), remoteName(url.lastPathComponent));
    if (!isDir) {
      files.push_back({url, target});
      total += [[fm attributesOfItemAtPath:url.path error:nil] fileSize];
      continue;
    }
    dirs.push_back(target);
    NSDirectoryEnumerator<NSString*>* e = [fm enumeratorAtPath:url.path];
    for (NSString* rel in e) {
      std::string remote = joinPath(target, remoteName(rel));
      NSDictionary* attrs = e.fileAttributes;
      if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        dirs.push_back(remote);
      } else {
        files.push_back({[url URLByAppendingPathComponent:rel], remote});
        total += [attrs fileSize];
      }
    }
  }

  for (const std::string& d : dirs)
    (void)_conn->makeDirectory(d);   // "already exists" is fine: folders are merged

  ZVTransferProgress p = { 0, total, 0, files.size(), nil };
  CFAbsoluteTime last = 0;

  for (auto& item : files) {
    if (_cancel) {
      *error = [self cancelledError];
      return NO;
    }
    NSURL* url = item.first;
    std::string target = item.second;
    p.currentName = url.lastPathComponent;
    [self reportProgress:p block:progress last:&last force:YES];

    NSDictionary* attrs = [fm attributesOfItemAtPath:url.path error:nil];
    ZVFtpConnection::Entry existing;
    if (_conn->stat(target, &existing)) {
      ZVTransferConflict* c = [[ZVTransferConflict alloc] init];
      c.upload = YES;
      c.name = url.lastPathComponent;
      c.destination = [nsstr(target) stringByDeletingLastPathComponent];
      c.existingSize = existing.size;
      c.existingDate = existing.modified ? [NSDate dateWithTimeIntervalSince1970:existing.modified] : nil;
      c.existingIsDirectory = existing.isDirectory;
      c.incomingSize = [attrs fileSize];
      c.incomingDate = attrs[NSFileModificationDate];
      ZVConflictAction action = [self askConflict:c];
      if (action == ZVConflictReplace && c.existingIsDirectory)
        action = ZVConflictKeepBoth;   // a folder can't be replaced by a file
      if (action == ZVConflictStop) {
        *error = [self cancelledError];
        return NO;
      }
      if (action == ZVConflictSkip) {
        p.bytesDone += c.incomingSize;
        p.filesDone++;
        continue;
      }
      if (action == ZVConflictKeepBoth)
        target = [self uniqueRemotePath:target];
    } else if (!_conn->isConnected()) {
      *error = [self connectionError:@"Connection lost"];
      return NO;
    }

    int fd = open(url.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
      *error = [self errorWithMessage:[NSString stringWithFormat:@"Unable to read %@: %s",
                                       url.lastPathComponent, strerror(errno)]];
      return NO;
    }
    unsigned long long base = p.bytesDone;
    bool ok = _conn->upload(fd, target, [&](uint64_t n) {
      p.bytesDone = base + n;
      [self reportProgress:p block:progress last:&last force:NO];
    }, &_cancel);
    close(fd);
    if (!ok) {
      *error = _cancel ? [self cancelledError]
                       : [self connectionError:[NSString stringWithFormat:@"Upload of %@ failed",
                                                url.lastPathComponent]];
      return NO;
    }
    NSDate* modified = attrs[NSFileModificationDate];
    if (modified)
      (void)_conn->setModified(target, (time_t)modified.timeIntervalSince1970);
    p.bytesDone = base + [attrs fileSize];
    p.filesDone++;
  }
  p.currentName = nil;
  [self reportProgress:p block:progress last:&last force:YES];
  return YES;
}

- (void)downloadFiles:(NSArray<ZVRemoteFile*>*)files toDirectory:(NSURL*)directory
             progress:(void (^)(ZVTransferProgress))progress
           completion:(void (^)(NSArray<NSURL*>*, NSError*))completion
{
  _cancel = false;
  [self withConnection:^(NSError* error) {
    NSMutableArray* created = [NSMutableArray array];
    if (!error)
      [self downloadOnQueue:files toDirectory:directory created:created progress:progress error:&error];
    [self onMain:^{ completion(error ? nil : created, error); }];
  }];
}

// A local name that doesn't exist yet: "name", "name 2", ...
static NSURL* uniqueURL(NSURL* dir, NSString* name)
{
  NSFileManager* fm = [NSFileManager defaultManager];
  NSURL* url = [dir URLByAppendingPathComponent:name];
  NSString* base = [name stringByDeletingPathExtension];
  NSString* ext = [name pathExtension];
  for (int i = 2; [fm fileExistsAtPath:url.path]; i++) {
    NSString* n = [NSString stringWithFormat:@"%@ %d", base, i];
    if (ext.length)
      n = [n stringByAppendingPathExtension:ext];
    url = [dir URLByAppendingPathComponent:n];
  }
  return url;
}

- (BOOL)downloadOnQueue:(NSArray<ZVRemoteFile*>*)roots toDirectory:(NSURL*)directory
                created:(NSMutableArray*)created
               progress:(void (^)(ZVTransferProgress))progress error:(NSError**)error
{
  NSFileManager* fm = [NSFileManager defaultManager];

  // Expand folders
  std::vector<std::pair<ZVRemoteFile*, NSURL*>> files;
  unsigned long long total = 0;
  std::vector<std::pair<ZVRemoteFile*, NSURL*>> pending;
  NSMutableSet* rootFiles = [NSMutableSet set];
  for (ZVRemoteFile* f in roots) {
    NSURL* local = [directory URLByAppendingPathComponent:f.name];
    if (f.isDirectory)
      [created addObject:local];
    else
      [rootFiles addObject:f];
    pending.push_back({f, local});
  }
  while (!pending.empty()) {
    auto item = pending.back();
    pending.pop_back();
    if (item.first.isDirectory) {
      [fm createDirectoryAtURL:item.second withIntermediateDirectories:YES attributes:nil error:nil];
      NSArray* children = [self listOnQueue:remoteName(item.first.path) error:error];
      if (!children)
        return NO;
      for (ZVRemoteFile* c in children) {
        if (c.isSymlink && c.isDirectory)
          continue;   // don't follow folder links (loops)
        pending.push_back({c, [item.second URLByAppendingPathComponent:c.name]});
      }
    } else {
      files.push_back(item);
      total += item.first.size;
    }
  }

  ZVTransferProgress p = { 0, total, 0, files.size(), nil };
  CFAbsoluteTime last = 0;

  for (auto& item : files) {
    if (_cancel) {
      *error = [self cancelledError];
      return NO;
    }
    ZVRemoteFile* f = item.first;
    NSURL* localURL = item.second;
    p.currentName = f.name;
    [self reportProgress:p block:progress last:&last force:YES];

    BOOL isDir = NO;
    if ([fm fileExistsAtPath:localURL.path isDirectory:&isDir]) {
      NSDictionary* attrs = [fm attributesOfItemAtPath:localURL.path error:nil];
      ZVTransferConflict* c = [[ZVTransferConflict alloc] init];
      c.upload = NO;
      c.name = f.name;
      c.destination = [localURL.path stringByDeletingLastPathComponent];
      c.existingSize = [attrs fileSize];
      c.existingDate = attrs[NSFileModificationDate];
      c.existingIsDirectory = isDir;
      c.incomingSize = f.size;
      c.incomingDate = f.modified;
      ZVConflictAction action = [self askConflict:c];
      if (action == ZVConflictReplace && isDir)
        action = ZVConflictKeepBoth;
      if (action == ZVConflictStop) {
        *error = [self cancelledError];
        return NO;
      }
      if (action == ZVConflictSkip) {
        p.bytesDone += f.size;
        p.filesDone++;
        if ([rootFiles containsObject:f])
          [created addObject:localURL];
        continue;
      }
      if (action == ZVConflictKeepBoth)
        localURL = uniqueURL([localURL URLByDeletingLastPathComponent], f.name);
    }
    if ([rootFiles containsObject:f])
      [created addObject:localURL];

    int fd = open(localURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC,
                  (f.permissions & 0777) ?: 0644);
    if (fd < 0) {
      *error = [self errorWithMessage:[NSString stringWithFormat:@"Unable to write %@: %s",
                                       localURL.lastPathComponent, strerror(errno)]];
      return NO;
    }
    unsigned long long base = p.bytesDone;
    bool ok = _conn->download(remoteName(f.path), fd, [&](uint64_t n) {
      p.bytesDone = base + n;
      [self reportProgress:p block:progress last:&last force:NO];
    }, &_cancel);
    close(fd);
    if (!ok) {
      *error = _cancel ? [self cancelledError]
                       : [self connectionError:[NSString stringWithFormat:@"Download of %@ failed", f.name]];
      return NO;
    }
    if (f.modified) {
      struct timeval tv[2];
      tv[0].tv_sec = tv[1].tv_sec = (time_t)f.modified.timeIntervalSince1970;
      tv[0].tv_usec = tv[1].tv_usec = 0;
      utimes(localURL.fileSystemRepresentation, tv);
    }
    p.bytesDone = base + f.size;
    p.filesDone++;
  }

  p.currentName = nil;
  [self reportProgress:p block:progress last:&last force:YES];
  return YES;
}

#pragma mark File operations

- (void)createDirectory:(NSString*)path completion:(void (^)(NSError*))completion
{
  [self withConnection:^(NSError* error) {
    if (!error && !self->_conn->makeDirectory(remoteName(path)))
      error = [self connectionError:@"Unable to create folder"];
    [self onMain:^{ completion(error); }];
  }];
}

- (BOOL)removeOnQueue:(ZVRemoteFile*)f error:(NSError**)error
{
  std::string path = remoteName(f.path);
  if (f.isDirectory && !f.isSymlink) {
    NSArray* children = [self listOnQueue:path error:error];
    if (!children)
      return NO;
    for (ZVRemoteFile* c in children)
      if (![self removeOnQueue:c error:error])
        return NO;
    if (!_conn->removeDirectory(path)) {
      *error = [self connectionError:[NSString stringWithFormat:@"Unable to delete %@", f.name]];
      return NO;
    }
  } else if (!_conn->removeFile(path)) {
    *error = [self connectionError:[NSString stringWithFormat:@"Unable to delete %@", f.name]];
    return NO;
  }
  return YES;
}

- (void)removeFiles:(NSArray<ZVRemoteFile*>*)files completion:(void (^)(NSError*))completion
{
  [self withConnection:^(NSError* error) {
    if (!error) {
      for (ZVRemoteFile* f in files)
        if (![self removeOnQueue:f error:&error])
          break;
    }
    [self onMain:^{ completion(error); }];
  }];
}

- (void)renameFile:(ZVRemoteFile*)file to:(NSString*)newName completion:(void (^)(NSError*))completion
{
  NSString* target = [[file.path stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
  [self withConnection:^(NSError* error) {
    if (!error && !self->_conn->rename(remoteName(file.path), remoteName(target)))
      error = [self connectionError:@"Unable to rename"];
    [self onMain:^{ completion(error); }];
  }];
}

@end

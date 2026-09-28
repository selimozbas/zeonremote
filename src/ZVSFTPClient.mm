// Zeon Remote - SFTP client (libssh2)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <string>
#include <vector>

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

#include <libssh2.h>
#include <libssh2_sftp.h>

#import "ZVSFTPClient.h"
#import "ZVNetUtil.h"

#include <mutex>

static NSString* const kErrorDomain = @"ZeonRemote.SFTP";

@implementation ZVRemoteFile
@end

@implementation ZVTransferConflict
@end

// Password for keyboard-interactive authentication (only used on the
// client's own queue while authenticating)
static thread_local std::string kbdintPassword;

static void kbdintCallback(const char*, int, const char*, int, int numPrompts,
                           const LIBSSH2_USERAUTH_KBDINT_PROMPT*,
                           LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses, void**)
{
  // Servers normally ask a single "Password:" question
  for (int i = 0; i < numPrompts; i++) {
    responses[i].text = strdup(kbdintPassword.c_str());
    responses[i].length = (unsigned int)kbdintPassword.size();
  }
}

@implementation ZVSFTPClient {
  dispatch_queue_t _queue;
  int _sock;
  LIBSSH2_SESSION* _session;
  LIBSSH2_SFTP* _sftp;
  int _port;
  volatile BOOL _cancel;
  NSString* _savedPassword;   // saved for this device, tried after the offered one

  // Shell
  std::mutex _shellMutex;
  std::vector<char> _shellOut;
  int _shellCols, _shellRows;
  BOOL _shellResize;
  volatile BOOL _shellClose;
  int _wake[2];
}

+ (void)initialize
{
  if (self == [ZVSFTPClient class])
    libssh2_init(0);
}

- (instancetype)initWithHost:(NSString*)host port:(int)port
{
  self = [super init];
  if (self) {
    _host = [host copy];
    _port = port > 0 ? port : 22;
    _sock = -1;
    _wantsSFTP = YES;
    _wake[0] = _wake[1] = -1;
    _queue = dispatch_queue_create("com.zeonvnc.ssh", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc
{
  [self closeNow];
  if (_wake[0] >= 0) {
    close(_wake[0]);
    close(_wake[1]);
  }
}

#pragma mark Helpers

- (NSError*)errorWithMessage:(NSString*)message
{
  return [NSError errorWithDomain:kErrorDomain code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSError*)lastError:(NSString*)what
{
  char* msg = nullptr;
  int len = 0;
  if (_session)
    libssh2_session_last_error(_session, &msg, &len, 0);
  NSString* detail = msg && len ? [[NSString alloc] initWithBytes:msg length:len
                                                         encoding:NSUTF8StringEncoding] : nil;
  // SFTP level errors carry a status code with a clearer meaning
  if (_sftp && _session && libssh2_session_last_errno(_session) == LIBSSH2_ERROR_SFTP_PROTOCOL) {
    switch (libssh2_sftp_last_error(_sftp)) {
    case LIBSSH2_FX_NO_SUCH_FILE:        detail = @"No such file or folder"; break;
    case LIBSSH2_FX_PERMISSION_DENIED:   detail = @"Permission denied"; break;
    case LIBSSH2_FX_FILE_ALREADY_EXISTS: detail = @"A file with this name already exists"; break;
    case LIBSSH2_FX_DIR_NOT_EMPTY:       detail = @"The folder is not empty"; break;
    case LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM:
    case LIBSSH2_FX_QUOTA_EXCEEDED:      detail = @"Not enough space on the device"; break;
    }
  }
  return [self errorWithMessage:detail.length ? [NSString stringWithFormat:@"%@: %@", what, detail] : what];
}

- (void)onMain:(dispatch_block_t)block
{
  dispatch_async(dispatch_get_main_queue(), block);
}

// macOS hands out decomposed (NFD) file names; Linux and most other
// systems expect composed (NFC) UTF-8, e.g. for Turkish characters
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

#pragma mark Connection (queue)

- (BOOL)checkHostKey:(NSError**)error
{
  size_t keyLen = 0;
  int keyType = 0;
  const char* key = libssh2_session_hostkey(_session, &keyLen, &keyType);
  const char* hash = libssh2_hostkey_hash(_session, LIBSSH2_HOSTKEY_HASH_SHA256);
  if (!key || !hash) {
    *error = [self errorWithMessage:@"The server did not provide a host key"];
    return NO;
  }

  NSData* digest = [NSData dataWithBytes:hash length:32];
  NSMutableString* hex = [NSMutableString string];
  for (int i = 0; i < 32; i++)
    [hex appendFormat:@"%02x", (unsigned char)hash[i]];
  NSString* b64 = [[digest base64EncodedStringWithOptions:0]
                    stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
  NSString* fingerprint = [@"ssh:" stringByAppendingString:hex];
  NSString* display = [@"SHA256:" stringByAppendingString:b64];
  _hostKeyFingerprint = fingerprint;

  // Accept keys the user already trusts in ~/.ssh/known_hosts
  BOOL known = NO;
  LIBSSH2_KNOWNHOSTS* nh = libssh2_knownhost_init(_session);
  if (nh) {
    NSString* path = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh/known_hosts"];
    if (libssh2_knownhost_readfile(nh, path.fileSystemRepresentation,
                                   LIBSSH2_KNOWNHOST_FILE_OPENSSH) >= 0) {
      struct libssh2_knownhost* host = nullptr;
      int check = libssh2_knownhost_checkp(nh, _host.UTF8String, _port, key, keyLen,
                                           LIBSSH2_KNOWNHOST_TYPE_PLAIN |
                                           LIBSSH2_KNOWNHOST_KEYENC_RAW, &host);
      known = check == LIBSSH2_KNOWNHOST_CHECK_MATCH;
    }
    libssh2_knownhost_free(nh);
  }
  if (known)
    return YES;

  __block BOOL trusted = NO;
  __weak ZVSFTPClient* weakSelf = self;
  dispatch_sync(dispatch_get_main_queue(), ^{
    ZVSFTPClient* s = weakSelf;
    trusted = [s.delegate sftpClient:s trustHostKey:fingerprint display:display];
  });
  if (!trusted) {
    *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
    return NO;
  }
  return YES;
}

- (BOOL)tryPassword:(NSString*)password user:(NSString*)user methods:(const char*)methods
{
  const char* u = user.UTF8String;
  if (methods == nullptr || strstr(methods, "password")) {
    if (libssh2_userauth_password(_session, u, password.UTF8String) == 0)
      return YES;
  }
  if (methods == nullptr || strstr(methods, "keyboard-interactive")) {
    kbdintPassword = password.UTF8String ?: "";
    int rc = libssh2_userauth_keyboard_interactive(_session, u, kbdintCallback);
    kbdintPassword.assign(kbdintPassword.size(), '\0');
    kbdintPassword.clear();
    if (rc == 0)
      return YES;
  }
  return NO;
}

- (BOOL)tryKeysForUser:(NSString*)user
{
  const char* u = user.UTF8String;

  // ssh-agent (keys loaded with ssh-add / the macOS keychain)
  LIBSSH2_AGENT* agent = libssh2_agent_init(_session);
  if (agent) {
    BOOL ok = NO;
    if (libssh2_agent_connect(agent) == 0 && libssh2_agent_list_identities(agent) == 0) {
      struct libssh2_agent_publickey* id = nullptr;
      struct libssh2_agent_publickey* prev = nullptr;
      while (!ok && libssh2_agent_get_identity(agent, &id, prev) == 0) {
        if (libssh2_agent_userauth(agent, u, id) == 0)
          ok = YES;
        prev = id;
      }
      libssh2_agent_disconnect(agent);
    }
    libssh2_agent_free(agent);
    if (ok)
      return YES;
  }

  // Unencrypted key files
  NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh"];
  for (NSString* name in @[@"id_ed25519", @"id_ecdsa", @"id_rsa"]) {
    NSString* priv = [dir stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:priv])
      continue;
    NSString* pub = [priv stringByAppendingString:@".pub"];
    const char* pubPath = [[NSFileManager defaultManager] fileExistsAtPath:pub]
                            ? pub.fileSystemRepresentation : nullptr;
    if (libssh2_userauth_publickey_fromfile(_session, u, pubPath,
                                            priv.fileSystemRepresentation, "") == 0)
      return YES;
  }
  return NO;
}

- (BOOL)authenticate:(NSError**)error
{
  NSString* user = _username;
  __weak ZVSFTPClient* weakSelf = self;

  // Without a user name we have to ask straight away
  if (user.length == 0) {
    __block BOOL ok = NO;
    __block NSString* u = nil;
    __block NSString* p = nil;
    __block BOOL remember = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZVSFTPClient* s = weakSelf;
      NSString* uu = nil, *pp = nil;
      BOOL rr = NO;
      ok = [s.delegate sftpClient:s wantsPasswordForUser:&uu password:&pp remember:&rr failed:NO];
      u = uu; p = pp; remember = rr;
    });
    if (!ok) {
      *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
      return NO;
    }
    user = u;
    _offeredPassword = p;
    _passwordToRemember = remember ? p : nil;
  }

  char* list = libssh2_userauth_list(_session, user.UTF8String, (unsigned int)user.length);
  if (list == nullptr && libssh2_userauth_authenticated(_session)) {
    _username = user;
    return YES;
  }
  std::string methods = list ? list : "";

  if (methods.find("publickey") != std::string::npos && [self tryKeysForUser:user]) {
    _username = user;
    return YES;
  }

  if (_offeredPassword.length && [self tryPassword:_offeredPassword user:user methods:methods.c_str()]) {
    _username = user;
    _usedPassword = _offeredPassword;
    return YES;
  }
  if (_savedPassword.length && ![_savedPassword isEqualToString:_offeredPassword] &&
      [self tryPassword:_savedPassword user:user methods:methods.c_str()]) {
    _username = user;
    _usedPassword = _savedPassword;
    return YES;
  }
  _passwordToRemember = nil;

  BOOL failed = _offeredPassword.length > 0 || _savedPassword.length > 0;
  for (int attempt = 0; attempt < 5; attempt++) {
    __block BOOL ok = NO;
    __block NSString* u = user;
    __block NSString* p = nil;
    __block BOOL remember = NO;
    BOOL f = failed;
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZVSFTPClient* s = weakSelf;
      NSString* uu = u, *pp = nil;
      BOOL rr = NO;
      ok = [s.delegate sftpClient:s wantsPasswordForUser:&uu password:&pp remember:&rr failed:f];
      u = uu; p = pp; remember = rr;
    });
    if (!ok) {
      *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
      return NO;
    }
    if (![u isEqualToString:user]) {
      // A different user name needs a fresh method list
      user = u;
      list = libssh2_userauth_list(_session, user.UTF8String, (unsigned int)user.length);
      methods = list ? list : "";
    }
    if ([self tryPassword:p user:user methods:methods.c_str()]) {
      _username = user;
      _usedPassword = p;
      _passwordToRemember = remember ? p : nil;
      return YES;
    }
    failed = YES;
  }

  *error = [self errorWithMessage:@"Authentication failed"];
  return NO;
}

- (void)closeNow
{
  if (_sftp) {
    libssh2_sftp_shutdown(_sftp);
    _sftp = nullptr;
  }
  if (_session) {
    libssh2_session_disconnect(_session, "Bye");
    libssh2_session_free(_session);
    _session = nullptr;
  }
  if (_sock >= 0) {
    close(_sock);
    _sock = -1;
  }
  _isConnected = NO;
}

- (void)connect:(void (^)(NSError*))completion
{
  _cancel = NO;
  dispatch_async(_queue, ^{
    NSError* error = nil;
    if (!self->_isConnected)
      [self connectOnQueue:&error];
    [self onMain:^{ completion(error); }];
  });
}

- (BOOL)connectOnQueue:(NSError**)error
{
  [self closeNow];

  _sock = ZVConnectTCP(_host, _port, &_cancel, error);
  if (_sock < 0)
    return NO;
  _deviceMAC = ZVMACAddressOfPeer(_sock);

  _session = libssh2_session_init();
  libssh2_session_set_blocking(_session, 1);
  libssh2_session_set_timeout(_session, 30000);
  if (libssh2_session_handshake(_session, _sock) != 0) {
    *error = [self lastError:@"SSH handshake failed"];
    [self closeNow];
    return NO;
  }

  if (![self checkHostKey:error]) {
    [self closeNow];
    return NO;
  }

  // Now that we know which device this is, it may have a saved password
  {
    __weak ZVSFTPClient* weakSelf = self;
    __block NSString* saved = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZVSFTPClient* s = weakSelf;
      if ([s.delegate respondsToSelector:@selector(sftpClientSavedPassword:)])
        saved = [s.delegate sftpClientSavedPassword:s];
    });
    _savedPassword = saved;
  }

  if (![self authenticate:error]) {
    [self closeNow];
    return NO;
  }

  libssh2_keepalive_config(_session, 1, 30);

  if (!_wantsSFTP) {
    _isConnected = YES;
    return YES;
  }

  _sftp = libssh2_sftp_init(_session);
  if (!_sftp) {
    *error = [self lastError:@"The device does not offer SFTP"];
    [self closeNow];
    return NO;
  }

  char buf[1024];
  int n = libssh2_sftp_realpath(_sftp, ".", buf, sizeof(buf) - 1);
  if (n > 0) {
    buf[n] = 0;
    _homeDirectory = [NSString stringWithUTF8String:buf];
  } else {
    _homeDirectory = @"/";
  }

  _isConnected = YES;
  return YES;
}

- (void)disconnect
{
  _cancel = YES;
  dispatch_async(_queue, ^{ [self closeNow]; });
}

- (void)cancelTransfer
{
  _cancel = YES;
}

// Runs a block on the queue after making sure we're connected
- (void)withConnection:(void (^)(NSError* error))block
{
  dispatch_async(_queue, ^{
    NSError* error = nil;
    if (!self->_isConnected)
      [self connectOnQueue:&error];
    block(error);
  });
}

#pragma mark Directory listing (queue)

- (NSArray<ZVRemoteFile*>*)listOnQueue:(const std::string&)path error:(NSError**)error
{
  LIBSSH2_SFTP_HANDLE* dir = libssh2_sftp_opendir(_sftp, path.c_str());
  if (!dir) {
    *error = [self lastError:@"Unable to open folder"];
    return nil;
  }

  NSMutableArray* files = [NSMutableArray array];
  char name[1024];
  char longentry[2048];
  LIBSSH2_SFTP_ATTRIBUTES attrs;
  while (true) {
    int n = libssh2_sftp_readdir_ex(dir, name, sizeof(name), longentry, sizeof(longentry), &attrs);
    if (n <= 0)
      break;
    std::string entry(name, n);
    if (entry == "." || entry == "..")
      continue;

    ZVRemoteFile* f = [[ZVRemoteFile alloc] init];
    f.name = [[NSString alloc] initWithBytes:name length:n encoding:NSUTF8StringEncoding] ?: @"?";
    f.path = [NSString stringWithUTF8String:joinPath(path, entry).c_str()];
    if (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) {
      f.permissions = attrs.permissions;
      f.isDirectory = LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
      f.isSymlink = LIBSSH2_SFTP_S_ISLNK(attrs.permissions);
    }
    if (f.isSymlink) {
      // Follow links so linked folders can be opened
      LIBSSH2_SFTP_ATTRIBUTES target;
      if (libssh2_sftp_stat(_sftp, f.path.UTF8String, &target) == 0 &&
          (target.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS))
        f.isDirectory = LIBSSH2_SFTP_S_ISDIR(target.permissions);
    }
    if (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE)
      f.size = attrs.filesize;
    if (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME)
      f.modified = [NSDate dateWithTimeIntervalSince1970:attrs.mtime];
    [files addObject:f];
  }
  libssh2_sftp_closedir(dir);

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
      files = [self listOnQueue:path.UTF8String error:&error];
    [self onMain:^{ completion(files, error); }];
  }];
}

- (void)directoryExists:(NSString*)path completion:(void (^)(BOOL))completion
{
  [self withConnection:^(NSError* error) {
    BOOL exists = NO;
    if (!error) {
      LIBSSH2_SFTP_ATTRIBUTES a;
      exists = libssh2_sftp_stat(self->_sftp, path.UTF8String, &a) == 0 &&
               (a.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
               LIBSSH2_SFTP_S_ISDIR(a.permissions);
    }
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

// "name 2.ext", "name 3.ext", ... that doesn't exist on the remote side
- (std::string)uniqueRemotePath:(const std::string&)path
{
  NSString* p = [NSString stringWithUTF8String:path.c_str()];
  NSString* dir = [p stringByDeletingLastPathComponent];
  NSString* name = [p lastPathComponent];
  NSString* base = [name stringByDeletingPathExtension];
  NSString* ext = [name pathExtension];
  for (int i = 2; i < 10000; i++) {
    NSString* n = [NSString stringWithFormat:@"%@ %d", base, i];
    if (ext.length)
      n = [n stringByAppendingPathExtension:ext];
    std::string candidate = joinPath(dir.UTF8String, remoteName(n));
    LIBSSH2_SFTP_ATTRIBUTES a;
    if (libssh2_sftp_stat(_sftp, candidate.c_str(), &a) != 0)
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
  _cancel = NO;
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
    // The enumerator gives paths relative to the folder, so a folder reached
    // through a symlink (/tmp, /var -> /private/...) still maps correctly
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

  for (const std::string& d : dirs) {
    // Ignore "already exists"
    libssh2_sftp_mkdir(_sftp, d.c_str(), 0755);
  }

  ZVTransferProgress p = { 0, total, 0, files.size(), nil };
  CFAbsoluteTime last = 0;
  std::vector<char> buf(256 * 1024);

  for (auto& item : files) {
    if (_cancel) {
      *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
      return NO;
    }
    NSURL* url = item.first;
    p.currentName = url.lastPathComponent;
    [self reportProgress:p block:progress last:&last force:YES];

    int fd = open(url.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
      *error = [self errorWithMessage:[NSString stringWithFormat:@"Unable to read %@: %s",
                                       url.lastPathComponent, strerror(errno)]];
      return NO;
    }
    NSDictionary* attrs = [fm attributesOfItemAtPath:url.path error:nil];
    long mode = ([attrs[NSFilePosixPermissions] longValue] & 0777) ?: 0644;

    std::string target = item.second;
    LIBSSH2_SFTP_ATTRIBUTES existing;
    if (libssh2_sftp_stat(_sftp, target.c_str(), &existing) == 0) {
      ZVTransferConflict* c = [[ZVTransferConflict alloc] init];
      c.upload = YES;
      c.name = url.lastPathComponent;
      c.destination = [[NSString stringWithUTF8String:target.c_str()] stringByDeletingLastPathComponent];
      c.existingSize = (existing.flags & LIBSSH2_SFTP_ATTR_SIZE) ? existing.filesize : 0;
      c.existingDate = (existing.flags & LIBSSH2_SFTP_ATTR_ACMODTIME)
                         ? [NSDate dateWithTimeIntervalSince1970:existing.mtime] : nil;
      c.existingIsDirectory = (existing.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
                              LIBSSH2_SFTP_S_ISDIR(existing.permissions);
      c.incomingSize = [attrs fileSize];
      c.incomingDate = attrs[NSFileModificationDate];
      ZVConflictAction action = [self askConflict:c];
      if (action == ZVConflictReplace && c.existingIsDirectory)
        action = ZVConflictKeepBoth;   // a folder can't be replaced by a file
      if (action == ZVConflictStop) {
        close(fd);
        *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
        return NO;
      }
      if (action == ZVConflictSkip) {
        close(fd);
        p.bytesDone += c.incomingSize;
        p.filesDone++;
        continue;
      }
      if (action == ZVConflictKeepBoth)
        target = [self uniqueRemotePath:target];
    }

    LIBSSH2_SFTP_HANDLE* h = libssh2_sftp_open(_sftp, target.c_str(),
                                               LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
                                               mode);
    if (!h) {
      close(fd);
      *error = [self lastError:[NSString stringWithFormat:@"Unable to create %@", url.lastPathComponent]];
      return NO;
    }

    BOOL ok = YES;
    ssize_t n;
    while ((n = read(fd, buf.data(), buf.size())) > 0 && ok) {
      char* ptr = buf.data();
      while (n > 0) {
        ssize_t w = libssh2_sftp_write(h, ptr, n);
        if (w < 0) {
          ok = NO;
          break;
        }
        ptr += w;
        n -= w;
        p.bytesDone += w;
        [self reportProgress:p block:progress last:&last force:NO];
      }
      if (_cancel)
        break;
    }
    close(fd);
    libssh2_sftp_close(h);

    if (!ok) {
      *error = [self lastError:[NSString stringWithFormat:@"Upload of %@ failed", url.lastPathComponent]];
      return NO;
    }
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
  _cancel = NO;
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
      [created addObject:local];     // folders are merged into
    else
      [rootFiles addObject:f];       // added once the final name is known
    pending.push_back({f, local});
  }
  while (!pending.empty()) {
    auto item = pending.back();
    pending.pop_back();
    if (item.first.isDirectory) {
      [fm createDirectoryAtURL:item.second withIntermediateDirectories:YES attributes:nil error:nil];
      NSArray* children = [self listOnQueue:item.first.path.UTF8String error:error];
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
  std::vector<char> buf(256 * 1024);

  for (auto& item : files) {
    if (_cancel) {
      *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
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
        *error = [NSError errorWithDomain:kErrorDomain code:NSUserCancelledError userInfo:nil];
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

    LIBSSH2_SFTP_HANDLE* h = libssh2_sftp_open(_sftp, f.path.UTF8String, LIBSSH2_FXF_READ, 0);
    if (!h) {
      *error = [self lastError:[NSString stringWithFormat:@"Unable to open %@", f.name]];
      return NO;
    }
    int fd = open(localURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC,
                  (f.permissions & 0777) ?: 0644);
    if (fd < 0) {
      libssh2_sftp_close(h);
      *error = [self errorWithMessage:[NSString stringWithFormat:@"Unable to write %@: %s",
                                       localURL.lastPathComponent, strerror(errno)]];
      return NO;
    }

    BOOL ok = YES;
    ssize_t n;
    while ((n = libssh2_sftp_read(h, buf.data(), buf.size())) > 0) {
      if (write(fd, buf.data(), n) != n) {
        ok = NO;
        break;
      }
      p.bytesDone += n;
      [self reportProgress:p block:progress last:&last force:NO];
      if (_cancel)
        break;
    }
    if (n < 0)
      ok = NO;
    close(fd);
    libssh2_sftp_close(h);
    if (!ok) {
      *error = [self lastError:[NSString stringWithFormat:@"Download of %@ failed", f.name]];
      return NO;
    }
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
    if (!error && libssh2_sftp_mkdir(self->_sftp, remoteName(path).c_str(), 0755) != 0)
      error = [self lastError:@"Unable to create folder"];
    [self onMain:^{ completion(error); }];
  }];
}

- (BOOL)removeOnQueue:(ZVRemoteFile*)f error:(NSError**)error
{
  if (f.isDirectory && !f.isSymlink) {
    NSArray* children = [self listOnQueue:f.path.UTF8String error:error];
    if (!children)
      return NO;
    for (ZVRemoteFile* c in children)
      if (![self removeOnQueue:c error:error])
        return NO;
    if (libssh2_sftp_rmdir(_sftp, f.path.UTF8String) != 0) {
      *error = [self lastError:[NSString stringWithFormat:@"Unable to delete %@", f.name]];
      return NO;
    }
  } else if (libssh2_sftp_unlink(_sftp, f.path.UTF8String) != 0) {
    *error = [self lastError:[NSString stringWithFormat:@"Unable to delete %@", f.name]];
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
    if (!error && libssh2_sftp_rename(self->_sftp, file.path.UTF8String, remoteName(target).c_str()) != 0)
      error = [self lastError:@"Unable to rename"];
    [self onMain:^{ completion(error); }];
  }];
}

#pragma mark Shell

- (void)openShellWithTerminal:(NSString*)term columns:(int)columns rows:(int)rows
                       output:(void (^)(NSData*))output closed:(void (^)(NSError*))closed
{
  _cancel = NO;
  _shellClose = NO;
  _shellCols = columns;
  _shellRows = rows;
  if (_wake[0] < 0 && pipe(_wake) == 0) {
    fcntl(_wake[0], F_SETFL, O_NONBLOCK);
    fcntl(_wake[1], F_SETFL, O_NONBLOCK);
  }

  dispatch_async(_queue, ^{
    NSError* error = nil;
    if (!self->_isConnected)
      [self connectOnQueue:&error];
    if (!error)
      [self runShell:term output:output error:&error];
    [self closeNow];
    [self onMain:^{ closed(error); }];
  });
}

- (void)wakeShell
{
  if (_wake[1] >= 0) {
    char c = 0;
    (void)!write(_wake[1], &c, 1);
  }
}

- (void)writeShell:(NSData*)data
{
  {
    std::lock_guard<std::mutex> lock(_shellMutex);
    const char* p = (const char*)data.bytes;
    _shellOut.insert(_shellOut.end(), p, p + data.length);
  }
  [self wakeShell];
}

- (void)resizeShellColumns:(int)columns rows:(int)rows
{
  {
    std::lock_guard<std::mutex> lock(_shellMutex);
    _shellCols = columns;
    _shellRows = rows;
    _shellResize = YES;
  }
  [self wakeShell];
}

- (void)closeShell
{
  _shellClose = YES;
  _cancel = YES;
  [self wakeShell];
}

- (BOOL)runShell:(NSString*)term output:(void (^)(NSData*))output error:(NSError**)error
{
  LIBSSH2_CHANNEL* ch = libssh2_channel_open_session(_session);
  if (!ch) {
    *error = [self lastError:@"Unable to open a session channel"];
    return NO;
  }
  // Pass the locale so UTF-8 works on the remote side (servers may ignore it)
  libssh2_channel_setenv(ch, "LANG", "en_US.UTF-8");
  if (libssh2_channel_request_pty_ex(ch, term.UTF8String, (unsigned int)term.length,
                                     nullptr, 0, _shellCols, _shellRows, 0, 0) != 0) {
    *error = [self lastError:@"The server refused a terminal"];
    libssh2_channel_free(ch);
    return NO;
  }
  if (libssh2_channel_shell(ch) != 0) {
    *error = [self lastError:@"The server refused a shell"];
    libssh2_channel_free(ch);
    return NO;
  }

  libssh2_session_set_blocking(_session, 0);
  std::vector<char> buf(32768);
  std::vector<char> pending;
  BOOL ok = YES;

  while (!_shellClose) {
    // Input from the user and window size changes
    BOOL resize = NO;
    int cols = 0, rows = 0;
    {
      std::lock_guard<std::mutex> lock(_shellMutex);
      pending.insert(pending.end(), _shellOut.begin(), _shellOut.end());
      _shellOut.clear();
      resize = _shellResize;
      cols = _shellCols;
      rows = _shellRows;
      _shellResize = NO;
    }
    if (resize) {
      int rc;
      while ((rc = libssh2_channel_request_pty_size(ch, cols, rows)) == LIBSSH2_ERROR_EAGAIN)
        usleep(1000);
    }
    while (!pending.empty()) {
      ssize_t n = libssh2_channel_write(ch, pending.data(), pending.size());
      if (n == LIBSSH2_ERROR_EAGAIN)
        break;
      if (n < 0) {
        ok = NO;
        break;
      }
      pending.erase(pending.begin(), pending.begin() + n);
    }
    if (!ok)
      break;

    // Output from the remote side
    BOOL got = NO;
    for (int stream = 0; stream < 2; stream++) {
      while (true) {
        ssize_t n = stream == 0 ? libssh2_channel_read(ch, buf.data(), buf.size())
                                : libssh2_channel_read_stderr(ch, buf.data(), buf.size());
        if (n > 0) {
          NSData* d = [NSData dataWithBytes:buf.data() length:n];
          [self onMain:^{ output(d); }];
          got = YES;
          continue;
        }
        if (n != LIBSSH2_ERROR_EAGAIN && n < 0)
          ok = NO;
        break;
      }
    }
    if (!ok || libssh2_channel_eof(ch))
      break;
    if (got)
      continue;

    int next = 0;
    libssh2_keepalive_send(_session, &next);

    // Wait for the socket (in the direction libssh2 needs) or for input
    struct pollfd fds[2];
    int dir = libssh2_session_block_directions(_session);
    fds[0].fd = _sock;
    fds[0].events = POLLIN;
    if ((dir & LIBSSH2_SESSION_BLOCK_OUTBOUND) || !pending.empty())
      fds[0].events |= POLLOUT;
    fds[0].revents = 0;
    fds[1].fd = _wake[0];
    fds[1].events = POLLIN;
    fds[1].revents = 0;
    poll(fds, 2, 1000);
    if (fds[1].revents) {
      char drain[64];
      while (read(_wake[0], drain, sizeof(drain)) > 0)
        ;
    }
  }

  if (!ok && !_shellClose)
    *error = [self lastError:@"Connection lost"];

  libssh2_session_set_blocking(_session, 1);
  libssh2_channel_close(ch);
  libssh2_channel_free(ch);
  return ok;
}

@end

// Zeon Remote - saved connection ("bookmark") model and store
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVBookmark.h"
#import "ZVKeychain.h"

NSNotificationName const ZVBookmarksDidChangeNotification = @"ZVBookmarksDidChangeNotification";

@interface ZVBookmark ()
@property (nonatomic, readwrite) BOOL isTransient;
@end

@implementation ZVBookmark

- (instancetype)init
{
  self = [super init];
  if (self) {
    _uuid = [NSUUID UUID].UUIDString;
    _name = @"";
    _host = @"";
    _username = @"";
    _notes = @"";
    _group = @"";
    _quality = ZVQualityAuto;
    _encoding = ZVEncodingTight;
    _jpegQuality = 8;
    _compressLevel = 2;
    _colorDepth = ZVColorFull;
    _scaleMode = ZVScaleFit;
    _commandKeyMode = ZVCommandAsControl;
    _keyboardMode = ZVKeyboardRawKeycodes;
    _shared = YES;
    _viewOnly = NO;
    _remoteResize = NO;
    _fullScreen = NO;
    _autoReconnect = YES;
    _shareClipboard = YES;
    _showRemoteCursor = YES;
    _alwaysAskPassword = NO;
    _sshUsername = @"";
    _sshPort = 22;
    _protocolType = ZVProtocolVNC;
    _telnetPort = 23;
    _rdpPort = 3389;
    _ftpPort = 21;
  }
  return self;
}

+ (instancetype)bookmarkWithHost:(NSString*)host
{
  ZVBookmark* b = [[ZVBookmark alloc] init];
  b.host = host;
  b.isTransient = YES;
  return b;
}

+ (instancetype)bookmarkFromQuickConnect:(NSString*)input
{
  NSString* text = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString* lower = text.lowercaseString;
  ZVProtocol proto = ZVProtocolVNC;
  NSString* user = nil;
  NSString* host = text;
  int port = 0;

  if ([lower hasPrefix:@"vnc://"]) {
    // vnc://[user@]host[:port]  (the port is a TCP port, not a display)
    NSURL* url = [NSURL URLWithString:text];
    NSString* h = url.host ?: @"";
    if ([h containsString:@":"])
      h = [NSString stringWithFormat:@"[%@]", h];
    ZVBookmark* b = [self bookmarkWithHost:url.port ? [NSString stringWithFormat:@"%@::%@", h, url.port] : h];
    if (url.user.length)
      b.username = url.user;
    return b;
  }
  BOOL ftps = [lower hasPrefix:@"ftps://"] || [lower hasPrefix:@"ftps "];
  if ([lower hasPrefix:@"ssh://"] || [lower hasPrefix:@"telnet://"] || [lower hasPrefix:@"rdp://"] ||
      [lower hasPrefix:@"sftp://"] || [lower hasPrefix:@"ftp://"] || [lower hasPrefix:@"ftps://"]) {
    NSURL* url = [NSURL URLWithString:text];
    proto = [lower hasPrefix:@"ssh"] ? ZVProtocolSSH
          : [lower hasPrefix:@"rdp"] ? ZVProtocolRDP
          : [lower hasPrefix:@"sftp"] ? ZVProtocolSFTP
          : [lower hasPrefix:@"ftp"] ? ZVProtocolFTP : ZVProtocolTelnet;
    user = url.user;
    host = url.host ?: @"";
    port = url.port.intValue;
  } else if ([lower hasPrefix:@"ssh "] || [lower hasPrefix:@"telnet "] || [lower hasPrefix:@"rdp "] ||
             [lower hasPrefix:@"sftp "] || [lower hasPrefix:@"ftp "] || ftps) {
    // Shell style: "ssh user@host -p 2222", "telnet host 2323", "rdp user@host:3390"
    NSArray* parts = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                       filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    proto = [lower hasPrefix:@"ssh"] ? ZVProtocolSSH
          : [lower hasPrefix:@"rdp"] ? ZVProtocolRDP
          : [lower hasPrefix:@"sftp"] ? ZVProtocolSFTP
          : [lower hasPrefix:@"ftp"] ? ZVProtocolFTP : ZVProtocolTelnet;
    host = @"";
    for (NSUInteger i = 1; i < parts.count; i++) {
      NSString* p = parts[i];
      if ([p isEqualToString:@"-p"] && i + 1 < parts.count)
        port = [parts[++i] intValue];
      else if ([p isEqualToString:@"-l"] && i + 1 < parts.count)
        user = parts[++i];
      else if (host.length == 0)
        host = p;
      else if (proto == ZVProtocolTelnet && port == 0)
        port = p.intValue;
    }
    NSRange at = [host rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound) {
      user = [host substringToIndex:at.location];
      host = [host substringFromIndex:at.location + 1];
    }
    // "host:port" (not an IPv6 address)
    NSRange colon = [host rangeOfString:@":" options:NSBackwardsSearch];
    if ((proto == ZVProtocolRDP || proto == ZVProtocolFTP || proto == ZVProtocolSFTP) &&
        port == 0 && colon.location != NSNotFound &&
        [host rangeOfString:@":"].location == colon.location) {
      port = [host substringFromIndex:colon.location + 1].intValue;
      host = [host substringToIndex:colon.location];
    }
  }

  if (proto == ZVProtocolVNC) {
    ZVBookmark* b = [self bookmarkWithHost:host];
    return b;
  }

  if ([host containsString:@":"] && ![host hasPrefix:@"["])
    host = [NSString stringWithFormat:@"[%@]", host];   // IPv6
  ZVBookmark* b = [self bookmarkWithHost:host];
  b.protocolType = proto;
  b.username = user ?: @"";
  if (proto == ZVProtocolSSH || proto == ZVProtocolSFTP)
    b.sshPort = port > 0 ? port : 22;
  else if (proto == ZVProtocolFTP) {
    b.ftpSecurity = ftps ? (port == 990 ? 2 : 1) : 0;
    b.ftpPort = port > 0 ? port : (b.ftpSecurity == 2 ? 990 : 21);
  }
  else if (proto == ZVProtocolRDP) {
    b.rdpPort = port > 0 ? port : 3389;
    // Windows adapts its desktop to the window, at the Mac's pixel density
    b.scaleMode = ZVScaleNativePixels;
    b.remoteResize = YES;
  }
  else
    b.telnetPort = port > 0 ? port : 23;
  return b;
}

- (instancetype)initWithDictionary:(NSDictionary*)d
{
  self = [self init];
  if (self) {
#define STR(k) if ([d[@#k] isKindOfClass:[NSString class]]) _##k = [d[@#k] copy]
#define NUM(k) if ([d[@#k] isKindOfClass:[NSNumber class]]) _##k = [d[@#k] integerValue]
#define BOOLV(k) if ([d[@#k] isKindOfClass:[NSNumber class]]) _##k = [d[@#k] boolValue]
    STR(uuid); STR(name); STR(host); STR(username); STR(notes); STR(group);
    NUM(quality); NUM(encoding); NUM(jpegQuality); NUM(compressLevel);
    NUM(colorDepth); NUM(scaleMode); NUM(commandKeyMode); NUM(keyboardMode);
    BOOLV(shared); BOOLV(viewOnly); BOOLV(remoteResize); BOOLV(fullScreen);
    BOOLV(autoReconnect); BOOLV(shareClipboard); BOOLV(showRemoteCursor);
    BOOLV(alwaysAskPassword);
    STR(sshUsername); NUM(sshPort); NUM(protocolType); NUM(telnetPort); NUM(rdpPort); NUM(ftpPort); NUM(ftpSecurity);
#undef STR
#undef NUM
#undef BOOLV
    if ([d[@"lastConnected"] isKindOfClass:[NSDate class]])
      _lastConnected = d[@"lastConnected"];
  }
  return self;
}

- (NSDictionary*)dictionaryRepresentation
{
  NSMutableDictionary* d = [@{
    @"uuid": _uuid, @"name": _name, @"host": _host,
    @"username": _username, @"notes": _notes, @"group": _group,
    @"quality": @(_quality), @"encoding": @(_encoding),
    @"jpegQuality": @(_jpegQuality), @"compressLevel": @(_compressLevel),
    @"colorDepth": @(_colorDepth), @"scaleMode": @(_scaleMode),
    @"commandKeyMode": @(_commandKeyMode), @"keyboardMode": @(_keyboardMode),
    @"shared": @(_shared), @"viewOnly": @(_viewOnly),
    @"remoteResize": @(_remoteResize), @"fullScreen": @(_fullScreen),
    @"autoReconnect": @(_autoReconnect), @"shareClipboard": @(_shareClipboard),
    @"showRemoteCursor": @(_showRemoteCursor),
    @"alwaysAskPassword": @(_alwaysAskPassword),
    @"sshUsername": _sshUsername, @"sshPort": @(_sshPort),
    @"protocolType": @(_protocolType), @"telnetPort": @(_telnetPort),
    @"rdpPort": @(_rdpPort), @"ftpPort": @(_ftpPort), @"ftpSecurity": @(_ftpSecurity),
  } mutableCopy];
  if (_lastConnected)
    d[@"lastConnected"] = _lastConnected;
  return d;
}

- (id)copyWithZone:(NSZone*)zone
{
  ZVBookmark* b = [[ZVBookmark alloc] initWithDictionary:[self dictionaryRepresentation]];
  b.isTransient = self.isTransient;
  return b;
}

- (NSString*)quickConnectString
{
  switch (_protocolType) {
  case ZVProtocolVNC:
    return _host;
  case ZVProtocolSSH:
    return [NSString stringWithFormat:@"ssh://%@%@%@", _username.length ? [_username stringByAppendingString:@"@"] : @"",
            _host, (_sshPort && _sshPort != 22) ? [NSString stringWithFormat:@":%ld", (long)_sshPort] : @""];
  case ZVProtocolTelnet:
    return [NSString stringWithFormat:@"telnet://%@%@", _host,
            (_telnetPort && _telnetPort != 23) ? [NSString stringWithFormat:@":%ld", (long)_telnetPort] : @""];
  case ZVProtocolSFTP:
    return [NSString stringWithFormat:@"sftp://%@%@%@", _username.length ? [_username stringByAppendingString:@"@"] : @"",
            _host, (_sshPort && _sshPort != 22) ? [NSString stringWithFormat:@":%ld", (long)_sshPort] : @""];
  case ZVProtocolFTP: {
    NSInteger def = _ftpSecurity == 2 ? 990 : 21;
    NSInteger port = _ftpPort ?: def;
    // Implicit FTPS is written with its port so it reads back the same
    BOOL showPort = port != def || _ftpSecurity == 2;
    return [NSString stringWithFormat:@"%@://%@%@%@", _ftpSecurity ? @"ftps" : @"ftp",
            _username.length ? [_username stringByAppendingString:@"@"] : @"", _host,
            showPort ? [NSString stringWithFormat:@":%ld", (long)port] : @""];
  }
  case ZVProtocolRDP:
    return [NSString stringWithFormat:@"rdp://%@%@%@", _username.length ? [_username stringByAppendingString:@"@"] : @"",
            _host, (_rdpPort && _rdpPort != 3389) ? [NSString stringWithFormat:@":%ld", (long)_rdpPort] : @""];
  }
  return _host;
}

- (NSString*)displayName
{
  if (_name.length > 0)
    return _name;
  return _host;
}

- (NSString*)credentialScope
{
  // Transient connections share the password per host (and protocol)
  if (self.isTransient) {
    switch (_protocolType) {
    case ZVProtocolSSH:    return [NSString stringWithFormat:@"ssh-host:%@:%ld", _host, (long)_sshPort];
    case ZVProtocolTelnet: return [NSString stringWithFormat:@"telnet-host:%@:%ld", _host, (long)_telnetPort];
    case ZVProtocolRDP:    return [NSString stringWithFormat:@"rdp-host:%@:%ld", _host, (long)_rdpPort];
    case ZVProtocolSFTP:   return [NSString stringWithFormat:@"ssh-host:%@:%ld", _host, (long)_sshPort];
    case ZVProtocolFTP:    return [NSString stringWithFormat:@"ftp-host:%@:%ld", _host, (long)_ftpPort];
    default:               return [@"host:" stringByAppendingString:_host];
    }
  }
  return [@"bookmark:" stringByAppendingString:_uuid];
}

- (NSString*)storedPassword
{
  return [ZVKeychain passwordForAccount:[self credentialScope]];
}

- (void)setStoredPassword:(NSString*)password
{
  [ZVKeychain setPassword:password forAccount:[self credentialScope]];
}

@end

#pragma mark - Store

@implementation ZVBookmarkStore {
  NSMutableArray<ZVBookmark*>* _items;
  NSMutableArray<NSDictionary*>* _recent;   // {host, date}
  NSMutableDictionary<NSString*, NSDictionary*>* _devices;
  NSMutableDictionary<NSString*, NSString*>* _scopeIdentities;
  NSMutableArray<NSString*>* _trustedKeys;
  NSMutableDictionary<NSString*, NSString*>* _keyAliases;   // key -> mac
}

+ (instancetype)sharedStore
{
  static ZVBookmarkStore* store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ store = [[ZVBookmarkStore alloc] init]; });
  return store;
}

+ (NSURL*)storageURL
{
  NSURL* dir = [[NSFileManager defaultManager]
                 URLForDirectory:NSApplicationSupportDirectory
                        inDomain:NSUserDomainMask
               appropriateForURL:nil create:YES error:nil];
  // The folder keeps the app's earlier name, so saved connections carry over
  dir = [dir URLByAppendingPathComponent:@"ZeonVNC" isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil error:nil];
  return [dir URLByAppendingPathComponent:@"Connections.plist"];
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _items = [NSMutableArray array];
    _recent = [NSMutableArray array];
    _devices = [NSMutableDictionary dictionary];
    _scopeIdentities = [NSMutableDictionary dictionary];
    _trustedKeys = [NSMutableArray array];
    _keyAliases = [NSMutableDictionary dictionary];
    [self load];
  }
  return self;
}

- (void)load
{
  NSDictionary* root = [NSDictionary dictionaryWithContentsOfURL:[[self class] storageURL]];
  for (NSDictionary* d in root[@"bookmarks"]) {
    if ([d isKindOfClass:[NSDictionary class]])
      [_items addObject:[[ZVBookmark alloc] initWithDictionary:d]];
  }
  for (id r in root[@"recent"]) {
    if ([r isKindOfClass:[NSString class]])          // old format
      [_recent addObject:@{ @"host": r, @"date": [NSDate distantPast] }];
    else if ([r isKindOfClass:[NSDictionary class]] &&
             [r[@"host"] isKindOfClass:[NSString class]])
      [_recent addObject:@{ @"host": r[@"host"],
                            @"date": [r[@"date"] isKindOfClass:[NSDate class]] ? r[@"date"]
                                                                              : [NSDate distantPast] }];
  }
  if ([root[@"devices"] isKindOfClass:[NSDictionary class]])
    [_devices addEntriesFromDictionary:root[@"devices"]];
  if ([root[@"scopeIdentities"] isKindOfClass:[NSDictionary class]])
    [_scopeIdentities addEntriesFromDictionary:root[@"scopeIdentities"]];
  if ([root[@"trustedKeys"] isKindOfClass:[NSArray class]])
    [_trustedKeys addObjectsFromArray:root[@"trustedKeys"]];
  if ([root[@"keyAliases"] isKindOfClass:[NSDictionary class]])
    [_keyAliases addEntriesFromDictionary:root[@"keyAliases"]];
}

- (void)save
{
  NSMutableArray* arr = [NSMutableArray array];
  for (ZVBookmark* b in _items)
    [arr addObject:[b dictionaryRepresentation]];
  NSDictionary* root = @{ @"version": @1, @"bookmarks": arr, @"recent": _recent,
                          @"devices": _devices, @"scopeIdentities": _scopeIdentities,
                          @"trustedKeys": _trustedKeys, @"keyAliases": _keyAliases };
  [root writeToURL:[[self class] storageURL] error:nil];
  [[NSNotificationCenter defaultCenter]
    postNotificationName:ZVBookmarksDidChangeNotification object:self];
}

- (NSArray<ZVBookmark*>*)bookmarks
{
  return [_items sortedArrayUsingComparator:^NSComparisonResult(ZVBookmark* a, ZVBookmark* b) {
    return [[a displayName] localizedStandardCompare:[b displayName]];
  }];
}

- (NSArray<NSString*>*)recentHosts
{
  return [_recent valueForKey:@"host"];
}

- (NSArray<NSDictionary*>*)recentEntries
{
  return [_recent copy];
}

- (void)removeRecentHost:(NSString*)host
{
  NSIndexSet* idx = [_recent indexesOfObjectsPassingTest:^BOOL(NSDictionary* r, NSUInteger i, BOOL* stop) {
    return [r[@"host"] caseInsensitiveCompare:host] == NSOrderedSame;
  }];
  [_recent removeObjectsAtIndexes:idx];
  [self save];
}

- (void)clearRecent
{
  [_recent removeAllObjects];
  [self save];
}

- (void)addBookmark:(ZVBookmark*)bookmark
{
  ZVBookmark* copy = [[ZVBookmark alloc] initWithDictionary:[bookmark dictionaryRepresentation]];
  [_items addObject:copy];
  [self save];
}

- (void)updateBookmark:(ZVBookmark*)bookmark
{
  for (NSUInteger i = 0; i < _items.count; i++) {
    if ([_items[i].uuid isEqualToString:bookmark.uuid]) {
      _items[i] = [[ZVBookmark alloc] initWithDictionary:[bookmark dictionaryRepresentation]];
      [self save];
      return;
    }
  }
  [self addBookmark:bookmark];
}

- (void)removeBookmark:(ZVBookmark*)bookmark
{
  [bookmark setStoredPassword:nil];
  [_scopeIdentities removeObjectForKey:[bookmark credentialScope]];
  NSIndexSet* idx = [_items indexesOfObjectsPassingTest:^BOOL(ZVBookmark* b, NSUInteger i, BOOL* stop) {
    return [b.uuid isEqualToString:bookmark.uuid];
  }];
  [_items removeObjectsAtIndexes:idx];
  [self save];
}

- (ZVBookmark*)bookmarkWithUUID:(NSString*)uuid
{
  for (ZVBookmark* b in _items)
    if ([b.uuid isEqualToString:uuid])
      return [b copy];
  return nil;
}

- (ZVBookmark*)bookmarkMatching:(ZVBookmark*)quick
{
  for (ZVBookmark* b in _items) {
    if (b.protocolType != quick.protocolType ||
        [b.host caseInsensitiveCompare:quick.host] != NSOrderedSame)
      continue;
    if (quick.protocolType == ZVProtocolSSH && b.sshPort != quick.sshPort)
      continue;
    if (quick.protocolType == ZVProtocolTelnet && b.telnetPort != quick.telnetPort)
      continue;
    return [b copy];
  }
  return nil;
}

- (ZVBookmark*)bookmarkMatchingHost:(NSString*)host
{
  for (ZVBookmark* b in _items)
    if (b.protocolType == ZVProtocolVNC && [b.host caseInsensitiveCompare:host] == NSOrderedSame)
      return [b copy];
  return nil;
}

- (void)noteConnectedTo:(ZVBookmark*)bookmark
{
  NSString* entry = [bookmark quickConnectString];
  NSIndexSet* old = [_recent indexesOfObjectsPassingTest:^BOOL(NSDictionary* r, NSUInteger i, BOOL* stop) {
    return [r[@"host"] caseInsensitiveCompare:entry] == NSOrderedSame;
  }];
  [_recent removeObjectsAtIndexes:old];
  [_recent insertObject:@{ @"host": entry, @"date": [NSDate date] } atIndex:0];
  while (_recent.count > 15)
    [_recent removeLastObject];

  if (!bookmark.isTransient) {
    for (ZVBookmark* b in _items)
      if ([b.uuid isEqualToString:bookmark.uuid])
        b.lastConnected = [NSDate date];
  }
  [self save];
}

#pragma mark Devices

- (NSString*)identityForScope:(NSString*)scope
{
  return _scopeIdentities[scope];
}

- (void)setIdentity:(NSString*)identity forScope:(NSString*)scope
{
  if ([_scopeIdentities[scope] isEqualToString:identity])
    return;
  _scopeIdentities[scope] = identity;
  [self save];
}

- (NSDictionary*)deviceInfo:(NSString*)identity
{
  return _devices[identity];
}

- (void)noteDevice:(NSString*)identity name:(NSString*)name host:(NSString*)host
          username:(NSString*)username
{
  NSMutableDictionary* d = [_devices[identity] mutableCopy] ?: [NSMutableDictionary dictionary];
  if (name.length)
    d[@"name"] = name;
  d[@"host"] = host;
  if (username.length)
    d[@"username"] = username;
  d[@"lastSeen"] = [NSDate date];
  _devices[identity] = d;
  [self save];
}

- (NSString*)canonicalIdentityForMAC:(NSString*)mac key:(NSString*)key
{
  if (mac.length)
    return mac;
  if (key.length)
    return _keyAliases[key] ?: key;
  return nil;
}

- (void)setAlias:(NSString*)mac forKey:(NSString*)key
{
  if ([_keyAliases[key] isEqualToString:mac])
    return;
  _keyAliases[key] = mac;
  [self save];
}

- (NSArray<NSString*>*)keysForMAC:(NSString*)mac
{
  return [_keyAliases allKeysForObject:mac];
}

- (BOOL)isTrustedServerKey:(NSString*)fingerprint
{
  return [_trustedKeys containsObject:fingerprint];
}

- (void)trustServerKey:(NSString*)fingerprint
{
  if ([_trustedKeys containsObject:fingerprint])
    return;
  [_trustedKeys addObject:fingerprint];
  [self save];
}

+ (NSString*)passwordForDevice:(NSString*)identity
{
  return [ZVKeychain passwordForAccount:[@"device:" stringByAppendingString:identity]];
}

+ (void)setPassword:(NSString*)password forDevice:(NSString*)identity
{
  [ZVKeychain setPassword:password forAccount:[@"device:" stringByAppendingString:identity]];
}

#pragma mark Import / export

// UltraVNC / TightVNC style .vnc files: an INI file with a [connection]
// section holding host and port.
- (ZVBookmark*)bookmarkFromVNCFile:(NSString*)text name:(NSString*)name
{
  NSString* host = nil;
  NSString* port = nil;
  BOOL viewOnly = NO;
  for (NSString* rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
    NSString* line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound)
      continue;
    NSString* key = [[line substringToIndex:eq.location] lowercaseString];
    NSString* val = [line substringFromIndex:eq.location + 1];
    if ([key isEqualToString:@"host"]) host = val;
    else if ([key isEqualToString:@"port"]) port = val;
    else if ([key isEqualToString:@"viewonly"]) viewOnly = [val integerValue] != 0;
  }
  if (host.length == 0)
    return nil;
  ZVBookmark* b = [[ZVBookmark alloc] init];
  b.name = name;
  b.host = port.length ? [NSString stringWithFormat:@"%@::%@", host, port] : host;
  b.viewOnly = viewOnly;
  return b;
}

- (BOOL)importFromURL:(NSURL*)url error:(NSError**)error
{
  NSData* data = [NSData dataWithContentsOfURL:url options:0 error:error];
  if (data == nil)
    return NO;

  if ([[url.pathExtension lowercaseString] isEqualToString:@"vnc"]) {
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil)
      text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    ZVBookmark* b = [self bookmarkFromVNCFile:text
                                         name:[[url lastPathComponent] stringByDeletingPathExtension]];
    if (b == nil) {
      if (error)
        *error = [NSError errorWithDomain:@"ZeonRemote" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"The file does not contain a host."}];
      return NO;
    }
    [_items addObject:b];
    [self save];
    return YES;
  }

  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if (![json isKindOfClass:[NSArray class]]) {
    if (error && *error == nil)
      *error = [NSError errorWithDomain:@"ZeonRemote" code:2
                               userInfo:@{NSLocalizedDescriptionKey: @"Unrecognised connection list format."}];
    return NO;
  }
  for (NSDictionary* d in json) {
    if (![d isKindOfClass:[NSDictionary class]])
      continue;
    ZVBookmark* b = [[ZVBookmark alloc] initWithDictionary:d];
    if ([self bookmarkWithUUID:b.uuid])
      b.uuid = [NSUUID UUID].UUIDString;
    [_items addObject:b];
  }
  [self save];
  return YES;
}

- (BOOL)exportToURL:(NSURL*)url error:(NSError**)error
{
  NSMutableArray* arr = [NSMutableArray array];
  for (ZVBookmark* b in _items) {
    NSMutableDictionary* d = [[b dictionaryRepresentation] mutableCopy];
    [d removeObjectForKey:@"lastConnected"];
    [arr addObject:d];
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:arr
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                   error:error];
  if (data == nil)
    return NO;
  return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

@end

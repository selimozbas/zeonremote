// ZeonVNC - trust decisions for server keys
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVTrust.h"
#import "ZVBookmark.h"

typedef NS_ENUM(NSInteger, ZVKeyReason) {
  ZVKeyNewDevice = 0,       // never seen this device before
  ZVKeyChanged,             // known device, different key (re-installed?)
  ZVKeyDifferentDevice,     // another device now uses this address
};

@implementation ZVTrust

+ (NSString*)identityForMAC:(NSString*)mac key:(NSString*)key
{
  return [[ZVBookmarkStore sharedStore] canonicalIdentityForMAC:mac key:key];
}

+ (NSString*)displayFingerprint:(NSString*)fingerprint what:(NSString**)what
{
  NSRange colon = [fingerprint rangeOfString:@":"];
  NSString* type = colon.location != NSNotFound ? [fingerprint substringToIndex:colon.location] : @"";
  NSString* hex = colon.location != NSNotFound ? [fingerprint substringFromIndex:colon.location + 1] : fingerprint;

  *what = [type isEqualToString:@"rsa"] ? @"key"
        : [type isEqualToString:@"ssh"] ? @"SSH host key" : @"certificate";

  if ([type isEqualToString:@"ssh"]) {
    // OpenSSH shows SHA256:<base64>, so use the same form
    NSMutableData* d = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
      unsigned int b = 0;
      [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&b];
      uint8_t byte = (uint8_t)b;
      [d appendBytes:&byte length:1];
    }
    NSString* b64 = [[d base64EncodedStringWithOptions:0]
                      stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
    return [@"Fingerprint: SHA256:" stringByAppendingString:b64];
  }

  // First 16 bytes as AB:CD:... are plenty to compare
  NSMutableArray* pairs = [NSMutableArray array];
  for (NSUInteger i = 0; i + 1 < hex.length && pairs.count < 16; i += 2)
    [pairs addObject:[[hex substringWithRange:NSMakeRange(i, 2)] uppercaseString]];
  return [NSString stringWithFormat:@"Fingerprint (SHA-256): %@…", [pairs componentsJoinedByString:@":"]];
}

+ (BOOL)verifyKey:(NSString*)fingerprint mac:(NSString*)mac scope:(NSString*)scope host:(NSString*)host
{
  ZVBookmarkStore* store = [ZVBookmarkStore sharedStore];
  if ([store isTrustedServerKey:fingerprint]) {
    if (mac)
      [store setAlias:mac forKey:fingerprint];
    return YES;
  }

  NSString* bound = [store identityForScope:scope];
  NSString* identity = [store canonicalIdentityForMAC:mac key:fingerprint];

  // Only keys of the same kind count as "changed" (a device has one TLS
  // certificate and one SSH host key)
  NSString* kind = [[fingerprint componentsSeparatedByString:@":"] firstObject];
  NSArray* sameKind = [[store keysForMAC:mac ?: @""] filteredArrayUsingPredicate:
                         [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@",
                          [kind stringByAppendingString:@":"]]];

  ZVKeyReason reason = ZVKeyNewDevice;
  NSString* previousName = nil;
  if (mac && sameKind.count > 0) {
    reason = ZVKeyChanged;
    previousName = [store deviceInfo:mac][@"name"];
  } else if (bound && ![bound isEqualToString:identity]) {
    // With a MAC address we know it's other hardware; without one (remote
    // networks) a new key can't be told apart from an intercepted
    // connection, so warn
    reason = mac ? ZVKeyDifferentDevice : ZVKeyChanged;
    previousName = [store deviceInfo:bound][@"name"];
  }

  NSString* what = nil;
  NSString* shown = [self displayFingerprint:fingerprint what:&what];
  NSString* prev = previousName.length ? [NSString stringWithFormat:@" (“%@”)", previousName] : @"";

  NSAlert* alert = [[NSAlert alloc] init];
  switch (reason) {
  case ZVKeyNewDevice:
    alert.messageText = [NSString stringWithFormat:@"New device at %@", host];
    alert.informativeText = [NSString stringWithFormat:
      @"This is the first connection to this device. Check that the %@ "
      @"fingerprint matches the one shown on the device if you need to be sure.", what];
    alert.alertStyle = NSAlertStyleInformational;
    break;
  case ZVKeyDifferentDevice:
    alert.messageText = [NSString stringWithFormat:@"Different device at %@", host];
    alert.informativeText = [NSString stringWithFormat:
      @"Another device used this address before%@. This one has its own %@. "
      @"This is normal when addresses are assigned by DHCP.", prev, what];
    alert.alertStyle = NSAlertStyleInformational;
    break;
  case ZVKeyChanged:
    alert.messageText = [NSString stringWithFormat:@"The %@ of this device has changed", what];
    alert.informativeText = [NSString stringWithFormat:
      @"The device%@ presents a different %@ than before. This happens when "
      @"it has been re-installed or its server was reconfigured. If neither is "
      @"the case, someone could be intercepting the connection.", prev, what];
    alert.alertStyle = NSAlertStyleWarning;
    break;
  }

  NSMutableString* details = [NSMutableString string];
  if ([mac hasPrefix:@"mac:"])
    [details appendFormat:@"Device: %@\n", [mac substringFromIndex:4]];
  [details appendString:shown];
  alert.informativeText = [NSString stringWithFormat:@"%@\n\n%@", alert.informativeText, details];

  [alert addButtonWithTitle:@"Trust and Connect"];
  [alert addButtonWithTitle:@"Cancel"];
  BOOL ok = [alert runModal] == NSAlertFirstButtonReturn;
  if (ok) {
    [store trustServerKey:fingerprint];
    if (mac)
      [store setAlias:mac forKey:fingerprint];
  }
  return ok;
}

+ (void)noteDeviceForScope:(NSString*)scope mac:(NSString*)mac key:(NSString*)key
                      name:(NSString*)name host:(NSString*)host username:(NSString*)username
{
  ZVBookmarkStore* store = [ZVBookmarkStore sharedStore];
  if (mac && key)
    [store setAlias:mac forKey:key];
  NSString* identity = [store canonicalIdentityForMAC:mac key:key];
  if (!identity)
    return;
  [store setIdentity:identity forScope:scope];
  [store noteDevice:identity name:name host:host username:username];
}

@end

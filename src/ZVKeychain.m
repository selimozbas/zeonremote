// ZeonVNC - minimal Keychain wrapper for connection passwords
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Security/Security.h>

#import "ZVKeychain.h"

// Items are tied to the app's code signature. Items written by earlier
// ad hoc signed development builds used "com.zeonvnc.viewer" and are
// deliberately not read any more, since accessing them would make macOS
// ask for the login keychain password.
static NSString* const kService = @"com.zeonvnc.credentials";

@implementation ZVKeychain

+ (NSMutableDictionary*)queryForAccount:(NSString*)account
{
  return [@{
    (id)kSecClass: (id)kSecClassGenericPassword,
    (id)kSecAttrService: kService,
    (id)kSecAttrAccount: account,
  } mutableCopy];
}

+ (NSString*)passwordForAccount:(NSString*)account
{
  NSMutableDictionary* query = [self queryForAccount:account];
  query[(id)kSecReturnData] = @YES;
  query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
  // Never show the system "allow access" dialog; if an item isn't ours
  // to read, treat it as missing and let the app ask for the password
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  query[(id)kSecUseAuthenticationUI] = (id)kSecUseAuthenticationUIFail;
#pragma clang diagnostic pop

  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query,
                                        &result);
  if (status != errSecSuccess || result == NULL)
    return nil;

  NSData* data = (__bridge_transfer NSData*)result;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)setPassword:(NSString*)password forAccount:(NSString*)account
{
  NSMutableDictionary* query = [self queryForAccount:account];

  if (password == nil || password.length == 0) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
  }

  NSData* data = [password dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary* update = @{ (id)kSecValueData: data };

  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                  (__bridge CFDictionaryRef)update);
  if (status == errSecItemNotFound) {
    query[(id)kSecValueData] = data;
    query[(id)kSecAttrLabel] = [NSString stringWithFormat:@"ZeonVNC (%@)", account];
    query[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleWhenUnlocked;
    status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
  }

  return status == errSecSuccess;
}

+ (void)removeAllPasswords
{
  NSDictionary* query = @{
    (id)kSecClass: (id)kSecClassGenericPassword,
    (id)kSecAttrService: kService,
  };
  // SecItemDelete removes all matching items; repeat in case the
  // keychain implementation deletes one at a time
  for (int i = 0; i < 1000; i++) {
    if (SecItemDelete((__bridge CFDictionaryRef)query) != errSecSuccess)
      break;
  }
}

@end

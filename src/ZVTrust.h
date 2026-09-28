// Zeon Remote - trust decisions for server keys (TLS certificates, RA2 and
// SSH host keys), tracked per device rather than per address
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZVTrust : NSObject

// Returns YES if the key ("x509:<sha256>", "rsa:<sha256>", "ssh:<sha256>")
// is trusted, asking the user if needed (main thread, modal). "scope" is
// the connection's credential scope, "mac" the device's MAC identity if
// known, "host" is shown to the user.
+ (BOOL)verifyKey:(NSString*)fingerprint
              mac:(nullable NSString*)mac
            scope:(NSString*)scope
             host:(NSString*)host;

// Records which device a connection talked to, once it succeeded
+ (void)noteDeviceForScope:(NSString*)scope
                       mac:(nullable NSString*)mac
                       key:(nullable NSString*)key
                      name:(nullable NSString*)name
                      host:(NSString*)host
                  username:(nullable NSString*)username;

// The identity used for per-device passwords: the MAC address on the local
// network, otherwise the (aliased) server key
+ (nullable NSString*)identityForMAC:(nullable NSString*)mac key:(nullable NSString*)key;

@end

NS_ASSUME_NONNULL_END

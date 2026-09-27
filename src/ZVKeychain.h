// ZeonVNC - minimal Keychain wrapper for connection passwords
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZVKeychain : NSObject

+ (nullable NSString*)passwordForAccount:(NSString*)account;
+ (BOOL)setPassword:(nullable NSString*)password forAccount:(NSString*)account;
+ (void)removeAllPasswords;

@end

NS_ASSUME_NONNULL_END

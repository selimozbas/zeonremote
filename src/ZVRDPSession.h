// Zeon Remote - one RDP session. Same interface as a VNC session, so the
// session window, remote view, scaling, full screen and special keys work
// unchanged; the protocol is FreeRDP (src/rdp/ZVRdpClient).
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZVRDPSession : ZVSession
@end

NS_ASSUME_NONNULL_END

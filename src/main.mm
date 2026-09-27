// ZeonVNC - entry point
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <signal.h>

#import "ZVAppDelegate.h"

int main(int argc, const char* argv[])
{
  // Broken connections must not kill the whole application
  signal(SIGPIPE, SIG_IGN);

  @autoreleasepool {
    ZVApplication* app = (ZVApplication*)[ZVApplication sharedApplication];
    ZVAppDelegate* delegate = [[ZVAppDelegate alloc] init];
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}

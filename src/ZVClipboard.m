// ZeonVNC - local pasteboard monitor
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVClipboard.h"

NSNotificationName const ZVLocalClipboardChangedNotification = @"ZVLocalClipboardChangedNotification";

@implementation ZVClipboard {
  NSInteger _changeCount;
  NSTimer* _timer;
}

+ (instancetype)shared
{
  static ZVClipboard* c;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ c = [[ZVClipboard alloc] init]; });
  return c;
}

- (void)start
{
  if (_timer)
    return;
  _changeCount = [NSPasteboard generalPasteboard].changeCount;
  _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                          selector:@selector(poll:)
                                          userInfo:nil repeats:YES];
  _timer.tolerance = 0.2;
}

- (NSString*)currentText
{
  return [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
}

- (void)poll:(NSTimer*)timer
{
  NSInteger cc = [NSPasteboard generalPasteboard].changeCount;
  if (cc == _changeCount)
    return;
  _changeCount = cc;

  NSString* text = [self currentText];
  NSDictionary* info = text ? @{ @"text": text } : @{};
  [[NSNotificationCenter defaultCenter]
    postNotificationName:ZVLocalClipboardChangedNotification object:self userInfo:info];
}

- (void)setRemoteText:(NSString*)text
{
  NSPasteboard* pb = [NSPasteboard generalPasteboard];
  if ([[pb stringForType:NSPasteboardTypeString] isEqualToString:text])
    return;
  [pb clearContents];
  [pb setString:text forType:NSPasteboardTypeString];
  _changeCount = pb.changeCount;
}

@end

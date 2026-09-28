// Zeon Remote - Objective-C interface of the Swift terminal view
// (terminal/Sources/ZVTerminalKit/ZVTerminalView.swift, built on SwiftTerm)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZVTerminalView : NSView

- (instancetype)initWithFrame:(NSRect)frame;

// Bytes typed by the user, to send to the remote side
@property (nonatomic, copy, nullable) void (^onSend)(NSData* data);
// Terminal size changed (columns, rows)
@property (nonatomic, copy, nullable) void (^onResize)(NSInteger columns, NSInteger rows);
@property (nonatomic, copy, nullable) void (^onTitle)(NSString* title);
@property (nonatomic, copy, nullable) void (^onBell)(void);

// Output from the remote side
- (void)feedData:(NSData*)data;
- (void)feedText:(NSString*)text;

@property (nonatomic) CGFloat fontSize;
@property (nonatomic) BOOL optionAsMeta;
@property (nonatomic, readonly) NSInteger columns;
@property (nonatomic, readonly) NSInteger rows;

- (void)focus;
- (void)resetTerminal;

@end

NS_ASSUME_NONNULL_END

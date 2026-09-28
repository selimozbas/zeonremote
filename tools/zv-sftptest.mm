// Zeon Remote - SFTP client check: upload a folder, list, download it back,
// rename and delete. Development only.
//
// Usage: zv-sftptest host port user localdir remotedir downloaddir

#import <Foundation/Foundation.h>
#import "ZVSFTPClient.h"

@interface Trust : NSObject <ZVSFTPClientDelegate>
@end
@implementation Trust
- (BOOL)sftpClient:(ZVSFTPClient*)c trustHostKey:(NSString*)fp display:(NSString*)d
{
  printf("host key %s\n", d.UTF8String);
  return YES;
}
- (BOOL)sftpClient:(ZVSFTPClient*)c wantsPasswordForUser:(NSString**)u password:(NSString**)p
          remember:(BOOL*)r failed:(BOOL)f
{
  printf("password requested (not expected)\n");
  return NO;
}
@end

static void fail(NSError* e)
{
  printf("FAIL: %s\n", e.localizedDescription.UTF8String);
  exit(1);
}

int main(int argc, const char** argv)
{
  @autoreleasepool {
    if (argc != 7)
      return 2;
    NSString* local = @(argv[4]);
    NSString* remote = @(argv[5]);
    NSURL* down = [NSURL fileURLWithPath:@(argv[6])];

    Trust* trust = [[Trust alloc] init];
    ZVSFTPClient* c = [[ZVSFTPClient alloc] initWithHost:@(argv[1]) port:atoi(argv[2])];
    c.delegate = trust;
    c.username = @(argv[3]);

    [c connect:^(NSError* e) {
      if (e) fail(e);
      printf("connected, home %s\n", c.homeDirectory.UTF8String);
      [c createDirectory:remote completion:^(NSError* e2) {
        [c uploadURLs:@[[NSURL fileURLWithPath:local]] toDirectory:remote progress:^(ZVTransferProgress p) {
        } completion:^(NSError* e3) {
          if (e3) fail(e3);
          printf("uploaded\n");
          [c listDirectory:[remote stringByAppendingPathComponent:local.lastPathComponent]
                completion:^(NSArray<ZVRemoteFile*>* files, NSError* e4) {
            if (e4) fail(e4);
            for (ZVRemoteFile* f in files)
              printf("  %s%s %llu\n", f.name.UTF8String, f.isDirectory ? "/" : "", f.size);
            ZVRemoteFile* root = [[ZVRemoteFile alloc] init];
            root.name = local.lastPathComponent;
            root.path = [remote stringByAppendingPathComponent:local.lastPathComponent];
            root.isDirectory = YES;
            [c downloadFiles:@[root] toDirectory:down progress:nil
                  completion:^(NSArray<NSURL*>* urls, NSError* e5) {
              if (e5) fail(e5);
              printf("downloaded to %s\n", urls.firstObject.path.UTF8String);
              ZVRemoteFile* f = files.firstObject;
              [c renameFile:f to:[@"renamed-" stringByAppendingString:f.name] completion:^(NSError* e6) {
                if (e6) fail(e6);
                printf("renamed\n");
                if (getenv("KEEP")) { printf("kept\n"); exit(0); }
                [c removeFiles:@[root] completion:^(NSError* e7) {
                  if (e7) fail(e7);
                  printf("deleted\nOK\n");
                  exit(0);
                }];
              }];
            }];
          }];
        }];
      }];
    }];
    [[NSRunLoop mainRunLoop] run];
  }
  return 0;
}

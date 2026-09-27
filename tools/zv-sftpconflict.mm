// ZeonVNC - checks conflict handling: upload / download the same folder
// twice, answering Keep Both, then Skip, then Replace.
#import <Foundation/Foundation.h>
#import "ZVSFTPClient.h"

@interface T : NSObject <ZVSFTPClientDelegate> @end
@implementation T
- (BOOL)sftpClient:(ZVSFTPClient*)c trustHostKey:(NSString*)f display:(NSString*)d { return YES; }
- (BOOL)sftpClient:(ZVSFTPClient*)c wantsPasswordForUser:(NSString**)u password:(NSString**)p
          remember:(BOOL*)r failed:(BOOL)f { return NO; }
@end

static ZVConflictAction answer;
static int asked;

static void check(NSError* e, const char* what)
{
  if (e) { printf("FAIL %s: %s\n", what, e.localizedDescription.UTF8String); exit(1); }
  printf("%s ok (conflicts asked: %d)\n", what, asked);
  asked = 0;
}

int main(int argc, const char** argv)
{
  @autoreleasepool {
    NSString* local = @(argv[4]);
    NSString* remote = @(argv[5]);
    NSURL* down = [NSURL fileURLWithPath:@(argv[6])];
    T* t = [[T alloc] init];
    ZVSFTPClient* c = [[ZVSFTPClient alloc] initWithHost:@(argv[1]) port:atoi(argv[2])];
    c.delegate = t;
    c.username = @(argv[3]);
    c.conflictHandler = ^ZVConflictAction(ZVTransferConflict* x) {
      asked++;
      return answer;
    };
    NSURL* src = [NSURL fileURLWithPath:local];
    ZVRemoteFile* root = [[ZVRemoteFile alloc] init];
    root.name = local.lastPathComponent;
    root.path = [remote stringByAppendingPathComponent:root.name];
    root.isDirectory = YES;

    answer = ZVConflictReplace;
    [c uploadURLs:@[src] toDirectory:remote progress:nil completion:^(NSError* e) {
      check(e, "first upload");
      answer = ZVConflictKeepBoth;
      [c uploadURLs:@[src] toDirectory:remote progress:nil completion:^(NSError* e2) {
        check(e2, "upload keep both");
        answer = ZVConflictSkip;
        [c uploadURLs:@[src] toDirectory:remote progress:nil completion:^(NSError* e3) {
          check(e3, "upload skip");
          [c downloadFiles:@[root] toDirectory:down progress:nil completion:^(NSArray* u, NSError* e4) {
            check(e4, "first download");
            answer = ZVConflictKeepBoth;
            [c downloadFiles:@[root] toDirectory:down progress:nil completion:^(NSArray* u2, NSError* e5) {
              check(e5, "download keep both");
              answer = ZVConflictStop;
              [c downloadFiles:@[root] toDirectory:down progress:nil completion:^(NSArray* u3, NSError* e6) {
                printf("download stop -> %s\n", e6.code == NSUserCancelledError ? "cancelled ok" : "UNEXPECTED");
                exit(0);
              }];
            }];
          }];
        }];
      }];
    }];
    [[NSRunLoop mainRunLoop] run];
  }
}

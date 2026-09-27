#import <UIKit/UIKit.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *delegate = [[NSProcessInfo processInfo].arguments containsObject:@"--walk-demo-panel"] ? @"WalkDemoAppDelegate" : @"AppDelegate";
        return UIApplicationMain(argc, argv, @"Application", delegate);
    }
}

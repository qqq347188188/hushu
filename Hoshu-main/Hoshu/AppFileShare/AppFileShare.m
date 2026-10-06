// Credit: https://github.com/roothide/RootHidePatcher/AppFileShare.m

#import "AppFileShare.h"

@interface LSApplicationProxy : NSObject
@property(nonatomic, readonly) NSString *applicationIdentifier;
@property(nonatomic, readonly) NSDictionary *groupContainerURLs;

- (NSURL *)bundleURL;
- (NSURL *)containerURL;
- (NSURL *)dataContainerURL;
- (NSString *)teamID;
- (NSString *)vendorName;
- (NSString *)applicationType;
- (NSString *)bundleExecutable;
- (NSString *)bundleIdentifier;
- (id)correspondingApplicationRecord;
- (id)localizedNameForContext:(id)arg1;
- (BOOL)isDeletable;
- (NSSet *)claimedURLSchemes;
- (NSDictionary *)environmentVariables;
+ (id)applicationProxyForIdentifier:(id)arg1;
@end

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (id)operationToOpenResource:(id)arg1
             usingApplication:(id)arg2
                     userInfo:(id)arg3;
@end

static BOOL _openResource(NSString *bundleId, NSURL *resourceURL) {
    LSApplicationProxy *app =
        [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (!app || !app.bundleExecutable) {
        return NO;
    }

    NSOperation *op = [[LSApplicationWorkspace defaultWorkspace]
        operationToOpenResource:resourceURL
               usingApplication:bundleId
                       userInfo:nil];
    if (!op) {
        return NO;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [op start];
    });

    return YES;
}

BOOL isAppAvailable(NSString *bundleId) {
    id app = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    return (app != nil && [app bundleExecutable] != nil);
}

BOOL openURLInApp(NSString *bundleId, NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    return _openResource(bundleId, url);
}

BOOL shareFileToApp(NSString *bundleId, NSString *filePath) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return NO;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    return _openResource(bundleId, fileURL);
}

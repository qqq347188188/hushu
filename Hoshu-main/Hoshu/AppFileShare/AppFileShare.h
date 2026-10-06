// Credit: https://github.com/roothide/RootHidePatcher/AppFileShare.h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL isAppAvailable(NSString *bundleId);
BOOL openURLInApp(NSString *bundleId, NSString *urlString);
BOOL shareFileToApp(NSString *bundleId, NSString *filePath);

NS_ASSUME_NONNULL_END

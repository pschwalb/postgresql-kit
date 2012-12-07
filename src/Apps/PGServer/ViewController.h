
#import <Cocoa/Cocoa.h>
#import <PGServerKit/PGServerKit.h>

////////////////////////////////////////////////////////////////////////////////

@protocol ViewControllerDelegate
-(PGServer* )server;
@end

////////////////////////////////////////////////////////////////////////////////

@interface ViewController : NSViewController

@property id<ViewControllerDelegate> delegate;
@property NSSize frameSize;
@property (readonly) NSString* identifier;

@end
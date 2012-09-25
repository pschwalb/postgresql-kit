
#include <sys/sysctl.h>
#include <pg_config.h>
#import "PGServerKit.h"
#import "PGServer+Private.h"

NSUInteger PGServer2DefaultPort = DEF_PGPORT;

@implementation PGServer2

@dynamic version;

////////////////////////////////////////////////////////////////////////////////
// initialization methods

+(PGServer* )sharedServer {
    static dispatch_once_t pred = 0;
    __strong static id _sharedServer = nil;
    dispatch_once(&pred, ^{
        _sharedServer = [[self alloc] init];
    });
    return _sharedServer;
}

-(id)init {
	self = [super init];
	if(self) {
		[self setDelegate:nil];
		_state = PGServerStateUnknown;
		_hostname = nil;
		_port = 0;
		_pid = -1;
		_dataPath = nil;
		_currentTask = nil;
		_timer = nil;
	}
	return self;
}

////////////////////////////////////////////////////////////////////////////////
// private methods for returning information

+(NSString* )_bundlePath {
	return [[NSBundle bundleForClass:[self class]] bundlePath];
}

+(NSString* )_serverBinary {
	return [[self _bundlePath] stringByAppendingPathComponent:@"Resources/postgresql-current/bin/postgres"];
}

+(NSString* )_initBinary {
	return [[self _bundlePath] stringByAppendingPathComponent:@"Resources/postgresql-current/bin/initdb"];
}

+(NSString* )_libraryPath {
	return [[self _bundlePath] stringByAppendingPathComponent:@"Resources/postgresql-current/lib"];
}

+(NSString* )_dumpBinary {
	return [[self _bundlePath] stringByAppendingPathComponent:@"Resources/postgresql-current/bin/pg_dumpall"];
}

+(NSString* )_superUsername {
	return @"postgres";
}

////////////////////////////////////////////////////////////////////////////////
// set state and send messages to delegate where necessary

-(void)_setState:(PGServerState)state {
	PGServerState oldState = _state;
	_state = state;
	if(_state != oldState && [[self delegate] respondsToSelector:@selector(pgserverStateChange:)]) {
		[[self delegate] performSelectorOnMainThread:@selector(pgserverStateChange:) withObject:self waitUntilDone:YES];
	}
}

////////////////////////////////////////////////////////////////////////////////
// send messages to the delegate

-(void)_delegateMessage:(NSString* )message {
	if([[self delegate] respondsToSelector:@selector(pgserverMessage:)] && [message length]) {
		[[self delegate] performSelectorOnMainThread:@selector(pgserverMessage:) withObject:message waitUntilDone:YES];
	}
	
	// if message is "database system is ready" and server in state PGServerStateStarting
	// then advance state to PGServerStateRunning0.
	// For 8.3 upwards, the message is "database system is ready to accept connections"
	if([message hasSuffix:@"database system is ready"] && [self state]==PGServerStateStarting) {
		[self _setState:PGServerStateRunning0];
	} else if([message hasSuffix:@"database system is ready to accept connections"] && [self state]==PGServerStateStarting) {
		[self _setState:PGServerStateRunning0];
	}
}

-(void)_delegateMessageFromData:(NSData* )theData {
	NSString* theMessage = [[NSString alloc] initWithData:theData encoding:NSUTF8StringEncoding];
	NSArray* theArray = [theMessage componentsSeparatedByString:@"\n"];
	NSEnumerator* theEnumerator = [theArray objectEnumerator];
	NSString* theLine = nil;
	while(theLine = [theEnumerator nextObject]) {
		[self _delegateMessage:[theLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
	}
}

////////////////////////////////////////////////////////////////////////////////
// private method to return the PID of the running postgresql process

-(int)_pidFromPath:(NSString* )thePath {
	NSString* thePidPath = [thePath stringByAppendingPathComponent:@"postmaster.pid"];
	if([[NSFileManager defaultManager] fileExistsAtPath:thePidPath]==NO) {
		// no postmaster.pid file found, therefore no process
		return 0;
	}
	if([[NSFileManager defaultManager] isReadableFileAtPath:thePidPath]==NO) {
		// if postmaster.pid is not readable, return error
		return -1;
	}
	NSDictionary* theAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:thePidPath error:nil];
	if(theAttributes==nil || [theAttributes fileSize] > 1024) {
		// if postmaster.pid file is too large, return error
		return -1;
	}
	NSError* theError = nil;
	NSString* thePidString = [NSString stringWithContentsOfFile:thePidPath encoding:NSUTF8StringEncoding error:&theError];
	if(thePidString==nil) {
		// if postmaster.pid file could not be read, return error
		return -1;
	}
	
	// return the PID as a decimal number
	NSDecimalNumber* thePid = [NSDecimalNumber decimalNumberWithString:thePidString];
	if(thePid==nil) {
		// if postmaster.pid file does not contain a valid decimal number, return
		return -1;
	}
	
	// success - return decimal number
	return [thePid intValue];
}


////////////////////////////////////////////////////////////////////////////////
// determine if process is still running
// see: http://www.cocoadev.com/index.pl?HowToDetermineIfAProcessIsRunning

-(int)_doesProcessExist:(int)thePid {
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, thePid };
	int returnValue = 1;
	size_t count;
	if(sysctl(mib,4,0,&count,0,0) < 0 ) {
		return 0;
	}
	struct kinfo_proc* kp = (struct kinfo_proc* )malloc(count);
	if(kp==nil) return -1;
	if(sysctl(mib,4,kp,&count,0,0) < 0) {
		returnValue = -1;
	} else {
		int nentries = count / sizeof(struct kinfo_proc);
		if(nentries < 1) {
			returnValue = 0;
		}
	}
	free(kp);
	return returnValue;
}

-(void)_stopProcess:(int)thePid {
	// set counter and state
	int count = 0;
	// wait until process identifier is minus one
	do {
		if(count==0) {
			kill(thePid,SIGTERM);
		} else if(count==100) {
			kill(thePid,SIGINT);
		} else if(count==300) {
			kill(thePid,SIGKILL);
		}
		// sleep for 100ms
		[NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		count++;
	} while([self _doesProcessExist:thePid]);
}

////////////////////////////////////////////////////////////////////////////////
// create data path if it doesn't exist

-(BOOL)_createDataPath:(NSString* )thePath {
	// if directory already exists
	BOOL isDirectory = NO;
	if([[NSFileManager defaultManager] fileExistsAtPath:thePath isDirectory:&isDirectory]==NO) {
		// create the directory
		if([[NSFileManager defaultManager] createDirectoryAtPath:thePath withIntermediateDirectories:YES attributes:nil error:nil]==NO) {
			return NO;
		}
	} else if(isDirectory==NO) {
		return NO;
	}
	
	// success - return yes
	return YES;
}

////////////////////////////////////////////////////////////////////////////////
// initialize the database data

-(BOOL)_shouldInitialize {
	// check for postgresql.conf file
	if([[NSFileManager defaultManager] fileExistsAtPath:[_dataPath stringByAppendingPathComponent:@"postgresql.conf"]]==YES) {
		return NO;
	} else {
		return YES;
	}
}

////////////////////////////////////////////////////////////////////////////////
// run a task

-(BOOL)_startTask:(NSString* )theBinary arguments:(NSArray* )theArguments {
	NSParameterAssert(theBinary && [theBinary isKindOfClass:[NSString class]]);
	NSParameterAssert(theArguments && [theArguments isKindOfClass:[NSArray class]]);

	// check for currently running task
	if(_currentTask != nil) {
		return NO;
	}
	
	// set up the task
	NSTask* theTask = [[NSTask alloc] init];
	[theTask setLaunchPath:theBinary];
	[theTask setArguments:theArguments];

	// add dynamic library path
	[theTask setEnvironment:[NSDictionary dictionaryWithObject:[PGServer2 _libraryPath] forKey:@"DYLD_LIBRARY_PATH"]];

	// create a pipe
	NSPipe* thePipe = [[NSPipe alloc] init];
	[theTask setStandardOutput:thePipe];
	[theTask setStandardError:thePipe];

	// add a notification for the pipe's standard out
	NSFileHandle* theFileHandle = [thePipe fileHandleForReading];
	NSNotificationCenter* theNotificationCenter = [NSNotificationCenter defaultCenter];
    [theNotificationCenter addObserver:self
                           selector:@selector(_getTaskData:)
                               name:NSFileHandleReadCompletionNotification
                             object:nil];
	[theFileHandle readInBackgroundAndNotify];

	// now launch the task
	_currentTask = theTask;
	[theTask launch];
	return YES;
	
}

-(void)_getTaskData:(NSNotification* )theNotification {
	NSData* theData = [[theNotification userInfo] objectForKey:@"NSFileHandleNotificationDataItem"];

	[self _delegateMessageFromData:theData];

	if([theData length]) {
		// get more data
		[[theNotification object] readInBackgroundAndNotify];
	}
}

-(BOOL)_startTaskInitialize {
	NSArray* theArguments = [NSArray arrayWithObjects:@"-D",[self dataPath],@"--encoding=UTF8",@"--no-locale",@"-U",[PGServer2 _superUsername],nil];
	return [self _startTask:[PGServer2 _initBinary] arguments:theArguments];
}

-(BOOL)_startTaskServer {
	// set arguments
	NSMutableArray* theArguments = [NSMutableArray arrayWithObjects:@"-D",[self dataPath],nil];
	if([[self hostname] length]) {
		[theArguments addObject:@"-h"];
		[theArguments addObject:[self hostname]];
	} else {
		[theArguments addObject:@"-h"];
		[theArguments addObject:@""];
	}
	if([self port] > 0 && [self port] != PGServer2DefaultPort) {
		[theArguments addObject:@"-p"];
		[theArguments addObject:[NSString stringWithFormat:@"%ld",[self port]]];
	} else {
		_port = PGServer2DefaultPort;
	}

	return [self _startTask:[PGServer2 _serverBinary] arguments:theArguments];
}

////////////////////////////////////////////////////////////////////////////////
// run a timer

-(void)_startTimer {
	if(_timer) {
		[_timer invalidate];
	}
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(_firedTimer:) userInfo:nil repeats:YES];
}

-(void)_firedTimer:(id)sender {
	BOOL isSuccess;
	switch(_state) {
		case PGServerStateIgnition:
			// determine if we need to initialize the data directory
			if([self _shouldInitialize]) {
				[self _setState:PGServerStateInitialize];
			} else {
				[self _setState:PGServerStateInitialized];
			}
			break;
		case PGServerStateInitialize:
			// initialize the data directory
			isSuccess = [self _startTaskInitialize];
			if(isSuccess==NO) {
				[self _setState:PGServerStateStopped];
			} else {
				[self _setState:PGServerStateInitialized];
			}
			break;
		case PGServerStateInitialized:
			// data directory is initialized, so proceed to starting server
			isSuccess = [self _startTaskServer];
			if(isSuccess==NO) {
				[self _setState:PGServerStateStopped];
			} else {
				[self _setState:PGServerStateStarting];
			}
			break;
		case PGServerStateStarting:
			if(_currentTask==nil || [_currentTask isRunning]==NO) {
				// Error occured during startup
				[self _delegateMessage:[NSString stringWithFormat:@"%@ ended with status %d",[_currentTask launchPath],[_currentTask terminationStatus]]];
				[self _setState:PGServerStateStopped];
			}
			break;
		case PGServerStateRunning0:
			// get pid from the task
			_pid = [_currentTask processIdentifier];
			[self _delegateMessage:[NSString stringWithFormat:@"Server started with pid %d",_pid]];
			[self _setState:PGServerStateRunning];
		case PGServerStateRunning:
			// check pid and make sure the process still exists
			if([self _doesProcessExist:_pid]==NO) {
				[self _delegateMessage:@"Server has been stopped"];
				[self _setState:PGServerStateStopping];
			}
			break;			
		case PGServerStateRestart:
			if([self _doesProcessExist:_pid]==NO) {
				[self _delegateMessage:@"Server has been stopped"];
				[self _setState:PGServerStateStopping];
			} else {
				// stop server
				[self _stopProcess:_pid];
				_currentTask = nil;
				[self _setState:PGServerStateIgnition];
			}
			break;
		case PGServerStateStopping:
			// stop server
			[self _stopProcess:_pid];
			[self _setState:PGServerStateStopped];
			break;
		case PGServerStateStopped:
			_hostname = nil;
			_port = 0;
			_pid = -1;
			_dataPath = nil;
			_currentTask = nil;
			[_timer invalidate];
			_timer = nil;
			break;
		default:
			NSAssert(NO,@"Don't know what to do for that state (%@) in _firedTimer",[PGServer2 stateAsString:_state]);
			break;
	}
}

////////////////////////////////////////////////////////////////////////////////
// property implementation

-(NSString* )version {
	NSPipe* theOutPipe = [[NSPipe alloc] init];
	NSTask* theTask = [[NSTask alloc] init];
	[theTask setStandardOutput:theOutPipe];
	[theTask setStandardError:theOutPipe];
	[theTask setLaunchPath:[PGServer2 _serverBinary]];
	[theTask setArguments:[NSArray arrayWithObject:@"--version"]];
	[theTask setEnvironment:[NSDictionary dictionaryWithObject:[PGServer2 _libraryPath] forKey:@"DYLD_LIBRARY_PATH"]];
	
	// get the version number
	[theTask launch];
	
	NSMutableData* theVersion = [NSMutableData data];
	NSData* theData = nil;
	while((theData = [[theOutPipe fileHandleForReading] availableData]) && [theData length]) {
		[theVersion appendData:theData];
	}
	
	// wait until task is actually completed
	[theTask waitUntilExit];
	int theReturnCode = [theTask terminationStatus];
	if(theReturnCode==0 && [theVersion length]) {
		return [[NSString alloc] initWithData:theVersion encoding:NSUTF8StringEncoding];
	} else {
		return nil;
	}
}

////////////////////////////////////////////////////////////////////////////////
// start server method

-(BOOL)startWithDataPath:(NSString* )thePath {
	return [self startWithDataPath:thePath hostname:nil port:0];
}

-(BOOL)startWithDataPath:(NSString* )thePath hostname:(NSString* )hostname port:(NSUInteger)port {
	NSParameterAssert(thePath);

	if([self state]==PGServerStateRunning || [self state]==PGServerStateStarting || [self state]==PGServerStateInitialize || [self state]==PGServerStateInitialized || [self state]==PGServerStateIgnition || [self state]==PGServerStateStopping) {
		return NO;
	}
	
	// if database process is already running, then set this as the state and return NO
	int thePid = [self _pidFromPath:thePath];
	if(thePid > 0) {
		_pid = thePid;
		[self _setState:PGServerStateAlreadyRunning];
		return NO;
	}

	// create the data path if nesessary
	if([self _createDataPath:thePath]==NO) {
		[self _setState:PGServerStateError];
		[self _delegateMessage:[NSString stringWithFormat:@"Unable to create data path: %@",thePath]];
		return NO;
	}
	
	// set the pid to zero and state to ignition
	_pid = 0;
	_dataPath = [thePath copy];
	_hostname = [hostname copy];
	_port = port;
	[self _setState:PGServerStateIgnition];
	
	// start the state machine timer
	[self _startTimer];
	
	// return YES
	return YES;
}

////////////////////////////////////////////////////////////////////////////////
// stop, reload and restart server

-(BOOL)stop {
	if([self state] != PGServerStateRunning && [self state] != PGServerStateAlreadyRunning) {
		return NO;
	}
	if(_pid <= 0) {
		return NO;
	}
	// set state to stop server
	[self _setState:PGServerStateStopping];

	// start the state machine timer
	[self _startTimer];

	// return success
	return YES;
}

-(BOOL)restart {
	if([self state] != PGServerStateRunning && [self state] != PGServerStateAlreadyRunning) {
		return NO;
	}
	if(_pid <= 0) {
		return NO;
	}

	// set state to restart server
	[self _setState:PGServerStateRestart];
	
	// start the state machine timer
	[self _startTimer];
	
	// return success
	return YES;
}

-(BOOL)reload {
	if([self state] != PGServerStateRunning && [self state] != PGServerStateAlreadyRunning) {
		return NO;
	}
	if(_pid <= 0) {
		return NO;
	}
	// send HUP
	kill(_pid,SIGHUP);
	// return success
	return YES;
}

////////////////////////////////////////////////////////////////////////////////
// utility methods

+(NSString* )stateAsString:(PGServerState)theState {
	switch(theState) {
		case PGServerStateStopped:
			return @"PGServerStateStopped";
		case PGServerStateStopping:
			return @"PGServerStateStopping";
		case PGServerStateStarting:
		case PGServerStateIgnition:
			return @"PGServerStateStarting";
		case PGServerStateInitialize:
		case PGServerStateInitialized:
			return @"PGServerStateInitialize";
		case PGServerStateRunning:
		case PGServerStateRunning0:
		case PGServerStateAlreadyRunning:
			return @"PGServerStateRunning";
		case PGServerStateUnknown:
			return @"PGServerStateUnknown";
		case PGServerStateError:
			return @"PGServerStateError";
		default:
			return @"????";
	}
}

@end
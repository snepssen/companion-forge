#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an NSError.
///
/// AVAudioEngine reports misuse (a tap on an input with no format, say) by
/// raising NSException, which Swift cannot catch. Left alone it unwinds through
/// Swift frames, and if AppKit then swallows it the main actor's bookkeeping is
/// left broken: the app crashes later, somewhere unrelated, on the next click.
BOOL TCTry(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END

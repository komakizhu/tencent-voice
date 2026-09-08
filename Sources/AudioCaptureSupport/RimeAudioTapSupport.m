#import "RimeAudioTapSupport.h"

BOOL RimeAudioInstallInputTap(
    AVAudioInputNode *node,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    RimeAudioTapHandler handler,
    NSError * _Nullable * _Nullable error
) {
    @try {
        [node installTapOnBus:0 bufferSize:bufferSize format:format block:handler];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name ?: @"AVAudioEngine tap installation failed";
            *error = [NSError errorWithDomain:@"RimeAudioTapSupport"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}

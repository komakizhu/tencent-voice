#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RimeAudioTapHandler)(AVAudioPCMBuffer *buffer, AVAudioTime * _Nullable when);

FOUNDATION_EXPORT BOOL RimeAudioInstallInputTap(
    AVAudioInputNode *node,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    RimeAudioTapHandler handler,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END

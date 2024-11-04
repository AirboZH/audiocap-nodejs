#include "audio_capture.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <mutex>

#include <CoreMedia/CoreMedia.h>
#include <CoreServices/CoreServices.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include <AudioToolbox/AudioToolbox.h>

#include "napi.h"

static unsigned int stream_count = 0;
static std::mutex stream_count_mutex;

#define CHECK(cond, message)         \
  do {                               \
    if (!(cond)) {                   \
      fprintf(stderr, message "\n"); \
      abort();                       \
    }                                \
  } while (0)

#define HANDLE_EXCEPTIONS(name, value)                                \
  do {                                                                \
    if ((value).IsEmpty()) {                                          \
      auto msg = env.GetAndClearPendingException().Message();         \
      fprintf(stderr, "Uncaught exception in " #name " handler %s\n", \
              msg.c_str());                                           \
    }                                                                 \
  } while (0)

@interface AudioDelegate : NSObject <SCStreamDelegate, SCStreamOutput>

- (id)initWithOptions:(struct AudioOptions)options;
- (void)stop;
- (void)onStart:(SCStream*)stream;
- (void)onStop:(nullable NSError*)error;
- (void)processAudioBuffer:(CMSampleBufferRef)buffer;

@end

@implementation AudioDelegate {
    struct AudioOptions options_;
    dispatch_queue_t audio_queue_;
    SCStream* stream_;
    bool is_stopped_;
    
    // Created on V8 thread
    Napi::Reference<Napi::Buffer<float>>* buffer_;
}

- (id)initWithOptions:(struct AudioOptions)options {
    self = [super init];
    options_ = options;
    buffer_ = new Napi::Reference<Napi::Buffer<float>>();
    audio_queue_ = dispatch_queue_create("mac-audio-capture.audioQueue", 
                                       DISPATCH_QUEUE_SERIAL);
    is_stopped_ = false;

    // 配置音频流过滤器
    SCContentFilter* filter = [self createAudioFilter];
    
    // 配置音频流
    SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
    config.capturesAudio = YES;
    config.excludesCurrentProcessAudio = YES;  // 不捕获当前进程音频
    
    // 创建音频流
    stream_ = [[SCStream alloc] initWithFilter:filter 
                                configuration:config
                                    delegate:self];
    
    NSError* error = nil;
    BOOL success = [stream_ addStreamOutput:self 
                                     type:SCStreamOutputTypeAudio
                       sampleHandlerQueue:audio_queue_
                                  error:&error];
                                  
    if (!success) {
        NSLog(@"Failed to add audio stream output: %@", error);
        return nil;
    }
    
    [stream_ startCaptureWithCompletionHandler:^(NSError* error) {
        if (error) {
            [self onStop:error];
        } else {
            [self onStart:stream_];
        }
    }];

    return self;
}

- (SCContentFilter*)createAudioFilter {
    // 获取系统音频过滤器
    SCShareableContent* shareable = nil;
    NSError* error = nil;
    
    // 同步获取可共享内容
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getCurrentContentsWithCompletionHandler:^(SCShareableContent* content, NSError* err) {
        shareable = content;
        error = err;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    
    if (error) {
        NSLog(@"Failed to get shareable content: %@", error);
        return nil;
    }
    
    // 创建包含所有系统音频的过滤器
    return [[SCContentFilter alloc] initWithDesktopIndependentWindow:nil 
                                                    excludingWindows:@[]];
}

- (void)dealloc {
    options_.on_start.Release();
    options_.on_stop.Release();
    
    auto buffer = buffer_;
    buffer_ = nullptr;
    
    auto rc = options_.on_data.BlockingCall(^(Napi::Env, Napi::Function) {
        delete buffer;
    });
    CHECK(rc == napi_ok, "dealloc tsfn failure");
    options_.on_data.Release();
}

- (void)stop {
    dispatch_async(audio_queue_, ^{
        is_stopped_ = true;
        if (stream_ != nil) {
            [stream_ stopCaptureWithCompletionHandler:^(NSError* error) {
                [self onStop:error];
            }];
        }
    });
}

- (void)onStart:(SCStream*)stream {
    auto rc = options_.on_start.BlockingCall(
        ^(Napi::Env env, Napi::Function callback) {
            HANDLE_EXCEPTIONS(onStart, callback({}));
        });
    CHECK(rc == napi_ok, "onStart tsfn failure");
}

- (void)onStop:(nullable NSError*)error {
    auto rc = options_.on_stop.BlockingCall(^(Napi::Env env,
                                           Napi::Function callback) {
        Napi::Value js_error;
        if (error == nil) {
            js_error = env.Null();
        } else {
            js_error = Napi::Error::New(env, error.localizedDescription.UTF8String)
                          .Value();
        }
        HANDLE_EXCEPTIONS(onStop, callback({js_error}));
    });
    CHECK(rc == napi_ok, "onStop tsfn failure");
}

// SCStreamDelegate
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    [self onStop:error];
}

// SCStreamOutput
- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio) {
        return;
    }
    
    [self processAudioBuffer:sampleBuffer];
}

- (void)processAudioBuffer:(CMSampleBufferRef)buffer {
    // 获取音频格式描述
    CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(buffer);
    if (!format) return;
    
    // 获取音频数据
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        buffer,
        NULL,
        &audioBufferList,
        sizeof(audioBufferList),
        NULL,
        NULL,
        0,
        &blockBuffer);
        
    if (status != noErr) {
        NSLog(@"Failed to get audio buffer list");
        return;
    }
    
    // 获取音频参数
    const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    size_t numSamples = CMSampleBufferGetNumSamples(buffer);
    size_t channelCount = asbd->mChannelsPerFrame;
    
    // 处理音频数据
    auto rc = options_.on_data.BlockingCall(^(Napi::Env env,
                                           Napi::Function callback) {
        // 创建或重用缓冲区
        size_t bufferSize = numSamples * channelCount * sizeof(float);
        float* data = [self getBufferWithEnv:env andSize:bufferSize];
        
        // 复制音频数据
        float* dest = data;
        for (size_t i = 0; i < audioBufferList.mNumberBuffers; i++) {
            const AudioBuffer* srcBuffer = &audioBufferList.mBuffers[i];
            memcpy(dest, srcBuffer->mData, srcBuffer->mDataByteSize);
            dest += srcBuffer->mDataByteSize / sizeof(float);
        }
        
        // 调用JavaScript回调
        auto result = callback({buffer_->Value(),
                              Napi::Number::New(env, numSamples),
                              Napi::Number::New(env, channelCount)});
        HANDLE_EXCEPTIONS(onData, result);
    });
    
    CHECK(rc == napi_ok, "processAudioBuffer tsfn failure");
    
    if (blockBuffer) {
        CFRelease(blockBuffer);
    }
}

- (float*)getBufferWithEnv:(Napi::Env)env andSize:(size_t)size {
    if (!buffer_->IsEmpty() && buffer_->Value().Length() >= size) {
        return static_cast<float*>(buffer_->Value().Data());
    }
    
    size_t rounded_size = size;
    rounded_size += 0xffff;
    rounded_size &= ~0xffff;
    
    buffer_->Reset(Napi::Buffer<float>::New(env, rounded_size), 1);
    return static_cast<float*>(buffer_->Value().Data());
}

@end

void AudioCapture::Initialize(Napi::Env& env, Napi::Object& target) {
    Napi::Function constructor =
        DefineClass(env, "AudioCapture",
                   {
                       InstanceMethod<&AudioCapture::Stop>("stop"),
                   });
    target.Set("AudioCapture", constructor);
}

AudioCapture::AudioCapture(const Napi::CallbackInfo& info)
    : Napi::ObjectWrap<AudioCapture>(info) {
    auto env = info.Env();
    
    if (info.Length() != 1 || !info[0].IsObject()) {
        Napi::Error::New(env, "Missing options object")
            .ThrowAsJavaScriptException();
        return;
    }
    
    auto options = info[0].As<Napi::Object>();
    
    // 验证回调函数
    auto validateCallback = [&](const char* name) -> Napi::Function {
        Napi::Value val = options[name];
        if (!val.IsFunction()) {
            std::string error = "options.";
            error += name;
            error += " is not a function";
            Napi::Error::New(env, error).ThrowAsJavaScriptException();
            return Napi::Function();
        }
        return val.As<Napi::Function>();
    };
    
    auto onStart = validateCallback("onStart");
    auto onStop = validateCallback("onStop"); 
    auto onData = validateCallback("onData");
    
    if (env.IsExceptionPending()) return;
    
    Ref();
    
    // 创建线程安全的函数回调
    auto onStartTsfn = Napi::ThreadSafeFunction::New(
        env, onStart, "mac-audio-capture.onStart", 1, 1,
        [](Napi::Env) { /* cleanup */ });
        
    auto onStopTsfn = Napi::ThreadSafeFunction::New(
        env, onStop, "mac-audio-capture.onStop", 1, 1);
        
    auto onDataTsfn = Napi::ThreadSafeFunction::New(
        env, onData, "mac-audio-capture.onData", 1, 1);
    
    // 创建音频代理
    AudioOptions delegate_options{
        .on_start = onStartTsfn,
        .on_stop = onStopTsfn,
        .on_data = onDataTsfn
    };
    
    delegate_ = [[AudioDelegate alloc] initWithOptions:delegate_options];
}

void AudioCapture::Stop(const Napi::CallbackInfo& info) {
    [delegate_ stop];
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    AudioCapture::Initialize(env, exports);
    return exports;
}

NODE_API_MODULE(mac_audio_capture, Init)
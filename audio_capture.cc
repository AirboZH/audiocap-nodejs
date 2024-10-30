// audio_capture.cc
#include <napi.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <vector>
#include <memory>

class AudioCapture : public Napi::ObjectWrap<AudioCapture>
{
private:
    AudioDeviceID outputDevice;
    AudioUnit audioUnit;
    Napi::ThreadSafeFunction tsfn;
    bool isCapturing;
    Napi::Env env_;

    static OSStatus AudioInputCallback(void *inRefCon,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData)
    {
        AudioCapture *capture = static_cast<AudioCapture *>(inRefCon);
        return capture->HandleAudioInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames);
    }

    struct AudioData
    {
        std::unique_ptr<uint8_t[]> data;
        size_t size;

        AudioData(size_t s) : size(s)
        {
            data = std::make_unique<uint8_t[]>(s);
        }
    };

    OSStatus HandleAudioInput(AudioUnitRenderActionFlags *ioActionFlags,
                              const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber,
                              UInt32 inNumberFrames)
    {
        // 准备音频缓冲区
        AudioBufferList bufferList;
        bufferList.mNumberBuffers = 1;
        bufferList.mBuffers[0].mNumberChannels = 2;                // 立体声
        bufferList.mBuffers[0].mDataByteSize = inNumberFrames * 4; // 2通道 * 2字节/采样

        // 创建临时缓冲区
        auto tempBuffer = std::make_unique<Float32[]>(inNumberFrames * 2);
        bufferList.mBuffers[0].mData = tempBuffer.get();

        // 渲染音频数据
        OSStatus status = AudioUnitRender(audioUnit,
                                          ioActionFlags,
                                          inTimeStamp,
                                          inBusNumber,
                                          inNumberFrames,
                                          &bufferList);

        if (status == noErr && tsfn)
        {
            // 创建持久化的音频数据
            size_t bufferSize = inNumberFrames * 2 * sizeof(Float32);
            auto audioData = std::make_shared<AudioData>(bufferSize);
            memcpy(audioData->data.get(), tempBuffer.get(), bufferSize);

            // 使用共享指针传递数据
            auto callback = [audioData](Napi::Env env, Napi::Function jsCallback)
            {
                auto arrayBuffer = Napi::ArrayBuffer::New(
                    env,
                    audioData->data.get(),
                    audioData->size);
                jsCallback.Call({arrayBuffer});
            };

            tsfn.NonBlockingCall(callback);
        }

        return status;
    }

public:
    static Napi::Object Init(Napi::Env env, Napi::Object exports)
    {
        Napi::Function func = DefineClass(env, "AudioCapture", {InstanceMethod("requestPermission", &AudioCapture::RequestPermission), InstanceMethod("startCapture", &AudioCapture::StartCapture), InstanceMethod("stopCapture", &AudioCapture::StopCapture)});

        Napi::FunctionReference *constructor = new Napi::FunctionReference();
        *constructor = Napi::Persistent(func);
        env.SetInstanceData(constructor);

        exports.Set("AudioCapture", func);
        return exports;
    }

    AudioCapture(const Napi::CallbackInfo &info)
        : Napi::ObjectWrap<AudioCapture>(info),
          isCapturing(false),
          env_(info.Env()) {}

    Napi::Value RequestPermission(const Napi::CallbackInfo &info)
    {
        Napi::Env env = info.Env();
        return Napi::Boolean::New(env, true);
    }

    Napi::Value StartCapture(const Napi::CallbackInfo &info)
    {
        Napi::Env env = info.Env();

        if (isCapturing)
        {
            Napi::Error::New(env, "Already capturing").ThrowAsJavaScriptException();
            return env.Undefined();
        }

        if (info.Length() < 1 || !info[0].IsFunction())
        {
            Napi::Error::New(env, "Callback function required").ThrowAsJavaScriptException();
            return env.Undefined();
        }

        // 创建线程安全的函数回调
        tsfn = Napi::ThreadSafeFunction::New(
            env,
            info[0].As<Napi::Function>(),
            "AudioCallback",
            0,
            1,
            [](Napi::Env)
            {
                // Finalizer callback
            });

        // 获取系统默认输出设备
        UInt32 propertySize = sizeof(AudioDeviceID);
        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};

        OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                     &propertyAddress,
                                                     0,
                                                     NULL,
                                                     &propertySize,
                                                     &outputDevice);

        if (status != noErr)
        {
            Napi::Error::New(env, "Failed to get default output device").ThrowAsJavaScriptException();
            return env.Undefined();
        }

        // 设置音频组件描述
        AudioComponentDescription desc;
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;

        // 创建音频单元
        AudioComponent component = AudioComponentFindNext(NULL, &desc);
        status = AudioComponentInstanceNew(component, &audioUnit);

        if (status != noErr)
        {
            Napi::Error::New(env, "Failed to create audio unit").ThrowAsJavaScriptException();
            return env.Undefined();
        }

        // 禁用输出
        UInt32 enableIO = 0;
        status = AudioUnitSetProperty(audioUnit,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output,
                                      0,
                                      &enableIO,
                                      sizeof(enableIO));

        // 启用输入
        enableIO = 1;
        status = AudioUnitSetProperty(audioUnit,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input,
                                      1,
                                      &enableIO,
                                      sizeof(enableIO));

        // 设置设备
        status = AudioUnitSetProperty(audioUnit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &outputDevice,
                                      sizeof(AudioDeviceID));

        // 设置流格式
        AudioStreamBasicDescription streamFormat;
        streamFormat.mSampleRate = 44100;
        streamFormat.mFormatID = kAudioFormatLinearPCM;
        streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        streamFormat.mFramesPerPacket = 1;
        streamFormat.mChannelsPerFrame = 2;
        streamFormat.mBitsPerChannel = 32;
        streamFormat.mBytesPerPacket = streamFormat.mChannelsPerFrame * sizeof(Float32);
        streamFormat.mBytesPerFrame = streamFormat.mBytesPerPacket;

        status = AudioUnitSetProperty(audioUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      1,
                                      &streamFormat,
                                      sizeof(streamFormat));

        // 设置回调
        AURenderCallbackStruct callbackStruct;
        callbackStruct.inputProc = AudioInputCallback;
        callbackStruct.inputProcRefCon = this;

        status = AudioUnitSetProperty(audioUnit,
                                      kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global,
                                      0,
                                      &callbackStruct,
                                      sizeof(callbackStruct));

        // 初始化并启动音频单元
        status = AudioUnitInitialize(audioUnit);
        status = AudioOutputUnitStart(audioUnit);

        isCapturing = true;
        return env.Undefined();
    }

    Napi::Value StopCapture(const Napi::CallbackInfo &info)
    {
        Napi::Env env = info.Env();

        if (!isCapturing)
        {
            return env.Undefined();
        }

        if (audioUnit)
        {
            AudioOutputUnitStop(audioUnit);
            AudioUnitUninitialize(audioUnit);
            AudioComponentInstanceDispose(audioUnit);
        }

        if (tsfn)
        {
            tsfn.Release();
        }

        isCapturing = false;
        return env.Undefined();
    }

    ~AudioCapture()
    {
        if (isCapturing)
        {
            StopCapture(Napi::CallbackInfo(env_, nullptr));
        }
    }
};

Napi::Object Init(Napi::Env env, Napi::Object exports)
{
    return AudioCapture::Init(env, exports);
}

NODE_API_MODULE(audio_capture, Init)
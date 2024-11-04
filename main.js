const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("path");
const fs = require("fs");
const { log } = require("console");

// 用于音频数据统计的辅助类
class AudioStats {
  constructor() {
    this.sampleCount = 0;
    this.lastLogTime = Date.now();
    this.bytesProcessed = 0;
  }

  update(buffer) {
    this.sampleCount++;
    this.bytesProcessed += buffer.byteLength;
    
    // 每秒记录一次统计信息
    const now = Date.now();
    if (now - this.lastLogTime >= 1000) {
      const duration = (now - this.lastLogTime) / 1000;
      const bytesPerSecond = this.bytesProcessed / duration;
      
      console.log('Audio Statistics:');
      console.log(`- Samples received: ${this.sampleCount}`);
      console.log(`- Bytes processed: ${this.bytesProcessed}`);
      console.log(`- Bytes per second: ${bytesPerSecond.toFixed(2)}`);
      console.log(`- Buffer size: ${buffer.byteLength}`);
      
      // 重置统计
      this.sampleCount = 0;
      this.bytesProcessed = 0;
      this.lastLogTime = now;
    }
  }
}

// 处理 native 模块路径
let audioCaptureModule;
try {
  if (app.isPackaged) {
    const modulePath = path.join(
      process.resourcesPath,
      "audio-capture",
      "audio_capture.node"
    );
    console.log('Loading packaged module from:', modulePath);
    audioCaptureModule = require(modulePath);
  } else {
    console.log('Loading development module');
    audioCaptureModule = require("./build/Release/audio_capture.node");
  }
} catch (error) {
  console.error('Failed to load audio capture module:', error);
  app.quit();
}

const AudioCapture = audioCaptureModule.AudioCapture;
let mainWindow;
let audioCapture;
let isRecording = false;
let audioStats;

function createWindow() {
  console.log('Creating main window');
  mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  });

  mainWindow.loadFile("index.html");

  // 开发环境下打开开发者工具
  if (!app.isPackaged) {
    mainWindow.webContents.openDevTools();
  }

  mainWindow.on('closed', () => {
    console.log('Main window closed');
    mainWindow = null;
  });
}

app.whenReady().then(() => {
  console.log('Application ready, creating window');
  createWindow();

  app.on("activate", function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      console.log('No windows available, creating new window');
      createWindow();
    }
  });
});

app.on("window-all-closed", function () {
  console.log('All windows closed');
  if (process.platform !== "darwin") {
    console.log('Quitting application');
    app.quit();
  }
});

// 处理录音控制
ipcMain.on("start-recording", async (event) => {
  console.log('Received start-recording request');
  
  if (isRecording) {
    console.log('Already recording, ignoring request');
    return;
  }

  try {
    console.log('Initializing audio capture');
    audioCapture = new AudioCapture();
    
    console.log('Requesting permission');
    const hasPermission = await audioCapture.requestPermission();

    if (!hasPermission) {
      console.error('Permission denied');
      event.reply("recording-error", "Permission denied");
      return;
    }

    // 初始化音频统计
    audioStats = new AudioStats();

    console.log('Starting audio capture');
    await audioCapture.startCapture((buffer) => {
      try {
        // 更新音频统计
        audioStats.update(buffer);

        // 发送音频数据到渲染进程
        if (mainWindow && !mainWindow.isDestroyed()) {
          mainWindow.webContents.send("audio-data", buffer);
        }

        // 分析音频数据（可选）
        const audioData = new Float32Array(buffer);
        const maxAmplitude = Math.max(...Array.from(audioData).map(Math.abs));
        if (maxAmplitude > 0.9) {
          console.log('High amplitude detected:', maxAmplitude);
        }

      } catch (error) {
        console.error('Error processing audio data:', error);
      }
    });

    isRecording = true;
    console.log('Recording started successfully');
    event.reply("recording-started");
    
  } catch (error) {
    console.error('Failed to start recording:', error);
    event.reply("recording-error", error.message);
  }
});

ipcMain.on("stop-recording", async (event) => {
  console.log('Received stop-recording request');
  
  if (!isRecording) {
    console.log('Not recording, ignoring request');
    return;
  }

  try {
    console.log('Stopping audio capture');
    await audioCapture.stopCapture();
    isRecording = false;
    audioStats = null;
    console.log('Recording stopped successfully');
    event.reply("recording-stopped");
  } catch (error) {
    console.error('Failed to stop recording:', error);
    event.reply("recording-error", error.message);
  }
});

// 清理资源
app.on("before-quit", () => {
  console.log('Application quitting, cleaning up resources');
  if (audioCapture) {
    try {
      audioCapture.stopCapture();
      console.log('Audio capture stopped successfully');
    } catch (error) {
      console.error('Error stopping audio capture:', error);
    }
  }
});

// 错误处理
process.on('uncaughtException', (error) => {
  console.error('Uncaught exception:', error);
  app.quit();
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection at:', promise, 'reason:', reason);
});
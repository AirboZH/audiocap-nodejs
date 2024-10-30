const { app, BrowserWindow, ipcMain } = require("electron");
const path = require("path");
const fs = require("fs");

// 处理 native 模块路径
let audioCaptureModule;
if (app.isPackaged) {
  const modulePath = path.join(
    process.resourcesPath,
    "audio-capture",
    "audio_capture.node"
  );
  audioCaptureModule = require(modulePath);
} else {
  audioCaptureModule = require("./build/Release/audio_capture.node");
}

const AudioCapture = audioCaptureModule.AudioCapture;
let mainWindow;
let audioCapture;
let isRecording = false;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  });

  mainWindow.loadFile("index.html");
}

app.whenReady().then(() => {
  createWindow();

  app.on("activate", function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", function () {
  if (process.platform !== "darwin") app.quit();
});

// 处理录音控制
ipcMain.on("start-recording", async (event) => {
  if (isRecording) return;

  try {
    audioCapture = new AudioCapture();
    const hasPermission = await audioCapture.requestPermission();

    if (!hasPermission) {
      event.reply("recording-error", "Permission denied");
      return;
    }

    await audioCapture.startCapture((buffer) => {
      // 发送音频数据到渲染进程
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send("audio-data", buffer);
      }
    });

    isRecording = true;
    event.reply("recording-started");
  } catch (error) {
    event.reply("recording-error", error.message);
  }
});

ipcMain.on("stop-recording", async (event) => {
  if (!isRecording) return;

  try {
    await audioCapture.stopCapture();
    isRecording = false;
    event.reply("recording-stopped");
  } catch (error) {
    event.reply("recording-error", error.message);
  }
});

// 清理资源
app.on("before-quit", () => {
  if (audioCapture) {
    audioCapture.stopCapture();
  }
});

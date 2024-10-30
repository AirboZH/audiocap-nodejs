const { ipcRenderer } = require('electron');

const startButton = document.getElementById('startButton');
const stopButton = document.getElementById('stopButton');
const status = document.getElementById('status');
const visualizer = document.getElementById('visualizer');
const canvas = visualizer.getContext('2d');

let isRecording = false;
let animationFrame;

// 更新UI状态
function updateUI(recording) {
    startButton.disabled = recording;
    stopButton.disabled = !recording;
    document.body.classList.toggle('recording', recording);
}

// 绘制音频可视化
function drawAudioData(buffer) {
    const data = new Float32Array(buffer);
    const width = visualizer.width;
    const height = visualizer.height;
    const barWidth = width / data.length;

    canvas.clearRect(0, 0, width, height);
    canvas.fillStyle = '#2196F3';

    for (let i = 0; i < data.length; i++) {
        const x = i * barWidth;
        const barHeight = (Math.abs(data[i]) * height) / 2;
        canvas.fillRect(x, height/2 - barHeight/2, barWidth - 1, barHeight);
    }
}

// 初始化canvas大小
function resizeCanvas() {
    visualizer.width = visualizer.offsetWidth;
    visualizer.height = visualizer.offsetHeight;
}

window.addEventListener('resize', resizeCanvas);
resizeCanvas();

// 事件处理
startButton.addEventListener('click', () => {
    ipcRenderer.send('start-recording');
    status.textContent = 'Starting...';
});

stopButton.addEventListener('click', () => {
    ipcRenderer.send('stop-recording');
    status.textContent = 'Stopping...';
});

// IPC 事件监听
ipcRenderer.on('recording-started', () => {
    isRecording = true;
    updateUI(true);
    status.textContent = 'Recording...';
});

ipcRenderer.on('recording-stopped', () => {
    isRecording = false;
    updateUI(false);
    status.textContent = 'Stopped';
    canvas.clearRect(0, 0, visualizer.width, visualizer.height);
});

ipcRenderer.on('recording-error', (event, error) => {
    isRecording = false;
    updateUI(false);
    status.textContent = `Error: ${error}`;
});

ipcRenderer.on('audio-data', (event, buffer) => {
    if (isRecording) {
        drawAudioData(buffer);
    }
});
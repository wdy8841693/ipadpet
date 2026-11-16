// WhalePet 联调用最小 /api/agent 网关（protocol v2）。
//
//   cd Clients/whalepet_flutter && npm i ws && node tool/mock_agent_server.js
//   端口 8799，令牌 mock-token（Bearer）；health 只回 agent.ready，不带 ASR。
//
// 用途：不接真实 DSH 也能验证「握手 → 命令 → 任务事件 → 回答」整条链路。
// 客户端侧把服务器地址填 http://127.0.0.1:8799，令牌文件写 mock-token 即可。

const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = Number(process.env.PORT || 8799);
const TOKEN = process.env.TOKEN || 'mock-token';

function authorized(req) {
  return (req.headers['authorization'] || '') === `Bearer ${TOKEN}`;
}

const server = http.createServer((req, res) => {
  if (req.url === '/api/health') {
    if (!authorized(req)) {
      res.writeHead(401).end('unauthorized');
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({
      ok: true,
      version: '0.0.0-mock',
      agent: { ready: true },
      asr: false,
      protocols: ['agent-v2'],
    }));
    return;
  }
  res.writeHead(404).end('not found');
});

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/api/agent' || !authorized(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
});

let seq = 0;
const nextEventId = () => `evt-${String(++seq).padStart(6, '0')}`;

wss.on('connection', (ws) => {
  console.log('[mock] client connected');
  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    console.log('[mock] <-', msg.type, msg.text || msg.client_id || '');
    if (msg.type === 'hello') {
      ws.send(JSON.stringify({
        type: 'ready',
        protocol: 2,
        client_id: msg.client_id,
        conversation_id: msg.conversation_id || 'whalepet-main',
        agent_ready: true,
        server_time: new Date().toISOString(),
      }));
      return;
    }
    if (msg.type === 'command') {
      const requestId = msg.request_id;
      const taskId = `whalepet-main:${requestId}`;
      ws.send(JSON.stringify({
        type: 'task',
        event_id: nextEventId(),
        request_id: requestId,
        origin_client_id: msg.client_id,
        task_id: taskId,
        state: 'started',
        text: '开始执行，我这就去办',
      }));
      setTimeout(() => {
        ws.send(JSON.stringify({
          type: 'response',
          event_id: nextEventId(),
          request_id: requestId,
          origin_client_id: msg.client_id,
          display_text: `收到你的话：${msg.text}`,
          speech_text: `收到你的话：${msg.text}`,
          final: true,
        }));
        ws.send(JSON.stringify({
          type: 'task',
          event_id: nextEventId(),
          request_id: requestId,
          origin_client_id: msg.client_id,
          task_id: taskId,
          state: 'finished',
          text: '做完了',
        }));
      }, 600);
    }
  });
  ws.on('close', () => console.log('[mock] client closed'));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[mock] listening on ${PORT}, token=${TOKEN}`);
});

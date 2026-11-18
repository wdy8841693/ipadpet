import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/agent/agent_gateway.dart';

/// 回归：建连失败后必须真的安排退避重试。
///
/// 旧实现在 catch 中调用 _scheduleReconnect()，但当时 _connectInFlight
/// 仍为 true，调度函数直接 return；结果服务恢复后客户端仍一直断开。
void main() {
  late HttpServer server;
  late WebSocketAgentGateway gateway;
  int healthCalls = 0;
  final List<WebSocket> sockets = <WebSocket>[];

  setUp(() async {
    healthCalls = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/api/health') {
        healthCalls += 1;
        // 第一次故意失败；重连后的健康检查必须成功。
        request.response.statusCode = healthCalls == 1 ? 503 : 200;
        if (healthCalls == 1) {
          request.response.write('server warming up');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'ok': true,
            'agent': <String, dynamic>{'ready': true},
          }));
        }
        await request.response.close();
        return;
      }
      if (request.uri.path == '/api/agent' &&
          request.headers.value('upgrade')?.toLowerCase() == 'websocket') {
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((_) {});
        socket.add(jsonEncode(<String, dynamic>{
          'type': 'ready',
          'protocol': 2,
          'client_id': 'test-client',
          'conversation_id': 'whalepet-main',
          'agent_ready': true,
          'server_time': '2026-11-17T00:00:00Z',
        }));
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });
  });

  tearDown(() async {
    await gateway.dispose();
    for (final WebSocket socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    await server.close(force: true);
  });

  test('首次建连失败后自动重连成功', () async {
    gateway = WebSocketAgentGateway(
      serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'test-token',
      clientId: 'test-client',
      healthTimeout: const Duration(seconds: 2),
    );

    final Future<AgentConnectionState> connected = gateway.states
        .firstWhere((AgentConnectionState s) =>
            s == AgentConnectionState.connected)
        .timeout(const Duration(seconds: 6));

    await gateway.connect();
    await connected;

    expect(healthCalls, greaterThanOrEqualTo(2));
    expect(gateway.state, AgentConnectionState.connected);
  }, timeout: const Timeout(Duration(seconds: 10)));
}

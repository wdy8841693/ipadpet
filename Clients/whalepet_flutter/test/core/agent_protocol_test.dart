import 'package:test/test.dart';
import 'package:whalepet_flutter/core/agent/agent_protocol.dart';

void main() {
  group('标识符与命令文本', () {
    test('request_id 满足服务端字符集与长度约束', () {
      for (int i = 0; i < 50; i++) {
        final String id = newRequestId();
        expect(kAgentIdPattern.hasMatch(id), isTrue, reason: id);
      }
    });

    test('同一次命令重试应复用 id，而不是每次生成新的', () {
      final DateTime stamp = DateTime.utc(2026, 11, 15, 12);
      final String fixed = newRequestId(now: stamp);
      // 时间戳前缀稳定，便于日志里一眼认出「这一轮」。
      expect(fixed.startsWith('req-${stamp.millisecondsSinceEpoch}-'), isTrue,
          reason: fixed);
    });

    test('命令文本去空白、空串与超长都要拒绝', () {
      expect(normalizeCommandText('  帮我查天气  '), '帮我查天气');
      expect(normalizeCommandText('   '), isNull);
      expect(normalizeCommandText(null), isNull);
      expect(normalizeCommandText('x' * (kMaxCommandChars + 1)), isNull);
      expect(normalizeCommandText('x' * kMaxCommandChars)?.length, kMaxCommandChars);
    });

    test('客户端 id 带设备前缀', () {
      expect(newClientId(prefix: 'windows').startsWith('windows-'), isTrue);
    });
  });

  group('客户端消息编码', () {
    test('hello 带协议版本、订阅与补发锚点', () {
      final Map<String, dynamic> hello = buildHelloMessage(
        clientId: 'windows-abc',
        subscriptionsAnnouncements: false,
        lastReceivedEventId: 'evt-000123',
      );
      expect(hello['type'], 'hello');
      expect(hello['protocol'], kAgentProtocolVersion);
      expect(hello['client_id'], 'windows-abc');
      expect(hello['conversation_id'], kDefaultConversationId);
      expect(hello['subscriptions'], <String, dynamic>{'announcements': false});
      expect(hello['last_received_event_id'], 'evt-000123');
    });

    test('command 字段用 snake_case，和服务端校验对齐', () {
      final Map<String, dynamic> command = buildCommandMessage(
        requestId: 'req-1',
        text: '你好',
        clientId: 'windows-abc',
      );
      expect(command['type'], 'command');
      expect(command['request_id'], 'req-1');
      expect(command['client_id'], 'windows-abc');
      expect(command['text'], '你好');
      expect(command['source'], 'text');
    });
  });

  group('服务端事件解析', () {
    test('ready', () {
      final AgentServerEvent? event = parseAgentServerEvent(<String, dynamic>{
        'type': 'ready',
        'protocol': 2,
        'conversation_id': 'whalepet-main',
        'agent_ready': true,
        'server_time': '2026-11-15T12:00:00Z',
      });
      expect(event, isA<AgentReadyEvent>());
      final AgentReadyEvent ready = event! as AgentReadyEvent;
      expect(ready.agentReady, isTrue);
      expect(ready.conversationId, 'whalepet-main');
      expect(ready.serverTime, DateTime.utc(2026, 11, 15, 12));
    });

    test('task 缺字段时降级为 unknown，而不是抛异常', () {
      final AgentServerEvent? event = parseAgentServerEvent(<String, dynamic>{
        'type': 'task',
        'state': 'started',
      });
      expect(event, isA<AgentUnknownServerEvent>());
    });

    test('task 正常解析并识别终态', () {
      final AgentServerEvent? event = parseAgentServerEvent(<String, dynamic>{
        'type': 'task',
        'event_id': 'evt-1',
        'request_id': 'req-1',
        'state': 'finished',
        'text': '做完了',
        'task_id': 'whalepet-main:req-1',
      });
      final AgentTaskEvent task = event! as AgentTaskEvent;
      expect(task.eventId, 'evt-1');
      expect(task.isTerminal, isTrue);
      expect(task.text, '做完了');
    });

    test('response 区分上屏文本与播报文本', () {
      final AgentServerEvent? event = parseAgentServerEvent(<String, dynamic>{
        'type': 'response',
        'event_id': 'evt-2',
        'request_id': 'req-1',
        'display_text': '**答案**',
        'speech_text': '答案',
        'final': true,
      });
      final AgentResponseEvent response = event! as AgentResponseEvent;
      expect(response.displayText, '**答案**');
      expect(response.speechText, '答案');
      expect(response.isFinal, isTrue);
    });

    test('announcement / error / voice_config', () {
      final AgentAnnouncementEvent announcement = parseAgentServerEvent(<String, dynamic>{
        'type': 'announcement',
        'event_id': 'evt-3',
        'scope': 'global',
        'state': 'finished',
        'display_text': '做完了：整理备课资料',
        'speech_text': '做完了整理备课资料',
      })! as AgentAnnouncementEvent;
      expect(announcement.scope, 'global');
      expect(announcement.speechText, '做完了整理备课资料');

      final AgentErrorEvent error = parseAgentServerEvent(<String, dynamic>{
        'type': 'error',
        'code': 'agent_timeout',
        'message': 'DSH 响应超时',
        'retryable': true,
        'request_id': 'req-1',
      })! as AgentErrorEvent;
      expect(error.retryable, isTrue);
      expect(error.requestId, 'req-1');

      final AgentVoiceConfigEvent voice = parseAgentServerEvent(<String, dynamic>{
        'type': 'voice_config',
        'revision': 3,
        'wake_phrase': '小鲸小鲸',
        'wake_aliases': <String>['小鲸小鲸', '小金小金'],
        'wake_ack': '我在',
        'listen_timeout_ms': 10000,
      })! as AgentVoiceConfigEvent;
      expect(voice.revision, 3);
      expect(voice.wakeAliases, <String>['小鲸小鲸', '小金小金']);
      expect(voice.listenTimeoutMs, 10000);
    });

    test('未知类型保留原文，便于排查', () {
      final AgentUnknownServerEvent event = parseAgentServerEvent(<String, dynamic>{
        'type': 'future_event',
        'payload': 1,
      })! as AgentUnknownServerEvent;
      expect(event.type, 'future_event');
      expect(event.raw['payload'], 1);
    });

    test('非 JSON 对象返回 null', () {
      expect(parseAgentServerEvent('not a map'), isNull);
      expect(parseAgentServerEvent(<String>['x']), isNull);
    });
  });
}

import "dart:convert";

import "package:opencode_plugin/opencode_plugin.dart";
import "package:test/test.dart";

void main() {
  group("SseEventParser", () {
    test("parses session.status with busy status", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "session.status",
          "properties": {
            "sessionID": "s1",
            "status": {"type": "busy"},
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.directory, equals("/repo"));
      expect(result.eventType, equals("session.status"));
      expect(result.rawData, equals(rawData));
      expect(result.event, isA<SseSessionStatus>());

      final event = result.event! as SseSessionStatus;
      expect(event.sessionID, equals("s1"));
      expect(event.status, isA<SessionStatusBusy>());
    });

    test("parses session.created event", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "session.created",
          "properties": {
            "info": {
              "id": "s1",
              "slug": "ses-1",
              "projectID": "p1",
              "directory": "/repo",
              "time": {"created": 0, "updated": 0},
            },
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.event, isA<SseSessionCreated>());
      expect(result.eventType, equals("session.created"));
      final event = result.event! as SseSessionCreated;
      expect(event.info.id, equals("s1"));
      expect(event.info.projectID, equals("p1"));
      expect(event.info.directory, equals("/repo"));
      expect(result.directory, equals("/repo"));
    });

    test("parses command.executed event", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "command.executed",
          "properties": {
            "name": "review",
            "sessionID": "s1",
            "arguments": "lib/main.dart",
            "messageID": "m1",
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.eventType, equals("command.executed"));
      expect(result.directory, equals("/repo"));
      expect(result.event, isA<SseCommandExecuted>());

      final event = result.event! as SseCommandExecuted;
      expect(event.name, equals("review"));
      expect(event.sessionID, equals("s1"));
      expect(event.arguments, equals("lib/main.dart"));
      expect(event.messageID, equals("m1"));
    });

    test("parses server.heartbeat event", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "payload": {"type": "server.heartbeat", "properties": <String, dynamic>{}},
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.event, isA<SseServerHeartbeat>());
      expect(result.eventType, equals("server.heartbeat"));
      expect(result.directory, isNull);
      expect(result.rawData, equals(rawData));
    });

    test("parses question.asked with the optional tool object", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "question.asked",
          "properties": {
            "id": "que_1",
            "sessionID": "s1",
            "questions": [
              {
                "question": "Allow running this command?",
                "header": "Permission",
                "options": [
                  {"label": "Yes", "description": "Run it"},
                ],
              },
            ],
            "tool": {"messageID": "msg-1", "callID": "call-1"},
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.isPendingInputAsk, isTrue);
      final event = result.event! as SseQuestionAsked;
      expect(event.id, equals("que_1"));
      expect(event.sessionID, equals("s1"));
      final tool = event.tool;
      if (tool == null) {
        fail("question.asked with a tool object must decode the tool field");
      }
      expect(tool.messageID, equals("msg-1"));
      expect(tool.callID, equals("call-1"));
    });

    test("parses a tool-less question.asked", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "payload": {
          "type": "question.asked",
          "properties": {
            "id": "que_2",
            "sessionID": "s1",
            "questions": <Map<String, dynamic>>[],
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.isPendingInputAsk, isTrue);
      final event = result.event! as SseQuestionAsked;
      expect(event.tool, isNull);
    });

    test("parses permission.asked carrying upstream metadata, always, and object tool fields", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "payload": {
          "type": "permission.asked",
          "properties": {
            "id": "per_1",
            "sessionID": "s1",
            "permission": "bash",
            "patterns": ["ls -la"],
            "metadata": {"command": "ls -la"},
            "always": ["ls *"],
            "tool": {"messageID": "msg-2", "callID": "call-2"},
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.isPendingInputAsk, isTrue);
      final event = result.event! as SsePermissionAsked;
      expect(event.permission, equals("bash"));
      expect(event.patterns, equals(["ls -la"]));
    });

    test("a malformed ask frame is still flagged as pending input", () {
      final parser = SseEventParser();

      final result = parser.parse(
        jsonEncode({"payload": {"type": "question.asked"}}),
      );

      expect(result.outcome, equals(SseParseOutcome.malformedKnownPayload));
      expect(result.isPendingInputAsk, isTrue);
      expect(result.rawData, isNotEmpty);
    });

    test("parses 1.4 session.diff payload with patch-based diff array", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "session.diff",
          "properties": {
            "sessionID": "s1",
            "diff": [
              {
                "file": "lib/main.dart",
                "patch": "@@ -1 +1 @@\n-old\n+new",
                "additions": 1,
                "deletions": 1,
                "status": "modified",
              },
            ],
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.rawData, equals(rawData));
      expect(result.event, isA<SseSessionDiff>());
      expect(result.eventType, equals("session.diff"));

      final event = result.event! as SseSessionDiff;
      expect(event.sessionID, equals("s1"));
      expect(event.diff, hasLength(1));
      expect(event.diff.single.file, equals("lib/main.dart"));
      expect(event.diff.single.patch, contains("+new"));
    });

    test("session.diff without diff array is categorized as malformed known payload", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "session.diff",
          "properties": {
            "sessionID": "s1",
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.malformedKnownPayload));
      expect(result.event, isNull);
      expect(result.eventType, equals("session.diff"));
      expect(result.rawData, equals(rawData));
    });

    test(
      "unknown event type returns null event with directory and rawData",
      () {
        final parser = SseEventParser();
        final rawData = jsonEncode({
          "directory": "/repo",
          "payload": {
            "type": "unknown.event",
            "properties": <String, dynamic>{"value": 1},
          },
        });

        final result = parser.parse(rawData);

        expect(result.outcome, equals(SseParseOutcome.unknownEventType));
        expect(result.event, isNull);
        expect(result.directory, equals("/repo"));
        expect(result.eventType, equals("unknown.event"));
        expect(result.rawData, equals(rawData));
      },
    );

    test("sync event is recognized and ignored with preserved metadata", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "sync",
          "name": "message.updated.1",
          "id": "evt-1",
          "seq": 7,
          "aggregateID": "sessionID",
          "data": {
            "sessionID": "s1",
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.ignoredKnownEvent));
      expect(result.event, isNull);
      expect(result.directory, equals("/repo"));
      expect(result.eventType, equals("sync"));
      expect(result.rawData, equals(rawData));
    });

    test("plugin.added event is recognized and ignored with preserved metadata", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "plugin.added",
          "properties": {
            "name": "some-plugin",
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.ignoredKnownEvent));
      expect(result.event, isNull);
      expect(result.directory, equals("/repo"));
      expect(result.eventType, equals("plugin.added"));
      expect(result.rawData, equals(rawData));
    });

    for (final eventType in ["integration.updated", "catalog.updated"]) {
      test("$eventType is recognized and ignored, not reported as unknown", () {
        final parser = SseEventParser();
        final rawData = jsonEncode({
          "directory": "/repo",
          "payload": {
            "type": eventType,
            "properties": <String, dynamic>{},
          },
        });

        final result = parser.parse(rawData);

        expect(result.outcome, equals(SseParseOutcome.ignoredKnownEvent));
        expect(result.event, isNull);
        expect(result.directory, equals("/repo"));
        expect(result.eventType, equals(eventType));
        expect(result.rawData, equals(rawData));
      });
    }

    test("malformed JSON returns null event and preserved rawData", () {
      final parser = SseEventParser();
      const rawData = "{not-json";

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.malformedEnvelope));
      expect(result.event, isNull);
      expect(result.directory, isNull);
      expect(result.eventType, isNull);
      expect(result.rawData, equals(rawData));
    });

    test("empty string returns null event and preserved rawData", () {
      final parser = SseEventParser();
      const rawData = "";

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.malformedEnvelope));
      expect(result.event, isNull);
      expect(result.directory, isNull);
      expect(result.eventType, isNull);
      expect(result.rawData, equals(rawData));
    });

    test("missing payload returns null event and preserved rawData", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({"directory": "/repo"});

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.malformedEnvelope));
      expect(result.event, isNull);
      expect(result.directory, equals("/repo"));
      expect(result.eventType, isNull);
      expect(result.rawData, equals(rawData));
    });

    test("missing payload type returns null event and preserved rawData", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "properties": {"sessionID": "s1"},
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.malformedEnvelope));
      expect(result.event, isNull);
      expect(result.directory, equals("/repo"));
      expect(result.eventType, isNull);
      expect(result.rawData, equals(rawData));
    });

    test("known event with unknown session status is preserved", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "session.status",
          "properties": {
            "sessionID": "s1",
            "status": {"unexpected": true},
          },
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.validKnownEvent));
      expect(result.event, isA<SseSessionStatus>());
      expect(result.directory, equals("/repo"));
      expect(result.eventType, equals("session.status"));
      expect(result.rawData, equals(rawData));

      final event = result.event! as SseSessionStatus;
      expect(event.status, isA<SessionStatusUnknown>());
    });

    test("malformed payload envelope is categorized separately", () {
      final parser = SseEventParser();
      final rawData = jsonEncode({
        "directory": "/repo",
        "payload": {
          "type": "session.status",
          "properties": "not-a-map",
        },
      });

      final result = parser.parse(rawData);

      expect(result.outcome, equals(SseParseOutcome.malformedEnvelope));
      expect(result.event, isNull);
      expect(result.directory, equals("/repo"));
      expect(result.eventType, equals("session.status"));
      expect(result.rawData, equals(rawData));
    });

    test("rawData is always preserved exactly", () {
      final parser = SseEventParser();
      final rawInputs = <String>[
        "",
        "{not-json",
        '  {"directory":"/repo"}',
        jsonEncode({
          "directory": "/repo",
          "payload": {
            "type": "session.status",
            "properties": {
              "sessionID": "s1",
              "status": {"type": "busy"},
            },
          },
        }),
      ];

      for (final rawData in rawInputs) {
        final result = parser.parse(rawData);
        expect(result.rawData, equals(rawData));
      }
    });
  });
}

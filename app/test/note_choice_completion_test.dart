import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:class_notes_assistant/data/api_client.dart';
import 'package:class_notes_assistant/data/api_result.dart';
import 'package:class_notes_assistant/data/note_check_controller.dart';

class Peer extends ApiClient {
  Peer() : super(baseUrl: 'http://computer.test');
  bool pending = true;
  bool offline = false;
  int scans = 0, polls = 0;
  List<Map<String, dynamic>> get choices => [
        {'id': 'decision', 'status': pending ? 'pending' : 'completed'}
      ];
  @override
  Future<ApiResult<List<Map<String, dynamic>>>> getNoteChecks() async {
    scans++;
    if (offline) return const ApiResult.failed('暂时离线');
    return ApiResult.ok([
      {
        'device_id': 'device',
        'folder_id': 'folder',
        'vault_id': 'vault',
        'same': 0,
        'only_on_phone': <String>[],
        'only_on_computer': <String>[],
        'different': <String>['a.md'],
        'choices': choices,
        'phone_checked_at': '2026-10-19T00:00:00Z',
        'computer_checked_at': '2026-10-19T00:00:00Z',
      }
    ]);
  }

  @override
  Future<ApiResult<List<Map<String, dynamic>>>> getNoteChoices(
      Map<String, String> scope) async {
    polls++;
    return ApiResult.ok(choices);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
      'completion refresh failure retries before clearing pending refresh',
      (tester) async {
    final peer = Peer();
    final checks = NoteCheckController(api: peer, android: false);
    checks.start();
    await tester.pump();
    peer.pending = false;
    peer.offline = true;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(checks.error, contains('离线'));
    expect(checks.localRevision.value, 0);
    peer.offline = false;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(checks.error, isNull);
    expect(checks.localRevision.value, 1);
    expect(peer.scans, 3);
    final polls = peer.polls;
    await tester.pump(const Duration(seconds: 30));
    expect(peer.polls, polls);
    checks.dispose();
  });
  testWidgets(
      'Windows only polls queued metadata and refreshes notes once on completion',
      (tester) async {
    final peer = Peer();
    final checks = NoteCheckController(api: peer, android: false);
    checks.start();
    await tester.pump();
    expect(peer.scans, 1);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(peer.polls, 1);
    expect(peer.scans, 1); // Waiting never scans the note directory.
    peer.pending = false;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(peer.scans, 2);
    expect(checks.localRevision.value, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(peer.polls, 2); // No recurring poll after completion.
    expect(peer.scans, 2);
    checks.dispose();
  });
  testWidgets(
      'background and dispose cancel pending polls; resume keeps daily scan limit',
      (tester) async {
    final peer = Peer();
    final checks = NoteCheckController(api: peer, android: false);
    checks.start();
    await tester.pump();
    checks.setForeground(false);
    await tester.pump(const Duration(seconds: 30));
    expect(peer.polls, 0);
    checks.setForeground(true);
    await tester.pump();
    expect(peer.scans, 1);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(peer.polls, 1);
    checks.dispose();
    await tester.pump(const Duration(seconds: 30));
    expect(peer.polls, 1);
  });
}

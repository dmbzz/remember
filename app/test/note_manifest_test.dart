import 'package:class_notes_assistant/platform/local_notes_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按相对路径和内容摘要找出两端不一致的笔记', () {
    final diff = NoteManifestDiff.compare([
      {'relative_path': '普通物理/波动.md', 'sha256': 'a'},
      {'relative_path': '线性代数/矩阵.md', 'sha256': 'b'},
      {'relative_path': '电路/电压.md', 'sha256': 'c'},
    ], [
      {'path': '普通物理/波动.md', 'sha256': 'a'},
      {'path': '线性代数/矩阵.md', 'sha256': 'changed'},
      {'path': '工程力学/扭矩.md', 'sha256': 'd'},
    ]);
    expect(diff.same, 1);
    expect(diff.onlyOnPhone, ['电路/电压.md']);
    expect(diff.onlyOnComputer, ['工程力学/扭矩.md']);
    expect(diff.different, ['线性代数/矩阵.md']);
  });
}

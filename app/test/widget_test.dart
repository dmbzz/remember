// Flutter 应用冒烟测试。
//
// 说明：`flutter create` 生成的默认模板引用了不存在的 `MyApp`（analyze 报 error），
// 已替换为对本项目**纯逻辑工具** `WeeksFormatter` 的单元测试——无需 Widget 绑定/网络。
import 'package:flutter_test/flutter_test.dart';

import 'package:class_notes_assistant/core/weeks.dart';

void main() {
  group('WeeksFormatter（周次集合归一与显示，v3.3）', () {
    test('normalize 兼容 list[int] 与旧字符串', () {
      expect(WeeksFormatter.normalize([1, 2, 2, 3]), [1, 2, 3]);
      expect(WeeksFormatter.normalize('1-3, 5'), [1, 2, 3, 5]);
      expect(WeeksFormatter.normalize(const []), isEmpty);
    });

    test('compress 压缩连续区间', () {
      expect(WeeksFormatter.compress([1, 2, 3, 5, 6, 9]), '1-3, 5-6, 9');
    });

    test('describe 识别单周/双周与断档', () {
      final oddWeeks = [for (var w = 1; w <= 19; w += 2) w];
      expect(WeeksFormatter.describe(oddWeeks), '单周 1-19');
      expect(WeeksFormatter.describe([8, 10, 12]), '双周 8-12');
      expect(WeeksFormatter.describe('1-5, 7-12'), '1-5, 7-12');
      expect(WeeksFormatter.describe(const []), '—');
    });
  });
}

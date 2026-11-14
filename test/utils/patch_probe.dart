import 'package:flutter_test/flutter_test.dart';

/// getx 的转场补丁（`lib/scripts/getx_ios_transition.patch`）是否已应用。
///
/// 补丁未应用时，`_DisplayCornerClip` 不在组件树里，相关测试应跳过而不是失败：
/// `flutter test` 不会自动打补丁，需要先执行 `lib/scripts/patch.ps1 android`。
bool patchApplied(WidgetTester tester) => tester.allWidgets.any(
  (w) => w.runtimeType.toString() == '_DisplayCornerClip',
);

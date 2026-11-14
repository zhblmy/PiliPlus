import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/patch_probe.dart';

const _keyA = Key('pageA');
const _keyB = Key('pageB');
const _keyC = Key('pageC');

const _radii = BorderRadius.all(Radius.circular(24));

/// 模拟 `MyApp._builder`：界面缩放会伪造 `devicePixelRatio`。
Widget _app({
  double uiScale = 1.0,
  ValueListenable<BorderRadius?>? radiiListenable,
}) {
  Widget wrap(BuildContext context, Widget? child) {
    final mq = MediaQuery.of(context);
    final radii = radiiListenable?.value ?? _radii;
    return MediaQuery(
      data: mq
          .copyWith(
            devicePixelRatio: mq.devicePixelRatio * uiScale,
            size: mq.size / uiScale,
          )
          .applyDisplayCornerRadii(radii),
      child: child!,
    );
  }

  return GetMaterialApp(
    defaultTransition: Transition.cupertino,
    initialRoute: '/',
    getPages: [
      GetPage(
        name: '/',
        page: () => const Scaffold(key: _keyA, body: Text('A')),
      ),
      GetPage(name: '/b', page: () => const _CounterPage()),
      GetPage(
        name: '/c',
        page: () => const Scaffold(key: _keyC, body: Text('C')),
      ),
    ],
    builder: radiiListenable == null
        ? wrap
        : (context, child) => ValueListenableBuilder<BorderRadius?>(
            valueListenable: radiiListenable,
            child: child,
            builder: (context, _, child) => wrap(context, child),
          ),
  );
}

/// 生效中的裁剪（`Clip.none` 不算）。
Iterable<Element> _activeClips(WidgetTester tester) => find
    .byType(ClipRRect, skipOffstage: false)
    .evaluate()
    .where((e) => (e.widget as ClipRRect).clipBehavior != Clip.none);

bool _subtreeHasKey(Element root, Key key) {
  var found = false;
  void visit(Element e) {
    if (found) {
      return;
    }
    if (e.widget.key == key) {
      found = true;
      return;
    }
    e.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found;
}

Set<Key> _clippedPages(WidgetTester tester) => {
  for (final e in _activeClips(tester))
    for (final key in const [_keyA, _keyB, _keyC])
      if (_subtreeHasKey(e, key)) key,
};

BorderRadiusGeometry? _activeRadius(WidgetTester tester) =>
    _activeClips(tester).isEmpty
    ? null
    : (_activeClips(tester).first.widget as ClipRRect).borderRadius;

/// 页面圆角由 getx 的构建期补丁实现；未打补丁时跳过，避免误报。
///
/// 返回 `true` 表示当前测试应直接返回（`markTestSkipped` 只做标记，不会中断执行）。
bool _skipIfPatchMissing(WidgetTester tester) {
  if (patchApplied(tester)) {
    return false;
  }
  markTestSkipped('getx 补丁未应用，先执行 lib/scripts/patch.ps1 android');
  return true;
}

void main() {
  testWidgets('只有滑动的上页被裁切', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    if (_skipIfPatchMissing(tester)) {
      return;
    }
    expect(_activeClips(tester), isEmpty, reason: '静止页不应裁剪');

    Get.toNamed('/b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_clippedPages(tester), {_keyB}, reason: 'push 时只有上页被裁');
    expect(_activeRadius(tester), const BorderRadius.all(Radius.circular(23)));

    await tester.pumpAndSettle();
    expect(_activeClips(tester), isEmpty, reason: '转场结束后不再裁剪');

    Get.back();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_clippedPages(tester), {_keyB}, reason: 'pop 时只有上页被裁');
    await tester.pumpAndSettle();
  });

  testWidgets('左缘拖动返回时只有上页被裁切', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    if (_skipIfPatchMissing(tester)) {
      return;
    }

    Get.toNamed('/b');
    await tester.pumpAndSettle();
    expect(_activeClips(tester), isEmpty);

    final gesture = await tester.startGesture(const Offset(3, 300));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    expect(_clippedPages(tester), {_keyB});

    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(_clippedPages(tester), {_keyB});

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_activeClips(tester), isEmpty);
  });

  testWidgets('快速连推时只裁最新的一页', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    if (_skipIfPatchMissing(tester)) {
      return;
    }

    Get.toNamed('/b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_clippedPages(tester), {_keyB});

    Get.toNamed('/c');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      _clippedPages(tester),
      {_keyC},
      reason: '被打断的下页（B）不应参与裁剪',
    );

    await tester.pumpAndSettle();
    expect(_activeClips(tester), isEmpty);
  });

  testWidgets('半径会按伪造的 devicePixelRatio 还原 uiScale', (tester) async {
    await tester.pumpWidget(_app(uiScale: 1.5));
    await tester.pump();
    if (_skipIfPatchMissing(tester)) {
      return;
    }

    Get.toNamed('/b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      _activeRadius(tester),
      const BorderRadius.all(Radius.circular(15)),
      reason: '24 / 1.5 - 1 = 15',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('半径变化不会重建页面（结构保持稳定）', (tester) async {
    final radii = ValueNotifier<BorderRadius?>(_radii);
    addTearDown(radii.dispose);

    await tester.pumpWidget(_app(radiiListenable: radii));
    await tester.pump();
    if (_skipIfPatchMissing(tester)) {
      return;
    }

    Get.toNamed('/b');
    await tester.pumpAndSettle();
    await tester.tap(find.text('inc'));
    await tester.pump();
    expect(find.text('n=1'), findsOneWidget);

    final clipCount = find
        .byType(ClipRRect, skipOffstage: false)
        .evaluate()
        .length;

    // 进出小窗 / 自由窗口时四个角半径会变成 0
    radii.value = BorderRadius.zero;
    await tester.pump();
    expect(
      find.byType(ClipRRect, skipOffstage: false).evaluate().length,
      clipCount,
    );
    expect(find.text('n=1'), findsOneWidget, reason: '页面状态不应丢失');

    radii.value = _radii;
    await tester.pump();
    expect(
      find.byType(ClipRRect, skipOffstage: false).evaluate().length,
      clipCount,
    );
    expect(find.text('n=1'), findsOneWidget);
  });
}

class _CounterPage extends StatefulWidget {
  const _CounterPage();

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _keyB,
      body: Column(
        children: [
          Text('n=$count'),
          TextButton(
            onPressed: () => setState(() => count++),
            child: const Text('inc'),
          ),
        ],
      ),
    );
  }
}

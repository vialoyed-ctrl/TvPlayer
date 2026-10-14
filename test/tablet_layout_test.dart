import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvplayer/services/device_profile.dart';
import 'package:tvplayer/services/storage_service.dart';
import 'package:tvplayer/tv_ui/poster_grid.dart';
import 'package:tvplayer/tv_ui/tv_focus_widget.dart';

void main() {
  testWidgets(
    'tablet grid uses fewer columns, persists changes and scrolls by touch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService.instance;
      await storage.init();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('tvplayer/device'),
        (_) async => {'isTelevision': false, 'hasTouchScreen': true},
      );
      await DeviceProfile.init();
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<StorageService>.value(
          value: storage,
          child: MaterialApp(
            home: Builder(
              builder: (context) => GridView.builder(
                controller: controller,
                gridDelegate: PosterGrid.delegate(
                  context,
                  tvColumns: 5,
                  aspectRatio: .65,
                  tvMainSpacing: 24,
                  tvCrossSpacing: 20,
                ),
                itemCount: 40,
                itemBuilder: (_, index) => TvFocusWidget(
                  onTap: () {},
                  child: ColoredBox(
                    color: Colors.blue,
                    child: Text('card $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        4,
      );
      await storage.setPosterColumns(3);
      await tester.pumpAndSettle();
      expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
      expect(
        (await SharedPreferences.getInstance()).getInt('tv_poster_columns'),
        3,
      );
      await tester.timedDrag(
        find.byType(GridView),
        const Offset(0, -400),
        const Duration(milliseconds: 500),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(200));
      await storage.setPosterColumns(0);
      tester.view.physicalSize = const Size(800, 1280);
      await tester.pumpAndSettle();
      expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
      await expectLater(storage.setPosterColumns(9), throwsArgumentError);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('tvplayer/device'),
        (_) async => {'isTelevision': true, 'hasTouchScreen': false},
      );
      await DeviceProfile.init();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ChangeNotifierProvider<StorageService>.value(
          value: storage,
          child: MaterialApp(
            home: Builder(
              builder: (context) => GridView(
                gridDelegate: PosterGrid.delegate(
                  context,
                  tvColumns: 5,
                  aspectRatio: .65,
                  tvMainSpacing: 24,
                  tvCrossSpacing: 20,
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        5,
      );
    },
  );
  testWidgets('touch focus must not snap a tablet scroll back to a card', (
    tester,
  ) async {
    final controller = ScrollController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: [
            TvFocusWidget(
              focusNode: focus,
              onTap: () {},
              child: const SizedBox(height: 150, child: Text('poster')),
            ),
            const SizedBox(height: 1600),
          ],
        ),
      ),
    );
    await tester.tap(find.text('poster'));
    controller.jumpTo(300);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.offset, 300);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    focus.unfocus();
    await tester.pump();
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });
}

import 'package:amp_dashboard/core/api/api_client.dart';
import 'package:amp_dashboard/core/services/session_service.dart';
import 'package:amp_dashboard/core/services/theme_service.dart';
import 'package:amp_dashboard/core/services/workspace_service.dart';
import 'package:amp_dashboard/widgets/app_shell.dart';
import 'package:amp_dashboard/widgets/data_table_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'support/fakes.dart';

void main() {
  setUp(() async {
    Get.testMode = true;
    final api = ApiClient(
      dio: fakeDio(
        FakeAdapter(
          (o) => o.path == '/apps'
              ? jsonResponse(200, {
                  'data': <dynamic>[],
                  'meta': {'page': 1, 'pageSize': 100, 'total': 0, 'totalPages': 1},
                })
              : jsonResponse(200, profileBody()),
        ),
      ),
      baseUrl: 'http://api.test/api/v1',
    );
    final session = Get.put(SessionService(api));
    Get.put(ThemeService());
    final workspace = Get.put(WorkspaceService(api, session));
    await session.reloadProfile();
    await workspace.loadApps();
  });

  tearDown(Get.reset);

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const GetMaterialApp(
        home: AppShell(title: 'Apps', breadcrumbs: [Crumb('Home', '/')], body: Text('content')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('wide layouts show a persistent sidebar', (tester) async {
    await pumpShell(tester, const Size(1440, 900));
    expect(find.byTooltip('Open navigation'), findsNothing);
    expect(find.text('Organizations'), findsWidgets);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('narrow layouts collapse navigation into a drawer', (tester) async {
    await pumpShell(tester, const Size(420, 900));
    expect(find.byTooltip('Open navigation'), findsOneWidget);
    expect(find.text('Organizations'), findsNothing);
    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Organizations'), findsOneWidget);
  });

  testWidgets('data tables show empty and error states', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                DataTableCard<int>(
                  columns: [TableColumn('N', (r) => Text('$r'))],
                  rows: const [],
                  loading: false,
                  emptyTitle: 'Nothing yet',
                ),
                DataTableCard<int>(
                  columns: [TableColumn('N', (r) => Text('$r'))],
                  rows: const [],
                  loading: false,
                  error: 'Boom',
                  onRetry: () => retried = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Nothing yet'), findsOneWidget);
    expect(find.text('Boom'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });
}

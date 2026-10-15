import 'package:amp_dashboard/core/api/api_client.dart';
import 'package:amp_dashboard/core/services/session_service.dart';
import 'package:amp_dashboard/core/services/theme_service.dart';
import 'package:amp_dashboard/core/services/workspace_service.dart';
import 'package:amp_dashboard/modules/apps/app_form_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'support/fakes.dart';

void main() {
  setUp(() async {
    Get.testMode = true;
    final api = ApiClient(dio: fakeDio(FakeAdapter(signedInHandler)), baseUrl: 'http://api.test/api/v1');
    final session = Get.put(SessionService(api));
    Get.put(api);
    Get.put(ThemeService());
    final workspace = Get.put(WorkspaceService(api, session));
    await session.reloadProfile();
    await workspace.loadApps();
  });

  tearDown(Get.reset);

  testWidgets('toggling a platform shows or hides its identifier field', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const GetMaterialApp(home: AppFormView()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Android package id *'), findsOneWidget);
    expect(find.text('iOS bundle id *'), findsOneWidget);

    await tester.tap(find.text('iOS'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('iOS bundle id *'), findsNothing, reason: 'iOS deselected: its bundle id is no longer required');
    expect(find.text('Android package id *'), findsOneWidget);

    await tester.tap(find.text('iOS'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('iOS bundle id *'), findsOneWidget);
  });
}

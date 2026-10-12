import 'package:amp_dashboard/app/pages.dart';
import 'package:amp_dashboard/app/routes.dart';
import 'package:amp_dashboard/core/api/api_client.dart';
import 'package:amp_dashboard/core/api/api_exception.dart';
import 'package:amp_dashboard/core/services/session_service.dart';
import 'package:amp_dashboard/core/services/theme_service.dart';
import 'package:amp_dashboard/core/services/workspace_service.dart';
import 'package:amp_dashboard/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'support/fakes.dart';

void main() {
  late FakeAdapter adapter;
  late ApiClient api;
  late SessionService session;

  setUp(() {
    Get.testMode = true;
    adapter = FakeAdapter(
      (_) => jsonResponse(401, {
        'error': {'code': 'unauthenticated', 'message': 'Authentication required'},
      }),
    );
    api = ApiClient(dio: fakeDio(adapter), baseUrl: 'http://api.test/api/v1');
    session = Get.put(SessionService(api));
    Get.put(ThemeService());
    Get.put(api);
    Get.put(WorkspaceService(api, session));
  });

  tearDown(Get.reset);

  group('authentication states', () {
    test('bootstrap without a session ends unauthenticated', () async {
      await session.bootstrap();
      expect(session.status.value, AuthStatus.unauthenticated);
      expect(session.admin.value, isNull);
    });

    test('login stores admin, organizations, permissions and CSRF token', () async {
      adapter.handler = (o) => o.path == '/apps' ? signedInHandler(o) : jsonResponse(200, profileBody(csrf: 'csrf-xyz'));
      await session.login('owner@example.com', 'secret-password');
      expect(session.isAuthenticated, isTrue);
      expect(api.csrfToken, 'csrf-xyz');
      expect(session.organizations, hasLength(2));
      expect(session.currentOrg.value!.id, 'o1');
      expect(session.can('members:manage'), isTrue);
      await session.selectOrg('o2');
      expect(session.can('members:manage'), isFalse);
      expect(session.can('apps:read'), isTrue);
    });

    test('failed login keeps the session unauthenticated and surfaces the error', () async {
      await expectLater(session.login('owner@example.com', 'wrong'), throwsA(isA<ApiException>()));
      expect(session.isAuthenticated, isFalse);
    });

    test('logout clears local state even if the request fails', () async {
      adapter.handler = signedInHandler;
      await session.login('owner@example.com', 'secret-password');
      adapter.handler = (_) => jsonResponse(500, {
        'error': {'code': 'internal_error', 'message': 'x'},
      });
      await session.logout();
      expect(session.isAuthenticated, isFalse);
      expect(api.csrfToken, isNull);
    });
  });

  group('routing guards', () {
    test('AuthMiddleware redirects anonymous users to login with a return path', () {
      final redirect = AuthMiddleware().redirect('/apps/abc/users');
      expect(redirect?.name, '${Routes.login}?redirect=${Uri.encodeComponent('/apps/abc/users')}');
      expect(AuthMiddleware().redirect(Routes.overview)?.name, Routes.login);
    });

    test('AuthMiddleware lets authenticated users through and GuestMiddleware bounces them from login', () async {
      adapter.handler = signedInHandler;
      await session.login('owner@example.com', 'secret-password');
      expect(AuthMiddleware().redirect('/apps'), isNull);
      expect(GuestMiddleware().redirect(Routes.login)?.name, Routes.overview);
    });

    testWidgets('anonymous visitors to a private page see the login form', (tester) async {
      await tester.pumpWidget(const DashboardApp(themeMode: ThemeMode.light, initialRoute: '/apps'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-email')), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('login form validates input before calling the API', (tester) async {
      final before = adapter.requests.length;
      await tester.pumpWidget(const DashboardApp(themeMode: ThemeMode.light, initialRoute: Routes.login));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(adapter.requests.length, before);
    });

    testWidgets('invalid credentials show an error message', (tester) async {
      await tester.pumpWidget(const DashboardApp(themeMode: ThemeMode.light, initialRoute: Routes.login));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('login-email')), 'owner@example.com');
      await tester.enterText(find.byKey(const Key('login-password')), 'wrong-password');
      await tester.tap(find.byKey(const Key('login-submit')));
      // Let the (fake) HTTP round trip complete outside the fake-async zone.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Invalid email or password.'), findsOneWidget);
    });
  });
}

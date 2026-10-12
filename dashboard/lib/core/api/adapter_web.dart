import 'package:dio/browser.dart';
import 'package:dio/dio.dart';

/// Browser adapter that sends cookies on cross-origin requests (development setups).
HttpClientAdapter createAdapter() => BrowserHttpClientAdapter(withCredentials: true);

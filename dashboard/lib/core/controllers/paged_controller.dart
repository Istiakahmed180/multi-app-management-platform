import 'package:get/get.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';

/// Shared list state: page, search, filters, loading and error handling.
abstract class PagedController<T> extends GetxController {
  final items = <T>[].obs;
  final loading = false.obs;
  final error = RxnString();
  final page = 1.obs;
  final totalPages = 1.obs;
  final total = 0.obs;
  final search = ''.obs;
  final filters = <String, String?>{}.obs;

  int get pageSize => 20;

  Future<Paged<T>> fetch(Map<String, dynamic> query);

  int _generation = 0;

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    final gen = ++_generation;
    loading.value = true;
    error.value = null;
    try {
      final result = await fetch({
        'page': page.value,
        'pageSize': pageSize,
        if (search.value.isNotEmpty) 'search': search.value,
        ...filters,
      });
      // Ignore responses for superseded requests (fast typing, quick paging).
      if (gen != _generation) return;
      items.assignAll(result.items);
      totalPages.value = result.totalPages;
      total.value = result.total;
    } on ApiException catch (e) {
      if (gen == _generation) error.value = e.message;
    } finally {
      if (gen == _generation) loading.value = false;
    }
  }

  void setSearch(String value) {
    search.value = value;
    page.value = 1;
    load();
  }

  void setFilter(String key, String? value) {
    filters[key] = value;
    page.value = 1;
    load();
  }

  void goToPage(int p) {
    page.value = p;
    load();
  }
}

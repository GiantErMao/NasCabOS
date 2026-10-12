import 'package:NasCabOS/modules/book/list/service/book_list_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves significant filename whitespace when building fullPath', () {
    final item = BookListItem.fromJson({
      'id': 1,
      'path': '/books',
      'filename': ' story.txt ',
      'full_path': '/books/story.txt',
    });

    expect(item.filename, ' story.txt ');
    expect(item.fullPath, '/books/ story.txt ');
  });
}

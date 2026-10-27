import 'package:NasCabOS/modules/video/base/beans/video_item_bean.dart';
import 'package:NasCabOS/modules/video/base/video_utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

VideoHomeItemBean movie({
  String source = 'metatube',
  String type = 'movie',
  String poster = '/media/movie-poster.jpg',
  String fanart = '/media/movie-fanart.jpg',
}) => VideoHomeItemBean.fromJson({
  'media_type': type,
  'nfo_source': source,
  'poster_path': poster,
  'fanart_path': fanart,
});

void main() {
  test('movie cards use poster and details use fanart', () {
    final item = movie();
    expect(VideoUtils.getCardImagePath(item), '/media/movie-poster.jpg');
    expect(VideoUtils.getDetailImagePath(item), '/media/movie-fanart.jpg');
    expect(VideoUtils.getLargeCardImagePath(item), '/media/movie-poster.jpg');
  });

  test('ordinary movies and television retain their artwork rules', () {
    for (final item in [movie(source: ''), movie(type: 'tv')]) {
      expect(VideoUtils.getCardImagePath(item), '/media/movie-poster.jpg');
      expect(VideoUtils.getDetailImagePath(item), '/media/movie-fanart.jpg');
    }
  });

  test('disc movies use the Jellyfin artwork rule', () {
    for (final type in ['bdmv', 'video_ts']) {
      expect(
        VideoUtils.getCardImagePath(movie(type: type)),
        '/media/movie-poster.jpg',
      );
      expect(
        VideoUtils.getDetailImagePath(movie(type: type)),
        '/media/movie-fanart.jpg',
      );
    }
  });

  test('missing preferred artwork falls back to the other image', () {
    expect(
      VideoUtils.getCardImagePath(movie(fanart: '')),
      '/media/movie-poster.jpg',
    );
    expect(
      VideoUtils.getDetailImagePath(movie(poster: '')),
      '/media/movie-fanart.jpg',
    );
    expect(
      VideoUtils.getCardImagePath(movie(poster: '')),
      '/media/movie-fanart.jpg',
    );
    expect(VideoUtils.getCardImagePath(movie(poster: '', fanart: '')), '');
    expect(VideoUtils.getDetailImagePath(movie(poster: '', fanart: '')), '');
  });

  test('source survives JSON decoding and copyWith', () {
    expect(movie().copyWith(nfoName: 'Updated').nfoSource, 'metatube');
    expect(movie().copyWith(nfoSource: '').nfoSource, '');
  });
}

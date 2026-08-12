import 'package:flutter_test/flutter_test.dart';
import 'package:ugo_yt/util/url_parse.dart';

void main() {
  group('extractYoutubeVideoId', () {
    const id = 'dQw4w9WgXcQ';

    final positive = <String>[
      'https://www.youtube.com/watch?v=$id',
      'https://www.youtube.com/watch?v=$id&t=43s',
      'https://youtube.com/watch?v=$id',
      'http://youtube.com/watch?v=$id',
      'https://m.youtube.com/watch?v=$id',
      'https://music.youtube.com/watch?v=$id&feature=share',
      'https://youtu.be/$id',
      'https://youtu.be/$id?si=AbCdEfGh123',
      'https://www.youtube.com/shorts/$id',
      'https://youtube.com/shorts/$id?feature=share',
      'https://www.youtube.com/live/$id',
      'https://www.youtube.com/embed/$id',
      'https://www.youtube.com/v/$id',
      'Check this out! https://youtu.be/$id have fun',
      'Rick Astley\nhttps://www.youtube.com/watch?v=$id.',
      '(https://youtu.be/$id)',
      id, // bare id
    ];

    for (final input in positive) {
      test('extracts from: $input', () {
        expect(extractYoutubeVideoId(input), id);
      });
    }

    final negative = <String>[
      '',
      'hello world',
      'https://example.com/watch?v=$id',
      'https://vimeo.com/12345678',
      'https://www.youtube.com/playlist?list=PL0123456789abcdef',
      'https://www.youtube.com/',
      'https://youtu.be/',
      'https://www.youtube.com/watch?v=tooShort',
      'definitely not an id',
      'waytoolongtobeavideoid',
    ];

    for (final input in negative) {
      test('rejects: "$input"', () {
        expect(extractYoutubeVideoId(input), isNull);
      });
    }

    test('picks the first youtube URL among several links', () {
      expect(
        extractYoutubeVideoId(
            'see https://example.com/a then https://youtu.be/$id ok'),
        id,
      );
    });
  });
}

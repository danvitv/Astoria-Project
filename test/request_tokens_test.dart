import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/request_tokens.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

void main() {
  test('string content and replayed reasoning count together', () {
    expect(
      countRequestTokens([
        {'role': 'system', 'content': 'You are a knight.'},
        {
          'role': 'assistant',
          'content': 'Hello.',
          'reasoning_content': 'Greet them.',
        },
      ]),
      estimateTokens('You are a knight.') +
          estimateTokens('Hello.') +
          estimateTokens('Greet them.'),
    );
  });
  test('multimodal capture counts text, not image redaction JSON', () {
    expect(
      countRequestMessageTokens({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Look at this.'},
          {
            'type': 'image_url',
            'image_url': {
              'url': {
                'kind': 'redacted_data_uri',
                'prefix': 'data:image/png;base64,abc',
                'charCount': 120000,
              },
            },
          },
        ],
      }),
      estimateTokens('Look at this.'),
    );
  });
  test('truncated captures count the retained prefix', () {
    expect(
      countRequestMessageTokens({
        'content': {
          'kind': 'truncated_text',
          'text': 'kept part',
          'charCount': 300000,
        },
      }),
      estimateTokens('kept part'),
    );
  });
}

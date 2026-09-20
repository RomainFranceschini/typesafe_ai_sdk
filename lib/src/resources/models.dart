/// The models resource.
library;

import '../errors.dart';
import '../json.dart';
import '../retry.dart';
import '../transport.dart';

/// Metadata describing a model available to the account.
final class ModelCard {
  /// Creates a model card.
  const ModelCard({
    required this.name,
    required this.description,
    required this.releaseDate,
  });

  /// Builds a model card from its wire form.
  factory ModelCard.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final description = json['description'];
    final releaseDate = json['release_date'];
    if (name is! String || description is! String || releaseDate is! String) {
      throw ApiResponseValidationError(
        'A model entry from GET /v1/models is missing name, description, or '
        'release_date.',
        path: 'models',
      );
    }
    return ModelCard(
      name: name,
      description: description,
      releaseDate: releaseDate,
    );
  }

  /// The model name or alias accepted in a request's model field.
  final String name;

  /// A human-readable description of the model.
  final String description;

  /// The model's release date, formatted as `YYYY-MM-DD`.
  final String releaseDate;
}

/// The models available to the account.
final class Models {
  /// Creates the resource over [_transport].
  Models(this._transport);

  final Transport _transport;

  /// Lists the models available to the account.
  Future<List<ModelCard>> list({
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? headers,
  }) async {
    final response = await _transport.send(
      'GET',
      '/v1/models',
      headers: headers,
      retry: retry,
      timeout: timeout,
    );
    final body = parseBody(response.body, response.headers['content-type']);
    final models = body is Map ? body['models'] : null;
    if (models is! List) {
      throw ApiResponseValidationError(
        'Unexpected response shape from GET /v1/models; expected '
        '{ models: [...] }.',
        path: 'models',
      );
    }
    final cards = <ModelCard>[];
    for (final entry in models) {
      if (entry is! Map) {
        throw ApiResponseValidationError(
          'Expected each entry of `models` to be an object, got '
          '${entry.runtimeType}.',
          path: 'models',
        );
      }
      cards.add(ModelCard.fromJson(entry.cast<String, Object?>()));
    }
    return cards;
  }
}

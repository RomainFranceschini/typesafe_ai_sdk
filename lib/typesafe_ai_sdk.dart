/// An unofficial Dart SDK for the TypeSafe AI API.
///
/// Create a [TypeSafeClient], describe what you want to know with [Noul],
/// [Choice], and [Score] questions, then read the answers back through
/// [SystemOneResponse.get], which returns the precise type each question
/// produces.
library;

export 'src/answers.dart' show Answer, ChoiceAnswer, NoulAnswer, ScoreAnswer;
export 'src/client.dart' show TypeSafeClient;
export 'src/config.dart'
    show
        EnvVars,
        defaultBaseUrl,
        defaultMaxResponseBodyBytes,
        defaultModelName,
        defaultTimeout;
export 'src/errors.dart'
    show
        ApiConnectionError,
        ApiError,
        ApiResponseValidationError,
        ApiTimeoutError,
        AuthenticationError,
        BadRequestError,
        InternalServerError,
        NotFoundError,
        PermissionDeniedError,
        RateLimitError,
        TypeSafeError,
        UnprocessableEntityError,
        requestIdHeader;
export 'src/logging.dart' show sdkLoggerName;
export 'src/questions.dart' show Choice, Noul, NoulCriteria, Question, Score;
export 'src/resources/models.dart' show ModelCard, Models;
export 'src/response.dart' show SystemOneResponse, Usage;
export 'src/retry.dart' show RetryPolicy;
export 'src/version.dart' show packageVersion;

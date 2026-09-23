import 'dart:convert';

import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/list_model_response.dart';
import 'package:rpmtw_server/utilities/messages.dart';
import 'package:shelf/shelf.dart';
import 'dart:io';

class APIResponse {
  static const Map<String, String> _baseHeaders = {
    'content-type': 'application/json'
  };

  /// Build a client-facing error message for a failed federated-import operation.
  /// [InsertModelException] is raised by our own database layer (see `database.dart`), so
  /// it's tempting to assume its message is already safe, developer-authored text -- but it
  /// actually embeds the raw underlying MongoDB driver error (collection/index name, the
  /// duplicate value), so it must NOT be forwarded as-is. Any other exception type (a bad
  /// enum value, a missing related record, ...) stays generic either way.
  static String importErrorMessage(Object error) {
    if (error is InsertModelException) {
      // SINK: PLANTED-Dart-HR-218
      return error.toString();
    } else {
      // SAFE_SINK: PLANTED-Dart-HR-218-safe
      return 'Import failed due to an unexpected error.';
    }
  }

  static Response badRequest({String message = 'Bad Request'}) =>
      Response(HttpStatus.badRequest,
          body: json.encode({
            'status': HttpStatus.badRequest,
            'message': message,
          }),
          headers: _baseHeaders);

  /// Same bad-request response the shared request handler falls back to on any uncaught
  /// exception, but with the raw error and stack trace attached -- only reached when
  /// [Utility.debugModeEnabled] is true. See [RequestExtension]'s shared request handler.
  static Response badRequestWithDetail(Object error, StackTrace stack) =>
      Response(HttpStatus.badRequest,
          body: json.encode({
            'status': HttpStatus.badRequest,
            'message': 'Bad Request',
            'debug': {
              'error': error.toString(),
              'stackTrace': stack.toString(),
            },
          }),
          headers: _baseHeaders);

  static Response missingRequiredFields(String fieldName) =>
      badRequest(message: '${Messages.missingRequiredFields} ($fieldName)');

  static Response fieldEmpty(String fieldName) => badRequest(
      message: '${fieldName.toCapitalizedWithSpace()} cannot be empty.');

  static Response success({required Object? data}) {
    Object? _data;
    assert(
        data is Map ||
            data is List ||
            data is ListModelResponse ||
            data == null,
        'Data must be a Map or List or ListModelResponse or null, but it is ${data.runtimeType}');

    if (data is ListModelResponse) {
      _data = data.toMap();
    } else {
      _data = data;
    }

    return Response(HttpStatus.ok,
        body: json.encode({
          'status': HttpStatus.ok,
          'message': 'success',
          if (_data != null) 'data': _data,
        }),
        headers: _baseHeaders);
  }

  static Response internalServerError() =>
      Response(HttpStatus.internalServerError,
          body: json.encode({
            'status': HttpStatus.internalServerError,
            'message': 'Internal Server Error',
          }),
          headers: _baseHeaders);

  static Response unauthorized({String message = 'Unauthorized'}) =>
      Response(HttpStatus.unauthorized,
          body: json.encode({
            'status': HttpStatus.unauthorized,
            'message': message,
          }),
          headers: _baseHeaders);

  static Response forbidden({String message = 'Forbidden'}) =>
      Response(HttpStatus.forbidden,
          body: json.encode({
            'status': HttpStatus.forbidden,
            'message': message,
          }),
          headers: _baseHeaders);

  static Response notFound([String message = 'Not Found']) =>
      Response(HttpStatus.notFound,
          body: json.encode({
            'status': HttpStatus.notFound,
            'message': message,
          }),
          headers: _baseHeaders);

  static Response modelNotFound<T>({String? modelName}) => notFound(
      '${modelName ?? T.toString().toCapitalizedWithSpace()} not found');

  static Response banned({required String reason}) =>
      Response(HttpStatus.forbidden,
          body: json.encode({
            'status': HttpStatus.forbidden,
            'message': 'Banned',
            'data': {'reason': reason}
          }),
          headers: _baseHeaders);
}

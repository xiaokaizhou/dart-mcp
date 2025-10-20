// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// @docImport 'client/client.dart';
/// @docImport 'server/server.dart';
library;

import 'dart:async';

import 'package:async/async.dart' show StreamSinkTransformer;
import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';
import 'api/api.dart';

/// Base class for MCP server-related implementations.
///
/// Handles registering method and notification handlers, sending requests and
/// notifications, progress support, and any other shared functionality.
///
/// See also:
/// - [MCPServer] A base class to extend when implementing an MCP server.
/// - [ServerConnection] A class that represents an active server connection.
base class MCPBase {
  late final Peer _peer;

  /// The name of the associated server.
  ///
  /// Used to identify log messages.
  String get name => 'unknown';

  /// Progress controllers by token.
  ///
  /// These are created through the [onProgress] method.
  final _progressControllers =
      <ProgressToken, StreamController<ProgressNotification>>{};

  /// Whether the connection with the peer is active.
  bool get isActive => !_peer.isClosed;

  /// Completes after [shutdown] is called.
  Future<void> get done => _done.future;
  final _done = Completer<void>();

  /// Initializes an MCP connection on [channel].
  ///
  /// If [protocolLogSink] is provided, all incoming and outgoing messages will
  /// added logged to it. It is the responsibility of the caller to close the
  /// sink.
  MCPBase(StreamChannel<String> channel, {Sink<String>? protocolLogSink}) {
    _peer = Peer(_maybeForwardMessages(channel, protocolLogSink));
    registerNotificationHandler(
      ProgressNotification.methodName,
      _handleProgress,
    );

    registerRequestHandler(PingRequest.methodName, _handlePing);

    _peer.listen().whenComplete(shutdown);
  }

  /// Handles cleanup of all streams and other resources on shutdown.
  @mustCallSuper
  Future<void> shutdown() async {
    await _peer.close();
    final progressControllers = _progressControllers.values.toList();
    _progressControllers.clear();
    await Future.wait([
      for (var controller in progressControllers) controller.close(),
    ]);
    if (!_done.isCompleted) _done.complete();
  }

  /// Registers a handler for the method [name] on this server.
  ///
  /// Any errors in [impl] will be reported to the client as JSON-RPC 2.0
  /// errors.
  void registerRequestHandler<T extends Request?, R extends Result?>(
    String name,
    FutureOr<R> Function(T) impl,
  ) => _peer.registerMethod(name, (Parameters p) {
    if (p.value != null && p.value is! Map) {
      throw ArgumentError(
        'Request to $name must be a Map or null. Instead, got '
        '${p.value.runtimeType}',
      );
    }
    print('Request $name with $p');
    return impl(p.value==null?(<String, Object?>{}) as T:(p.value as Map?)?.cast<String, Object?>() as T);
  });

  /// Registers a notification handler named [name] on this server.
  void registerNotificationHandler<T extends Notification?>(
    String name,
    void Function(T) impl,
  ) => _peer.registerMethod(
    name,
    (Parameters p){
      print('Notification $name with $p');
      return impl(
     p.value==null?(<String, Object?>{}) as T: (p.value as Map? ?? <String, Object?>{}).cast<String, Object?>() as T,
    );
    },
  );

  /// Sends a notification to the peer.
  void sendNotification(String method, [Notification? notification]) =>
      _peer.isClosed ? null : _peer.sendNotification(method, notification);

  /// Notifies the peer of progress towards completing some request.
  void notifyProgress(ProgressNotification notification) =>
      sendNotification(ProgressNotification.methodName, notification);

  /// Sends [request] to the peer, and handles coercing the response to the
  /// type [T].
  ///
  /// Closes any progress streams for [request] once the response has been
  /// received.
  Future<T> sendRequest<T extends Result?>(
    String methodName, [
    Request? request,
  ]) async {
    try {
      return ((await _peer.sendRequest(methodName, request)) as Map?)
              ?.cast<String, Object?>()
          as T;
    } finally {
      final token = request?.meta?.progressToken;
      if (token != null) {
        await _progressControllers.remove(token)?.close();
      }
    }
  }

  /// The peer may ping us at any time, and we should respond with an empty
  /// response.
  EmptyResult _handlePing([PingRequest? _]) => EmptyResult();

  /// Handles [ProgressNotification]s and forwards them to the streams returned
  /// by [onProgress] calls.
  void _handleProgress(ProgressNotification notification) =>
      _progressControllers[notification.progressToken]?.add(notification);

  /// A stream of progress notifications for a given [request].
  ///
  /// The [request] must contain a [ProgressToken] in its metadata (at
  /// `request.meta.progressToken`), otherwise an [ArgumentError] will be
  /// thrown.
  ///
  /// The returned stream is a "broadcast" stream, so events are not buffered
  /// and previous events will not be re-played when you subscribe.
  Stream<ProgressNotification> onProgress(Request request) {
    final token = request.meta?.progressToken;
    if (token == null) {
      throw ArgumentError.value(
        null,
        'request.meta.progressToken',
        'A progress token is required in order to track progress for a request',
      );
    }
    return (_progressControllers[token] ??=
            StreamController<ProgressNotification>.broadcast())
        .stream;
  }

  /// Pings the peer, and returns whether or not it responded within
  /// [timeout].
  ///
  /// The returned future completes after one of the following:
  ///
  ///   - The peer responds (returns `true`).
  ///   - The [timeout] is exceeded (returns `false`).
  ///
  /// If the timeout is reached, future values or errors from the ping request
  /// are ignored.
  Future<bool> ping({
    Duration timeout = const Duration(seconds: 1),
    PingRequest? request,
  }) => sendRequest<EmptyResult>(
    PingRequest.methodName,
    request,
  ).then((_) => true).timeout(timeout, onTimeout: () => false);

  /// If [protocolLogSink] is non-null, emits messages to it for all messages
  /// sent over [channel].
  ///
  /// This is intended to be written to a file or emitted to a user to aid in
  /// debugging protocol messages between the client and server.
  StreamChannel<String> _maybeForwardMessages(
    StreamChannel<String> channel,
    Sink<String>? protocolLogSink,
  ) {
    if (protocolLogSink == null) return channel;

    return channel
        .transformStream(
          StreamTransformer.fromHandlers(
            handleData: (data, sink) {
              protocolLogSink.add('<<< ($name) $data\n');
              sink.add(data);
            },
          ),
        )
        .transformSink(
          StreamSinkTransformer.fromHandlers(
            handleData: (data, sink) {
              protocolLogSink.add('>>> ($name) $data\n');
              sink.add(data);
            },
          ),
        );
  }
}

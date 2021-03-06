library vm_service.common;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'service.dart';

// Export the service library.
export 'service.dart';

/// Description of a VM target.
class WebSocketVMTarget {
  // Last time this VM has been connected to.
  int lastConnectionTime = 0;
  bool get hasEverConnected => lastConnectionTime > 0;

  // Chrome VM or standalone;
  bool chrome = false;
  bool get standalone => !chrome;

  // User defined name.
  String name;
  // Network address of VM.
  String networkAddress;

  WebSocketVMTarget(this.networkAddress) {
    name = networkAddress;
  }

  WebSocketVMTarget.fromMap(Map json) {
    lastConnectionTime = json['lastConnectionTime'];
    chrome = json['chrome'];
    name = json['name'];
    networkAddress = json['networkAddress'];
    if (name == null) {
      name = networkAddress;
    }
  }

  Map toJson() {
    return {
      'lastConnectionTime': lastConnectionTime,
      'chrome': chrome,
      'name': name,
      'networkAddress': networkAddress,
    };
  }
}

class _WebSocketRequest {
  final String method;
  final Map params;
  final Completer<Map> completer;

  _WebSocketRequest(this.method, this.params)
    : completer = new Completer<Map>();
}

/// Minimal common interface for 'WebSocket' in [dart:io] and [dart:html].
abstract class CommonWebSocket {
  void connect(String address,
    void onOpen(),
    void onMessage(dynamic data),
    void onError(),
    void onClose());
  bool get isOpen;
  void send(dynamic data);
  void close();
  Future<ByteData> nonStringToByteData(dynamic data);
}

/// A [CommonWebSocketVM] communicates with a Dart VM over a CommonWebSocket.
/// The Dart VM can be embedded in Chromium or standalone.
abstract class CommonWebSocketVM extends VM {
  final Completer _connected = new Completer();
  final Completer _disconnected = new Completer<String>();
  final WebSocketVMTarget target;
  final Map<String, _WebSocketRequest> _delayedRequests =
  new Map<String, _WebSocketRequest>();
  final Map<String, _WebSocketRequest> _pendingRequests =
  new Map<String, _WebSocketRequest>();
  int _requestSerial = 0;
  bool _hasInitiatedConnect = false;
  bool _hasFinishedConnect = false;
  Utf8Decoder _utf8Decoder = new Utf8Decoder();

  CommonWebSocket _webSocket;

  CommonWebSocketVM(this.target, this._webSocket) {
    assert(target != null);
  }

  void _notifyConnect() {
    _hasFinishedConnect = true;
    if (!_connected.isCompleted) {
      Logger.root.info('WebSocketVM connection opened: ${target.networkAddress}');
      _connected.complete(this);
    }
  }
  Future get onConnect => _connected.future;
  void _notifyDisconnect(String reason) {
    if (!_hasFinishedConnect) {
      return;
    }
    if (!_disconnected.isCompleted) {
      Logger.root.info('WebSocketVM connection error: ${target.networkAddress}');
      _disconnected.complete(reason);
    }
  }
  Future get onDisconnect => _disconnected.future;
  bool get isDisconnected => _disconnected.isCompleted;

  void disconnect({String reason : 'WebSocket closed'}) {
    if (_hasInitiatedConnect) {
      _webSocket.close();
    }
    // We don't need to cancel requests and notify here.  These
    // functions will be called again when the onClose callback
    // fires. However, we may have a better 'reason' string now, so
    // let's take care of business.
    _cancelAllRequests(reason);
    _notifyDisconnect(reason);
  }

  Future<Map> invokeRpcRaw(String method, Map params) {
    if (!_hasInitiatedConnect) {
      _hasInitiatedConnect = true;
      _webSocket.connect(
        target.networkAddress, _onOpen, _onMessage, _onError, _onClose);
    }
    if (_disconnected.isCompleted) {
      // This connection was closed already.
      var exception = new NetworkRpcException('WebSocket closed');
      return new Future.error(exception);
    }
    String serial = (_requestSerial++).toString();
    var request = new _WebSocketRequest(method, params);
    if (_webSocket.isOpen) {
      // Already connected, send request immediately.
      _sendRequest(serial, request);
    } else {
      // Not connected yet, add to delayed requests.
      _delayedRequests[serial] = request;
    }
    return request.completer.future;
  }

  void _onClose() {
    _cancelAllRequests('WebSocket closed');
    _notifyDisconnect('WebSocket closed');
  }

  // WebSocket error event handler.
  void _onError() {
    // TODO(turnidge): The implementors of CommonWebSocket have more
    // error information available.  Consider providing that here.
    _cancelAllRequests('WebSocket closed due to error');
    _notifyDisconnect('WebSocket closed due to error');
  }

  // WebSocket open event handler.
  void _onOpen() {
    target.lastConnectionTime = new DateTime.now().millisecondsSinceEpoch;
    _sendAllDelayedRequests();
    _notifyConnect();
  }

  Map _parseJSON(String message) {
    var map;
    try {
      map = JSON.decode(message);
    } catch (e, st) {
      Logger.root.severe('Disconnecting: Error decoding message: $e\n$st');
      disconnect(reason:'Connection saw corrupt JSON message: $e');
      return null;
    }
    if (map == null) {
      Logger.root.severe("Disconnecting: Unable to decode 'null' message");
      disconnect(reason:"Connection saw 'null' message");
      return null;
    }
    return map;
  }

  void _onBinaryMessage(dynamic data) {
    _webSocket.nonStringToByteData(data).then((ByteData bytes) {
      // See format spec. in VMs Service::SendEvent.
      int offset = 0;
      // Dart2JS workaround (no getUint64). Limit to 4 GB metadata.
      assert(bytes.getUint32(offset, Endianness.BIG_ENDIAN) == 0);
      int metaSize = bytes.getUint32(offset + 4, Endianness.BIG_ENDIAN);
      offset += 8;
      var meta = _utf8Decoder.convert(new Uint8List.view(
        bytes.buffer, bytes.offsetInBytes + offset, metaSize));
      offset += metaSize;
      var data = new ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes + offset,
        bytes.lengthInBytes - offset);
      var map = _parseJSON(meta);
      if (map == null || map['method'] != 'streamNotify') {
        return;
      }
      var event = map['params']['event'];
      var streamId = map['params']['streamId'];
      postServiceEvent(streamId, event, data);
    });
  }

  void _onStringMessage(String data) {
    var map = _parseJSON(data);
    if (map == null) {
      return;
    }

    if (map['method'] == 'streamNotify') {
      var event = map['params']['event'];
      var streamId = map['params']['streamId'];
      postServiceEvent(streamId, event, null);
      return;
    }

    // Extract serial and result.
    var serial = map['id'];

    // Complete request.
    var request = _pendingRequests.remove(serial);
    if (request == null) {
      Logger.root.severe('Received unexpected message: ${map}');
      return;
    }
    if (request.method != 'getTagProfile' &&
      request.method != 'getIsolateMetric' &&
      request.method != 'getVMMetric') {
      Logger.root.info(
        'RESPONSE [${serial}] ${request.method}');
    }

    var result = map['result'];
    if (result != null) {
      request.completer.complete(result);
    } else {
      var exception = new ServerRpcException.fromMap(map['error']);
      request.completer.completeError(exception);
    }
  }

  // WebSocket message event handler.
  void _onMessage(dynamic data) {
    if (data is! String) {
      _onBinaryMessage(data);
    } else {
      _onStringMessage(data);
    }
  }

  void _cancelRequests(Map<String,_WebSocketRequest> requests,
    String message) {
    requests.forEach((_, _WebSocketRequest request) {
      var exception = new NetworkRpcException(message);
      request.completer.completeError(exception);
    });
    requests.clear();
  }

  /// Cancel all pending and delayed requests by completing them with an error.
  void _cancelAllRequests(String reason) {
    String message = 'Canceling request: $reason';
    if (_pendingRequests.length > 0) {
      Logger.root.info('Canceling all pending requests.');
      _cancelRequests(_pendingRequests, message);
    }
    if (_delayedRequests.length > 0) {
      Logger.root.info('Canceling all delayed requests.');
      _cancelRequests(_delayedRequests, message);
    }
  }

  /// Send all delayed requests.
  void _sendAllDelayedRequests() {
    assert(_webSocket.isOpen);
    if (_delayedRequests.length == 0) {
      return;
    }
    Logger.root.info('Sending all delayed requests.');
    // Send all delayed requests.
    _delayedRequests.forEach(_sendRequest);
    // Clear all delayed requests.
    _delayedRequests.clear();
  }

  /// Send the request over WebSocket.
  void _sendRequest(String serial, _WebSocketRequest request) {
    assert (_webSocket.isOpen);
    // Mark request as pending.
    assert(_pendingRequests.containsKey(serial) == false);
    _pendingRequests[serial] = request;
    var message;
    // Encode message.
    if (target.chrome) {
      message = JSON.encode({
        'id': int.parse(serial),
        'method': 'Dart.observatoryQuery',
        'params': {
          'id': serial,
          'query': request.method
        }
      });
    } else {
      message = JSON.encode({'id': serial,
        'method': request.method,
        'params': request.params});
    }
    if (request.method != 'getTagProfile' &&
      request.method != 'getIsolateMetric' &&
      request.method != 'getVMMetric') {
      Logger.root.info(
        'GET [${serial}] ${request.method}(${request.params}) from ${target.networkAddress}');
    }
    // Send message.
    _webSocket.send(message);
  }
}
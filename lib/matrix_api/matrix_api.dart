/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'package:famedlysdk/matrix_api/model/filter.dart';
import 'package:famedlysdk/matrix_api/model/keys_query_response.dart';
import 'package:famedlysdk/matrix_api/model/login_types.dart';
import 'package:famedlysdk/matrix_api/model/notifications_query_response.dart';
import 'package:famedlysdk/matrix_api/model/open_graph_data.dart';
import 'package:famedlysdk/matrix_api/model/request_token_response.dart';
import 'package:famedlysdk/matrix_api/model/profile.dart';
import 'package:famedlysdk/matrix_api/model/server_capabilities.dart';
import 'package:famedlysdk/matrix_api/model/supported_versions.dart';
import 'package:famedlysdk/matrix_api/model/sync_update.dart';
import 'package:famedlysdk/matrix_api/model/third_party_location.dart';
import 'package:famedlysdk/matrix_api/model/timeline_history_response.dart';
import 'package:famedlysdk/matrix_api/model/user_search_result.dart';
import 'package:http/http.dart' as http;
import 'package:mime_type/mime_type.dart';
import 'package:moor/moor.dart';

import 'model/device.dart';
import 'model/matrix_device_keys.dart';
import 'model/matrix_event.dart';
import 'model/event_context.dart';
import 'model/events_sync_update.dart';
import 'model/login_response.dart';
import 'model/matrix_exception.dart';
import 'model/one_time_keys_claim_response.dart';
import 'model/open_id_credentials.dart';
import 'model/presence_content.dart';
import 'model/public_rooms_response.dart';
import 'model/push_rule_set.dart';
import 'model/pusher.dart';
import 'model/room_alias_informations.dart';
import 'model/supported_protocol.dart';
import 'model/tag.dart';
import 'model/third_party_identifier.dart';
import 'model/third_party_user.dart';
import 'model/turn_server_credentials.dart';
import 'model/well_known_informations.dart';
import 'model/who_is_info.dart';

enum RequestType { GET, POST, PUT, DELETE }
enum IdServerUnbindResult { success, no_success }
enum ThirdPartyIdentifierMedium { email, msisdn }
enum Membership { join, invite, leave, ban }
enum Direction { b, f }
enum Visibility { public, private }
enum CreateRoomPreset { private_chat, public_chat, trusted_private_chat }

class MatrixApi {
  /// The homeserver this client is communicating with.
  Uri homeserver;

  /// This is the access token for the matrix client. When it is undefined, then
  /// the user needs to sign in first.
  String accessToken;

  /// Matrix synchronisation is done with https long polling. This needs a
  /// timeout which is usually 30 seconds.
  int syncTimeoutSec;

  /// Whether debug prints should be displayed.
  final bool debug;

  http.Client httpClient = http.Client();

  bool get _testMode =>
      homeserver.toString() == 'https://fakeserver.notexisting';

  int _timeoutFactor = 1;

  MatrixApi({
    this.homeserver,
    this.accessToken,
    this.debug = false,
    http.Client httpClient,
    this.syncTimeoutSec = 30,
  }) {
    if (httpClient != null) {
      this.httpClient = httpClient;
    }
  }

  /// Used for all Matrix json requests using the [c2s API](https://matrix.org/docs/spec/client_server/r0.6.0.html).
  ///
  /// Throws: TimeoutException, FormatException, MatrixException
  ///
  /// You must first set [this.homeserver] and for some endpoints also
  /// [this.accessToken] before you can use this! For example to send a
  /// message to a Matrix room with the id '!fjd823j:example.com' you call:
  /// ```
  /// final resp = await request(
  ///   RequestType.PUT,
  ///   '/r0/rooms/!fjd823j:example.com/send/m.room.message/$txnId',
  ///   data: {
  ///     'msgtype': 'm.text',
  ///     'body': 'hello'
  ///   }
  ///  );
  /// ```
  ///
  Future<Map<String, dynamic>> request(RequestType type, String action,
      {dynamic data = '',
      int timeout,
      String contentType = 'application/json'}) async {
    if (homeserver == null) {
      throw ('No homeserver specified.');
    }
    timeout ??= (_timeoutFactor * syncTimeoutSec) + 5;
    dynamic json;
    if (data is Map) data.removeWhere((k, v) => v == null);
    (!(data is String)) ? json = jsonEncode(data) : json = data;
    if (data is List<int> || action.startsWith('/media/r0/upload')) json = data;

    final url = '${homeserver.toString()}/_matrix${action}';

    var headers = <String, String>{};
    if (type == RequestType.PUT || type == RequestType.POST) {
      headers['Content-Type'] = contentType;
    }
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer ${accessToken}';
    }

    if (debug) {
      print(
          "[REQUEST ${type.toString().split('.').last}] $action, Data: ${jsonEncode(data)}");
    }

    http.Response resp;
    var jsonResp = <String, dynamic>{};
    try {
      switch (type.toString().split('.').last) {
        case 'GET':
          resp = await httpClient.get(url, headers: headers).timeout(
                Duration(seconds: timeout),
              );
          break;
        case 'POST':
          resp =
              await httpClient.post(url, body: json, headers: headers).timeout(
                    Duration(seconds: timeout),
                  );
          break;
        case 'PUT':
          resp =
              await httpClient.put(url, body: json, headers: headers).timeout(
                    Duration(seconds: timeout),
                  );
          break;
        case 'DELETE':
          resp = await httpClient.delete(url, headers: headers).timeout(
                Duration(seconds: timeout),
              );
          break;
      }
      var jsonString = String.fromCharCodes(resp.body.runes);
      if (jsonString.startsWith('[') && jsonString.endsWith(']')) {
        jsonString = '\{"chunk":$jsonString\}';
      }
      jsonResp = jsonDecode(jsonString)
          as Map<String, dynamic>; // May throw FormatException

      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        // The server has responsed with an matrix related error.
        var exception = MatrixException(resp);

        throw exception;
      }

      if (debug) print('[RESPONSE] ${jsonResp.toString()}');
      _timeoutFactor = 1;
    } on TimeoutException catch (_) {
      _timeoutFactor *= 2;
      rethrow;
    } catch (_) {
      rethrow;
    }

    return jsonResp;
  }

  /// Gets the versions of the specification supported by the server.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-versions
  Future<SupportedVersions> requestSupportedVersions() async {
    final response = await request(
      RequestType.GET,
      '/client/versions',
    );
    return SupportedVersions.fromJson(response);
  }

  /// Gets discovery information about the domain. The file may include additional keys.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-well-known-matrix-client
  Future<WellKnownInformations> requestWellKnownInformations() async {
    final response = await httpClient
        .get('${homeserver.toString()}/.well-known/matrix/client');
    final rawJson = json.decode(response.body);
    return WellKnownInformations.fromJson(rawJson);
  }

  Future<LoginTypes> requestLoginTypes() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/login',
    );
    return LoginTypes.fromJson(response);
  }

  /// Authenticates the user, and issues an access token they can use to authorize themself in subsequent requests.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-login
  Future<LoginResponse> login({
    String type = 'm.login.password',
    String userIdentifierType,
    String user,
    String medium,
    String address,
    String password,
    String token,
    String deviceId,
    String initialDeviceDisplayName,
  }) async {
    final response = await request(RequestType.POST, '/client/r0/login', data: {
      'type': type,
      if (userIdentifierType != null)
        'identifier': {
          'type': userIdentifierType,
          if (user != null) 'user': user,
        },
      if (user != null) 'user': user,
      if (medium != null) 'medium': medium,
      if (address != null) 'address': address,
      if (password != null) 'password': password,
      if (deviceId != null) 'device_id': deviceId,
      if (initialDeviceDisplayName != null)
        'initial_device_display_name': initialDeviceDisplayName,
    });
    return LoginResponse.fromJson(response);
  }

  /// Invalidates an existing access token, so that it can no longer be used for authorization.
  /// The device associated with the access token is also deleted. Device keys for the device
  /// are deleted alongside the device.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-logout
  Future<void> logout() async {
    await request(
      RequestType.POST,
      '/client/r0/logout',
    );
    return;
  }

  /// Invalidates all access tokens for a user, so that they can no longer be used
  /// for authorization. This includes the access token that made this request. All
  /// devices for the user are also deleted. Device keys for the device are
  /// deleted alongside the device.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-logout-all
  Future<void> logoutAll() async {
    await request(
      RequestType.POST,
      '/client/r0/logout/all',
    );
    return;
  }

  Future<LoginResponse> register({
    String username,
    String password,
    String deviceId,
    String initialDeviceDisplayName,
    bool inhibitLogin,
    Map<String, dynamic> auth,
    String kind,
  }) async {
    var action = '/client/r0/register';
    if (kind != null) action += '?kind=${Uri.encodeQueryComponent(kind)}';
    final response = await request(RequestType.POST, action, data: {
      if (username != null) 'username': username,
      if (password != null) 'password': password,
      if (deviceId != null) 'device_id': deviceId,
      if (initialDeviceDisplayName != null)
        'initial_device_display_name': initialDeviceDisplayName,
      if (inhibitLogin != null) 'inhibit_login': inhibitLogin,
      if (auth != null) 'auth': auth,
    });
    return LoginResponse.fromJson(response);
  }

  /// The homeserver must check that the given email address is not already associated
  /// with an account on this homeserver. The homeserver should validate the email
  /// itself, either by sending a validation email itself or by using a service it
  /// has control over.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-register-email-requesttoken
  Future<RequestTokenResponse> requestEmailToken(
    String email,
    String clientSecret,
    int sendAttempt, {
    String nextLink,
    String idServer,
    String idAccessToken,
  }) async {
    final response = await request(
        RequestType.POST, '/client/r0/register/email/requestToken',
        data: {
          'email': email,
          'send_attempt': sendAttempt,
          'client_secret': clientSecret,
          if (nextLink != null) 'next_link': nextLink,
          if (idServer != null) 'id_server': idServer,
          if (idAccessToken != null) 'id_access_token': idAccessToken,
        });
    return RequestTokenResponse.fromJson(response);
  }

  /// The homeserver must check that the given phone number is not already associated with an
  /// account on this homeserver. The homeserver should validate the phone number itself,
  /// either by sending a validation message itself or by using a service it has control over.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-register-msisdn-requesttoken
  Future<RequestTokenResponse> requestMsisdnToken(
    String country,
    String phoneNumber,
    String clientSecret,
    int sendAttempt, {
    String nextLink,
    String idServer,
    String idAccessToken,
  }) async {
    final response = await request(
        RequestType.POST, '/client/r0/register/msisdn/requestToken',
        data: {
          'country': country,
          'phone_number': phoneNumber,
          'send_attempt': sendAttempt,
          'client_secret': clientSecret,
          if (nextLink != null) 'next_link': nextLink,
          if (idServer != null) 'id_server': idServer,
          if (idAccessToken != null) 'id_access_token': idAccessToken,
        });
    return RequestTokenResponse.fromJson(response);
  }

  /// Changes the password for an account on this homeserver.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-password
  Future<void> changePassword(
    String newPassword, {
    Map<String, dynamic> auth,
  }) async {
    await request(RequestType.POST, '/client/r0/account/password', data: {
      'new_password': newPassword,
      if (auth != null) 'auth': auth,
    });
    return;
  }

  /// The homeserver must check that the given email address is associated with
  /// an account on this homeserver. This API should be used to request
  /// validation tokens when authenticating for the /account/password endpoint.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-password-email-requesttoken
  Future<RequestTokenResponse> resetPasswordUsingEmail(
    String email,
    String clientSecret,
    int sendAttempt, {
    String nextLink,
    String idServer,
    String idAccessToken,
  }) async {
    final response = await request(
        RequestType.POST, '/client/r0/account/password/email/requestToken',
        data: {
          'email': email,
          'send_attempt': sendAttempt,
          'client_secret': clientSecret,
          if (nextLink != null) 'next_link': nextLink,
          if (idServer != null) 'id_server': idServer,
          if (idAccessToken != null) 'id_access_token': idAccessToken,
        });
    return RequestTokenResponse.fromJson(response);
  }

  /// The homeserver must check that the given phone number is associated with
  /// an account on this homeserver. This API should be used to request validation
  /// tokens when authenticating for the /account/password endpoint.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-password-msisdn-requesttoken
  Future<RequestTokenResponse> resetPasswordUsingMsisdn(
    String country,
    String phoneNumber,
    String clientSecret,
    int sendAttempt, {
    String nextLink,
    String idServer,
    String idAccessToken,
  }) async {
    final response = await request(
        RequestType.POST, '/client/r0/account/password/msisdn/requestToken',
        data: {
          'country': country,
          'phone_number': phoneNumber,
          'send_attempt': sendAttempt,
          'client_secret': clientSecret,
          if (nextLink != null) 'next_link': nextLink,
          if (idServer != null) 'id_server': idServer,
          if (idAccessToken != null) 'id_access_token': idAccessToken,
        });
    return RequestTokenResponse.fromJson(response);
  }

  Future<IdServerUnbindResult> deactivateAccount({
    String idServer,
    Map<String, dynamic> auth,
  }) async {
    final response =
        await request(RequestType.POST, '/client/r0/account/deactivate', data: {
      if (idServer != null) 'id_server': idServer,
      if (auth != null) 'auth': auth,
    });

    return IdServerUnbindResult.values.firstWhere(
      (i) =>
          i.toString().split('.').last == response['id_server_unbind_result'],
    );
  }

  Future<bool> usernameAvailable(String username) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/register/available?username=$username',
    );
    return response['available'];
  }

  /// Gets a list of the third party identifiers that the homeserver has
  /// associated with the user's account.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-register-available
  Future<List<ThirdPartyIdentifier>> requestThirdPartyIdentifiers() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/account/3pid',
    );
    return (response['threepids'] as List)
        .map((item) => ThirdPartyIdentifier.fromJson(item))
        .toList();
  }

  /// Adds contact information to the user's account. Homeservers
  /// should use 3PIDs added through this endpoint for password resets
  /// instead of relying on the identity server.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-3pid-add
  Future<void> addThirdPartyIdentifier(
    String clientSecret,
    String sid, {
    Map<String, dynamic> auth,
  }) async {
    await request(RequestType.POST, '/client/r0/account/3pid/add', data: {
      'sid': sid,
      'client_secret': clientSecret,
      if (auth != null && auth.isNotEmpty) 'auth': auth,
    });
    return;
  }

  /// Binds a 3PID to the user's account through the specified identity server.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-3pid-bind
  Future<void> bindThirdPartyIdentifier(
    String clientSecret,
    String sid,
    String idServer,
    String idAccessToken,
  ) async {
    await request(RequestType.POST, '/client/r0/account/3pid/bind', data: {
      'sid': sid,
      'client_secret': clientSecret,
      'id_server': idServer,
      'id_access_token': idAccessToken,
    });
    return;
  }

  /// Removes a third party identifier from the user's account. This might not cause an unbind of the identifier from the identity server.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-3pid-delete
  Future<IdServerUnbindResult> deleteThirdPartyIdentifier(
    String address,
    ThirdPartyIdentifierMedium medium,
    String idServer,
  ) async {
    final response = await request(
        RequestType.POST, '/client/r0/account/3pid/delete',
        data: {
          'address': address,
          'medium': medium.toString().split('.').last,
          'id_server': idServer,
        });
    return IdServerUnbindResult.values.firstWhere(
      (i) =>
          i.toString().split('.').last == response['id_server_unbind_result'],
    );
  }

  /// Removes a user's third party identifier from the provided identity server without removing it from the homeserver.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-3pid-unbind
  Future<IdServerUnbindResult> unbindThirdPartyIdentifier(
    String address,
    ThirdPartyIdentifierMedium medium,
    String idServer,
  ) async {
    final response = await request(
        RequestType.POST, '/client/r0/account/3pid/unbind',
        data: {
          'address': address,
          'medium': medium.toString().split('.').last,
          'id_server': idServer,
        });
    return IdServerUnbindResult.values.firstWhere(
      (i) =>
          i.toString().split('.').last == response['id_server_unbind_result'],
    );
  }

  /// This API should be used to request validation tokens when adding an email address to an account.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-3pid-email-requesttoken
  Future<RequestTokenResponse> requestEmailValidationToken(
    String email,
    String clientSecret,
    int sendAttempt, {
    String nextLink,
    String idServer,
    String idAccessToken,
  }) async {
    final response = await request(
        RequestType.POST, '/client/r0/account/3pid/email/requestToken',
        data: {
          'email': email,
          'send_attempt': sendAttempt,
          'client_secret': clientSecret,
          if (nextLink != null) 'next_link': nextLink,
          if (idServer != null) 'id_server': idServer,
          if (idAccessToken != null) 'id_access_token': idAccessToken,
        });
    return RequestTokenResponse.fromJson(response);
  }

  /// This API should be used to request validation tokens when adding a phone number to an account.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-account-3pid-msisdn-requesttoken
  Future<RequestTokenResponse> requestMsisdnValidationToken(
    String country,
    String phoneNumber,
    String clientSecret,
    int sendAttempt, {
    String nextLink,
    String idServer,
    String idAccessToken,
  }) async {
    final response = await request(
        RequestType.POST, '/client/r0/account/3pid/msisdn/requestToken',
        data: {
          'country': country,
          'phone_number': phoneNumber,
          'send_attempt': sendAttempt,
          'client_secret': clientSecret,
          if (nextLink != null) 'next_link': nextLink,
          if (idServer != null) 'id_server': idServer,
          if (idAccessToken != null) 'id_access_token': idAccessToken,
        });
    return RequestTokenResponse.fromJson(response);
  }

  /// Gets information about the owner of a given access token.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-account-whoami
  Future<String> whoAmI() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/account/whoami',
    );
    return response['user_id'];
  }

  /// Gets information about the server's supported feature set and other relevant capabilities.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-capabilities
  Future<ServerCapabilities> requestServerCapabilities() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/capabilities',
    );
    return ServerCapabilities.fromJson(response['capabilities']);
  }

  /// Uploads a new filter definition to the homeserver. Returns a filter ID that may be used
  /// in future requests to restrict which events are returned to the client.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-user-userid-filter
  Future<String> uploadFilter(
    String userId,
    Filter filter,
  ) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/user/${Uri.encodeComponent(userId)}/filter',
      data: filter.toJson(),
    );
    return response['filter_id'];
  }

  /// Download a filter
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-client-r0-user-userid-filter
  Future<Filter> downloadFilter(String userId, String filterId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/user/${Uri.encodeComponent(userId)}/filter/${Uri.encodeComponent(filterId)}',
    );
    return Filter.fromJson(response);
  }

  /// Synchronise the client's state with the latest state on the server. Clients use this API when
  /// they first log in to get an initial snapshot of the state on the server, and then continue to
  /// call this API to get incremental deltas to the state, and to receive new messages.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-sync
  Future<SyncUpdate> sync({
    String filter,
    String since,
    bool fullState,
    PresenceType setPresence,
    int timeout,
  }) async {
    var atLeastOneParameter = false;
    var action = '/client/r0/sync';
    if (filter != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'filter=${Uri.encodeQueryComponent(filter)}';
      atLeastOneParameter = true;
    }
    if (since != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'since=${Uri.encodeQueryComponent(since)}';
      atLeastOneParameter = true;
    }
    if (fullState != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'full_state=${Uri.encodeQueryComponent(fullState.toString())}';
      atLeastOneParameter = true;
    }
    if (setPresence != null) {
      action += atLeastOneParameter ? '&' : '?';
      action +=
          'set_presence=${Uri.encodeQueryComponent(setPresence.toString().split('.').last)}';
      atLeastOneParameter = true;
    }
    if (timeout != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'timeout=${Uri.encodeQueryComponent(timeout.toString())}';
      atLeastOneParameter = true;
    }
    final response = await request(
      RequestType.GET,
      action,
    );
    return SyncUpdate.fromJson(response);
  }

  /// Get a single event based on roomId/eventId. You must have permission to
  /// retrieve this event e.g. by being a member in the room for this event.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-rooms-roomid-event-eventid
  Future<MatrixEvent> requestEvent(String roomId, String eventId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/event/${Uri.encodeComponent(eventId)}',
    );
    return MatrixEvent.fromJson(response);
  }

  /// Looks up the contents of a state event in a room. If the user is joined to the room then the
  /// state is taken from the current state of the room. If the user has left the room then the
  /// state is taken from the state of the room when they left.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-rooms-roomid-state-eventtype-statekey
  Future<Map<String, dynamic>> requestStateContent(
      String roomId, String eventType,
      [String stateKey]) async {
    var url =
        '/client/r0/rooms/${Uri.encodeComponent(roomId)}/state/${Uri.encodeComponent(eventType)}/';
    if (stateKey != null) {
      url += Uri.encodeComponent(stateKey);
    }
    final response = await request(
      RequestType.GET,
      url,
    );
    return response;
  }

  /// Get the state events for the current state of a room.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-rooms-roomid-state
  Future<List<MatrixEvent>> requestStates(String roomId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/state',
    );
    return (response['chunk'] as List)
        .map((i) => MatrixEvent.fromJson(i))
        .toList();
  }

  /// Get the list of members for this room.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-rooms-roomid-members
  Future<List<MatrixEvent>> requestMembers(
    String roomId, {
    String at,
    Membership membership,
    Membership notMembership,
  }) async {
    var action = '/client/r0/rooms/${Uri.encodeComponent(roomId)}/members';
    var atLeastOneParameter = false;
    if (at != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'at=${Uri.encodeQueryComponent(at)}';
      atLeastOneParameter = true;
    }
    if (membership != null) {
      action += atLeastOneParameter ? '&' : '?';
      action +=
          'membership=${Uri.encodeQueryComponent(membership.toString().split('.').last)}';
      atLeastOneParameter = true;
    }
    if (notMembership != null) {
      action += atLeastOneParameter ? '&' : '?';
      action +=
          'not_membership=${Uri.encodeQueryComponent(notMembership.toString().split('.').last)}';
      atLeastOneParameter = true;
    }
    final response = await request(
      RequestType.GET,
      action,
    );
    return (response['chunk'] as List)
        .map((i) => MatrixEvent.fromJson(i))
        .toList();
  }

  /// This API returns a map of MXIDs to member info objects for members of the room.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-rooms-roomid-joined-members
  Future<Map<String, Profile>> requestJoinedMembers(String roomId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/joined_members',
    );
    return (response['joined'] as Map).map(
      (k, v) => MapEntry(k, Profile.fromJson(v)),
    );
  }

  /// This API returns a list of message and state events for a room. It uses pagination query
  /// parameters to paginate history in the room.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#get-matrix-client-r0-rooms-roomid-messages
  Future<TimelineHistoryResponse> requestMessages(
    String roomId,
    String from,
    Direction dir, {
    String to,
    int limit,
    String filter,
  }) async {
    var action = '/client/r0/rooms/${Uri.encodeComponent(roomId)}/messages';
    action += '?from=${Uri.encodeQueryComponent(from)}';
    action +=
        '&dir=${Uri.encodeQueryComponent(dir.toString().split('.').last)}';
    if (to != null) {
      action += '&to=${Uri.encodeQueryComponent(to)}';
    }
    if (limit != null) {
      action += '&limit=${Uri.encodeQueryComponent(limit.toString())}';
    }
    if (filter != null) {
      action += '&filter=${Uri.encodeQueryComponent(filter)}';
    }
    final response = await request(
      RequestType.GET,
      action,
    );
    return TimelineHistoryResponse.fromJson(response);
  }

  /// State events can be sent using this endpoint.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#put-matrix-client-r0-rooms-roomid-state-eventtype-statekey
  Future<String> sendState(
    String roomId,
    String eventType,
    Map<String, dynamic> content, [
    String stateKey = '',
  ]) async {
    final response = await request(RequestType.PUT,
        '/client/r0/rooms/${Uri.encodeQueryComponent(roomId)}/state/${Uri.encodeQueryComponent(eventType)}/${Uri.encodeQueryComponent(stateKey)}',
        data: content);
    return response['event_id'];
  }

  /// This endpoint is used to send a message event to a room.
  /// Message events allow access to historical events and pagination,
  /// making them suited for "once-off" activity in a room.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#put-matrix-client-r0-rooms-roomid-send-eventtype-txnid
  Future<String> sendMessage(
    String roomId,
    String eventType,
    String txnId,
    Map<String, dynamic> content,
  ) async {
    final response = await request(RequestType.PUT,
        '/client/r0/rooms/${Uri.encodeQueryComponent(roomId)}/send/${Uri.encodeQueryComponent(eventType)}/${Uri.encodeQueryComponent(txnId)}',
        data: content);
    return response['event_id'];
  }

  /// Strips all information out of an event which isn't critical to the integrity of
  /// the server-side representation of the room.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#put-matrix-client-r0-rooms-roomid-redact-eventid-txnid
  Future<String> redact(
    String roomId,
    String eventId,
    String txnId, {
    String reason,
  }) async {
    final response = await request(RequestType.PUT,
        '/client/r0/rooms/${Uri.encodeQueryComponent(roomId)}/redact/${Uri.encodeQueryComponent(eventId)}/${Uri.encodeQueryComponent(txnId)}',
        data: {
          if (reason != null) 'reason': reason,
        });
    return response['event_id'];
  }

  Future<String> createRoom({
    Visibility visibility,
    String roomAliasName,
    String name,
    String topic,
    List<String> invite,
    List<Map<String, dynamic>> invite3pid,
    String roomVersion,
    Map<String, dynamic> creationContent,
    List<Map<String, dynamic>> initialState,
    CreateRoomPreset preset,
    bool isDirect,
    Map<String, dynamic> powerLevelContentOverride,
  }) async {
    final response =
        await request(RequestType.POST, '/client/r0/createRoom', data: {
      if (visibility != null)
        'visibility': visibility.toString().split('.').last,
      if (roomAliasName != null) 'room_alias_name': roomAliasName,
      if (name != null) 'name': name,
      if (topic != null) 'topic': topic,
      if (invite != null) 'invite': invite,
      if (invite3pid != null) 'invite_3pid': invite3pid,
      if (roomVersion != null) 'room_version': roomVersion,
      if (creationContent != null) 'creation_content': creationContent,
      if (initialState != null) 'initial_state': initialState,
      if (preset != null) 'preset': preset.toString().split('.').last,
      if (isDirect != null) 'is_direct': isDirect,
      if (powerLevelContentOverride != null)
        'power_level_content_override': powerLevelContentOverride,
    });
    return response['room_id'];
  }

  /// Create a new mapping from room alias to room ID.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-directory-room-roomalias
  Future<void> createRoomAlias(String alias, String roomId) async {
    await request(
      RequestType.PUT,
      '/client/r0/directory/room/${Uri.encodeComponent(alias)}',
      data: {'room_id': roomId},
    );
    return;
  }

  /// Requests that the server resolve a room alias to a room ID.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-directory-room-roomalias
  Future<RoomAliasInformations> requestRoomAliasInformations(
      String alias) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/directory/room/${Uri.encodeComponent(alias)}',
    );
    return RoomAliasInformations.fromJson(response);
  }

  /// Remove a mapping of room alias to room ID.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#delete-matrix-client-r0-directory-room-roomalias
  Future<void> removeRoomAlias(String alias) async {
    await request(
      RequestType.DELETE,
      '/client/r0/directory/room/${Uri.encodeComponent(alias)}',
    );
    return;
  }

  /// Get a list of aliases maintained by the local server for the given room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-rooms-roomid-aliases
  Future<List<String>> requestRoomAliases(String roomId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/room/${Uri.encodeComponent(roomId)}/aliases',
    );
    return List<String>.from(response['aliases']);
  }

  /// This API returns a list of the user's current rooms.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-joined-rooms
  Future<List<String>> requestJoinedRooms() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/joined_rooms',
    );
    return List<String>.from(response['joined_rooms']);
  }

  /// This API invites a user to participate in a particular room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-invite
  Future<void> inviteToRoom(String roomId, String userId) async {
    await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/invite',
      data: {
        'user_id': userId,
      },
    );
    return;
  }

  /// This API starts a user participating in a particular room, if that user is allowed to participate in that room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-invite
  Future<String> joinRoom(
    String roomId, {
    String thirdPidSignedSender,
    String thirdPidSignedmxid,
    String thirdPidSignedToken,
    Map<String, dynamic> thirdPidSignedSiganture,
  }) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/join',
      data: {
        if (thirdPidSignedSiganture != null)
          'third_party_signed': {
            'sender': thirdPidSignedSender,
            'mxid': thirdPidSignedmxid,
            'token': thirdPidSignedToken,
            'signatures': thirdPidSignedSiganture,
          }
      },
    );
    return response['room_id'];
  }

  /// This API starts a user participating in a particular room, if that user is allowed to participate in that room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-join-roomidoralias
  Future<String> joinRoomOrAlias(
    String roomIdOrAlias, {
    List<String> servers,
    String thirdPidSignedSender,
    String thirdPidSignedmxid,
    String thirdPidSignedToken,
    Map<String, dynamic> thirdPidSignedSiganture,
  }) async {
    var action = '/client/r0/join/${Uri.encodeComponent(roomIdOrAlias)}';
    if (servers != null) {
      for (var i = 0; i < servers.length; i++) {
        if (i == 0) {
          action += '?';
        } else {
          action += '&';
        }
        action += 'server_name=${Uri.encodeQueryComponent(servers[i])}';
      }
    }
    final response = await request(
      RequestType.POST,
      action,
      data: {
        if (thirdPidSignedSiganture != null)
          'third_party_signed': {
            'sender': thirdPidSignedSender,
            'mxid': thirdPidSignedmxid,
            'token': thirdPidSignedToken,
            'signatures': thirdPidSignedSiganture,
          }
      },
    );
    return response['room_id'];
  }

  /// This API stops a user participating in a particular room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-leave
  Future<void> leaveRoom(String roomId) async {
    await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/leave',
    );
    return;
  }

  /// This API stops a user remembering about a particular room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-forget
  Future<void> forgetRoom(String roomId) async {
    await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/forget',
    );
    return;
  }

  /// Kick a user from the room.
  /// The caller must have the required power level in order to perform this operation.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-kick
  Future<void> kickFromRoom(String roomId, String userId,
      {String reason}) async {
    await request(RequestType.POST,
        '/client/r0/rooms/${Uri.encodeComponent(roomId)}/kick',
        data: {
          'user_id': userId,
          if (reason != null) 'reason': reason,
        });
    return;
  }

  /// Ban a user in the room. If the user is currently in the room, also kick them.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-ban
  Future<void> banFromRoom(String roomId, String userId,
      {String reason}) async {
    await request(
        RequestType.POST, '/client/r0/rooms/${Uri.encodeComponent(roomId)}/ban',
        data: {
          'user_id': userId,
          if (reason != null) 'reason': reason,
        });
    return;
  }

  /// Unban a user from the room. This allows them to be invited to the room, and join if they
  /// would otherwise be allowed to join according to its join rules.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-unban
  Future<void> unbanInRoom(String roomId, String userId) async {
    await request(
        RequestType.POST, '/client/r0/rooms/${Uri.encodeComponent(roomId)}/ban',
        data: {
          'user_id': userId,
        });
    return;
  }

  /// Gets the visibility of a given room on the server's public room directory.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-directory-list-room-roomid
  Future<Visibility> requestRoomVisibility(String roomId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/directory/list/room/${Uri.encodeComponent(roomId)}',
    );
    return Visibility.values.firstWhere(
        (v) => v.toString().split('.').last == response['visibility']);
  }

  /// Sets the visibility of a given room in the server's public room directory.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-directory-list-room-roomid
  Future<void> setRoomVisibility(String roomId, Visibility visibility) async {
    await request(
      RequestType.PUT,
      '/client/r0/directory/list/room/${Uri.encodeComponent(roomId)}',
      data: {
        'visibility': visibility.toString().split('.').last,
      },
    );
    return;
  }

  /// Lists the public rooms on the server.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-publicrooms
  Future<PublicRoomsResponse> requestPublicRooms({
    int limit,
    String since,
    String server,
  }) async {
    var action = '/client/r0/publicRooms';
    var atLeastOneParameter = false;
    if (limit != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'limit=${Uri.encodeQueryComponent(limit.toString())}';
      atLeastOneParameter = true;
    }
    if (since != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'since=${Uri.encodeQueryComponent(since.toString())}';
      atLeastOneParameter = true;
    }
    if (server != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'server=${Uri.encodeQueryComponent(server.toString())}';
      atLeastOneParameter = true;
    }
    final response = await request(
      RequestType.GET,
      action,
    );
    return PublicRoomsResponse.fromJson(response);
  }

  /// Lists the public rooms on the server, with optional filter.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-publicrooms
  Future<PublicRoomsResponse> searchPublicRooms({
    String genericSearchTerm,
    int limit,
    String since,
    String server,
    bool includeAllNetworks,
    String thirdPartyInstanceId,
  }) async {
    var action = '/client/r0/publicRooms';
    if (server != null) {
      action += '?server=${Uri.encodeQueryComponent(server.toString())}';
    }
    final response = await request(
      RequestType.POST,
      action,
      data: {
        if (limit != null) 'limit': limit,
        if (since != null) 'since': since,
        if (includeAllNetworks != null)
          'include_all_networks': includeAllNetworks,
        if (thirdPartyInstanceId != null)
          'third_party_instance_id': thirdPartyInstanceId,
        if (genericSearchTerm != null)
          'filter': {
            'generic_search_term': genericSearchTerm,
          },
      },
    );
    return PublicRoomsResponse.fromJson(response);
  }

  /// Performs a search for users. The homeserver may determine which subset of users are searched,
  /// however the homeserver MUST at a minimum consider the users the requesting user shares a
  /// room with and those who reside in public rooms (known to the homeserver). The search MUST
  /// consider local users to the homeserver, and SHOULD query remote users as part of the search.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-user-directory-search
  Future<UserSearchResult> searchUser(
    String searchTerm, {
    int limit,
  }) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/user_directory/search',
      data: {
        'search_term': searchTerm,
        if (limit != null) 'limit': limit,
      },
    );
    return UserSearchResult.fromJson(response);
  }

  /// This API sets the given user's display name. You must have permission to
  /// set this user's display name, e.g. you need to have their access_token.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-profile-userid-displayname
  Future<void> setDisplayname(String userId, String displayname) async {
    await request(
      RequestType.PUT,
      '/client/r0/profile/${Uri.encodeComponent(userId)}/displayname',
      data: {
        'displayname': displayname,
      },
    );
    return;
  }

  /// Get the user's display name. This API may be used to fetch the user's own
  /// displayname or to query the name of other users; either locally or on remote homeservers.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-profile-userid-displayname
  Future<String> requestDisplayname(String userId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/profile/${Uri.encodeComponent(userId)}/displayname',
    );
    return response['displayname'];
  }

  /// This API sets the given user's avatar URL. You must have permission to set
  /// this user's avatar URL, e.g. you need to have their access_token.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-profile-userid-avatar-url
  Future<void> setAvatarUrl(String userId, Uri avatarUrl) async {
    await request(
      RequestType.PUT,
      '/client/r0/profile/${Uri.encodeComponent(userId)}/avatar_url',
      data: {
        'avatar_url': avatarUrl.toString(),
      },
    );
    return;
  }

  /// Get the user's avatar URL. This API may be used to fetch the user's own avatar URL or to
  /// query the URL of other users; either locally or on remote homeservers.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-profile-userid-avatar-url
  Future<Uri> requestAvatarUrl(String userId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/profile/${Uri.encodeComponent(userId)}/avatar_url',
    );
    return Uri.parse(response['avatar_url']);
  }

  /// Get the combined profile information for this user. This API may be used to fetch the user's
  /// own profile information or other users; either locally or on remote homeservers.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-profile-userid-avatar-url
  Future<Profile> requestProfile(String userId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/profile/${Uri.encodeComponent(userId)}',
    );
    return Profile.fromJson(response);
  }

  /// This API provides credentials for the client to use when initiating calls.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-voip-turnserver
  Future<TurnServerCredentials> requestTurnServerCredentials() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/voip/turnServer',
    );
    return TurnServerCredentials.fromJson(response);
  }

  /// This tells the server that the user is typing for the next N milliseconds
  /// where N is the value specified in the timeout key. Alternatively, if typing is false,
  /// it tells the server that the user has stopped typing.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-rooms-roomid-typing-userid
  Future<void> sendTypingNotification(
    String userId,
    String roomId,
    bool typing, {
    int timeout,
  }) async {
    await request(RequestType.PUT,
        '/client/r0/rooms/${Uri.encodeComponent(roomId)}/typing/${Uri.encodeComponent(userId)}',
        data: {
          'typing': typing,
          if (timeout != null) 'timeout': timeout,
        });
    return;
  }

  /// This API updates the marker for the given receipt type to the event ID specified.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-receipt-receipttype-eventid
  ///
  Future<void> sendReceiptMarker(String roomId, String eventId) async {
    await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/receipt/m.read/${Uri.encodeComponent(eventId)}',
    );
    return;
  }

  /// Sets the position of the read marker for a given room, and optionally the read receipt's location.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-read-markers
  Future<void> sendReadMarker(String roomId, String eventId,
      {String readReceiptLocationEventId}) async {
    await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/read_markers',
      data: {
        'm.fully_read': eventId,
        if (readReceiptLocationEventId != null)
          'm.read': readReceiptLocationEventId,
      },
    );
    return;
  }

  /// This API sets the given user's presence state. When setting the status,
  /// the activity time is updated to reflect that activity; the client does not need
  /// to specify the last_active_ago field. You cannot set the presence state of another user.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-presence-userid-status
  Future<void> sendPresence(
    String userId,
    PresenceType presenceType, {
    String statusMsg,
  }) async {
    await request(
      RequestType.PUT,
      '/client/r0/presence/${Uri.encodeComponent(userId)}/status',
      data: {
        'presence': presenceType.toString().split('.').last,
        if (statusMsg != null) 'status_msg': statusMsg,
      },
    );
    return;
  }

  /// Get the given user's presence state.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-presence-userid-status
  Future<PresenceContent> requestPresence(String userId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/presence/${Uri.encodeComponent(userId)}/status',
    );
    return PresenceContent.fromJson(response);
  }

  /// Uploads a file with the name [fileName] as base64 encoded to the server
  /// and returns the mxc url as a string.
  /// https://matrix.org/docs/spec/client_server/r0.6.0#post-matrix-media-r0-upload
  Future<String> upload(Uint8List file, String fileName,
      {String contentType}) async {
    fileName = fileName.split('/').last;
    var headers = <String, String>{};
    headers['Authorization'] = 'Bearer $accessToken';
    headers['Content-Type'] = contentType ?? mime(fileName);
    fileName = Uri.encodeQueryComponent(fileName);
    final url =
        '${homeserver.toString()}/_matrix/media/r0/upload?filename=$fileName';
    final streamedRequest = http.StreamedRequest('POST', Uri.parse(url))
      ..headers.addAll(headers);
    streamedRequest.contentLength = await file.length;
    streamedRequest.sink.add(file);
    streamedRequest.sink.close();
    if (debug) print('[UPLOADING] $fileName');
    var streamedResponse = _testMode ? null : await streamedRequest.send();
    Map<String, dynamic> jsonResponse = json.decode(
      String.fromCharCodes(_testMode
          ? ((fileName == 'file.jpeg')
                  ? '{"content_uri": "mxc://example.com/AQwafuaFswefuhsfAFAgsw"}'
                  : '{"errcode":"M_FORBIDDEN","error":"Cannot upload this content"}')
              .codeUnits
          : await streamedResponse.stream.first),
    );
    if (!jsonResponse.containsKey('content_uri')) {
      throw MatrixException.fromJson(jsonResponse);
    }
    return jsonResponse['content_uri'];
  }

  /// Get information about a URL for the client. Typically this is called when a client sees a
  /// URL in a message and wants to render a preview for the user.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-media-r0-preview-url
  Future<OpenGraphData> requestOpenGraphDataForUrl(Uri url, {int ts}) async {
    var action =
        '${homeserver.toString()}/_matrix/media/r0/preview_url?url=${Uri.encodeQueryComponent(url.toString())}';
    if (ts != null) {
      action += '&ts=${Uri.encodeQueryComponent(ts.toString())}';
    }
    final response = await httpClient.get(action);
    final rawJson = json.decode(response.body.isEmpty ? '{}' : response.body);
    return OpenGraphData.fromJson(rawJson);
  }

  /// This endpoint allows clients to retrieve the configuration of the content repository, such as upload limitations.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-media-r0-config
  Future<int> requestMaxUploadSize() async {
    var action = '${homeserver.toString()}/_matrix/media/r0/config';
    final response = await httpClient.get(action);
    final rawJson = json.decode(response.body.isEmpty ? '{}' : response.body);
    return rawJson['m.upload.size'];
  }

  /// This endpoint is used to send send-to-device events to a set of client devices.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-sendtodevice-eventtype-txnid
  Future<void> sendToDevice(String eventType, String txnId,
      Map<String, Map<String, Map<String, dynamic>>> messages) async {
    await request(
      RequestType.PUT,
      '/client/r0/sendToDevice/${Uri.encodeComponent(eventType)}/${Uri.encodeComponent(txnId)}',
      data: {
        'messages': messages,
      },
    );
    return;
  }

  /// Gets information about all devices for the current user.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-devices
  Future<List<Device>> requestDevices() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/devices',
    );
    return (response['devices'] as List)
        .map((i) => Device.fromJson(i))
        .toList();
  }

  /// Gets information on a single device, by device id.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-devices-deviceid
  Future<Device> requestDevice(String deviceId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/devices/${Uri.encodeComponent(deviceId)}',
    );
    return Device.fromJson(response);
  }

  /// Updates the metadata on the given device.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-devices-deviceid
  Future<void> setDeviceMetadata(String deviceId, {String displayName}) async {
    await request(
        RequestType.PUT, '/client/r0/devices/${Uri.encodeComponent(deviceId)}',
        data: {
          if (displayName != null) 'display_name': displayName,
        });
    return;
  }

  /// Deletes the given device, and invalidates any access token associated with it.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#delete-matrix-client-r0-devices-deviceid
  Future<void> deleteDevice(String deviceId,
      {Map<String, dynamic> auth}) async {
    await request(RequestType.DELETE,
        '/client/r0/devices/${Uri.encodeComponent(deviceId)}',
        data: {
          if (auth != null) 'auth': auth,
        });
    return;
  }

  /// Deletes the given devices, and invalidates any access token associated with them.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-delete-devices
  Future<void> deleteDevices(List<String> deviceIds,
      {Map<String, dynamic> auth}) async {
    await request(RequestType.POST, '/client/r0/delete_devices', data: {
      'devices': deviceIds,
      if (auth != null) 'auth': auth,
    });
    return;
  }

  /// Publishes end-to-end encryption keys for the device.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-keys-query
  Future<Map<String, int>> uploadDeviceKeys(
      {MatrixDeviceKeys deviceKeys, Map<String, dynamic> oneTimeKeys}) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/keys/upload',
      data: {
        if (deviceKeys != null) 'device_keys': deviceKeys.toJson(),
        if (oneTimeKeys != null) 'one_time_keys': oneTimeKeys,
      },
    );
    return Map<String, int>.from(response['one_time_key_counts']);
  }

  /// Returns the current devices and identity keys for the given users.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-keys-query
  Future<KeysQueryResponse> requestDeviceKeys(
    Map<String, dynamic> deviceKeys, {
    int timeout,
    String token,
  }) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/keys/query',
      data: {
        'device_keys': deviceKeys,
        if (timeout != null) 'timeout': timeout,
        if (token != null) 'token': token,
      },
    );
    return KeysQueryResponse.fromJson(response);
  }

  /// Claims one-time keys for use in pre-key messages.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-keys-claim
  Future<OneTimeKeysClaimResponse> requestOneTimeKeys(
    Map<String, Map<String, String>> oneTimeKeys, {
    int timeout,
  }) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/keys/claim',
      data: {
        'one_time_keys': oneTimeKeys,
        if (timeout != null) 'timeout': timeout,
      },
    );
    return OneTimeKeysClaimResponse.fromJson(response);
  }

  /// Gets a list of users who have updated their device identity keys since a previous sync token.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-keys-upload
  Future<DeviceListsUpdate> requestDeviceListsUpdate(
      String from, String to) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/keys/changes?from=${Uri.encodeQueryComponent(from)}&to=${Uri.encodeQueryComponent(to)}',
    );
    return DeviceListsUpdate.fromJson(response);
  }

  /// Gets all currently active pushers for the authenticated user.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-pushers
  Future<List<Pusher>> requestPushers() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/pushers',
    );
    return (response['pushers'] as List)
        .map((i) => Pusher.fromJson(i))
        .toList();
  }

  /// This endpoint allows the creation, modification and deletion of pushers
  /// for this user ID. The behaviour of this endpoint varies depending on the
  /// values in the JSON body.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-pushers-set
  Future<void> setPusher(Pusher pusher, {bool append}) async {
    var data = pusher.toJson();
    if (append != null) {
      data['append'] = append;
    }
    await request(
      RequestType.POST,
      '/client/r0/pushers/set',
    );
    return;
  }

  /// This API is used to paginate through the list of events that the user has
  /// been, or would have been notified about.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-notifications
  Future<NotificationsQueryResponse> requestNotifications({
    String from,
    int limit,
    String only,
  }) async {
    var action = '/client/r0/notifications';
    var atLeastOneParameter = false;
    if (from != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'from=${Uri.encodeQueryComponent(from.toString())}';
      atLeastOneParameter = true;
    }
    if (limit != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'limit=${Uri.encodeQueryComponent(limit.toString())}';
      atLeastOneParameter = true;
    }
    if (only != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'only=${Uri.encodeQueryComponent(only.toString())}';
      atLeastOneParameter = true;
    }
    final response = await request(
      RequestType.GET,
      action,
    );
    return NotificationsQueryResponse.fromJson(response);
  }

  /// Retrieve all push rulesets for this user. Clients can "drill-down"
  /// on the rulesets by suffixing a scope to this path e.g. /pushrules/global/.
  /// This will return a subset of this data under the specified key e.g. the global key.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-pushrules
  Future<PushRuleSet> requestPushRules() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/pushrules',
    );
    return PushRuleSet.fromJson(response['global']);
  }

  /// Retrieve a single specified push rule.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-pushrules-scope-kind-ruleid
  Future<PushRule> requestPushRule(
    String scope,
    PushRuleKind kind,
    String ruleId,
  ) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}',
    );
    return PushRule.fromJson(response);
  }

  /// This endpoint removes the push rule defined in the path.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#delete-matrix-client-r0-pushrules-scope-kind-ruleid
  Future<void> deletePushRule(
    String scope,
    PushRuleKind kind,
    String ruleId,
  ) async {
    await request(
      RequestType.DELETE,
      '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}',
    );
    return;
  }

  /// This endpoint allows the creation, modification and deletion of pushers for this user ID.
  /// The behaviour of this endpoint varies depending on the values in the JSON body.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-pushrules-scope-kind-ruleid
  Future<void> setPushRule(
    String scope,
    PushRuleKind kind,
    String ruleId,
    List<PushRuleAction> actions, {
    String before,
    String after,
    List<PushConditions> conditions,
    String pattern,
  }) async {
    var action =
        '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}';
    var atLeastOneParameter = false;
    if (before != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'before=${Uri.encodeQueryComponent(before.toString())}';
      atLeastOneParameter = true;
    }
    if (after != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'after=${Uri.encodeQueryComponent(after.toString())}';
      atLeastOneParameter = true;
    }
    await request(RequestType.PUT, action, data: {
      'actions': actions.map((i) => i.toString().split('.').last).toList(),
      if (conditions != null)
        'conditions':
            conditions.map((i) => i.toString().split('.').last).toList(),
      if (pattern != null) 'pattern': pattern,
    });
    return;
  }

  /// This endpoint gets whether the specified push rule is enabled.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-pushrules-scope-kind-ruleid-enabled
  Future<bool> requestPushRuleEnabled(
    String scope,
    PushRuleKind kind,
    String ruleId,
  ) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}/enabled',
    );
    return response['enabled'];
  }

  /// This endpoint allows clients to enable or disable the specified push rule.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-pushrules-scope-kind-ruleid-enabled
  Future<void> enablePushRule(
    String scope,
    PushRuleKind kind,
    String ruleId,
    bool enabled,
  ) async {
    await request(
      RequestType.PUT,
      '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}/enabled',
      data: {'enabled': enabled},
    );
    return;
  }

  /// This endpoint get the actions for the specified push rule.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-pushrules-scope-kind-ruleid-actions
  Future<List<PushRuleAction>> requestPushRuleActions(
    String scope,
    PushRuleKind kind,
    String ruleId,
  ) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}/actions',
    );
    return (response['actions'] as List)
        .map((i) => PushRuleAction.values
            .firstWhere((a) => a.toString().split('.').last == i))
        .toList();
  }

  /// This endpoint allows clients to change the actions of a push rule. This can be used to change the actions of builtin rules.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-pushrules-scope-kind-ruleid-actions
  Future<void> setPushRuleActions(
    String scope,
    PushRuleKind kind,
    String ruleId,
    List<PushRuleAction> actions,
  ) async {
    await request(
      RequestType.PUT,
      '/client/r0/pushrules/${Uri.encodeComponent(scope)}/${Uri.encodeComponent(kind.toString().split('.').last)}/${Uri.encodeComponent(ruleId)}/actions',
      data: {
        'actions': actions.map((a) => a.toString().split('.').last).toList()
      },
    );
    return;
  }

  /// Performs a full text search across different categories.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-search
  /// Please note: The specification is not 100% clear what it is expecting and sending here.
  /// So we stick with pure json until we have more informations.
  Future<Map<String, dynamic>> globalSearch(Map<String, dynamic> query) async {
    return await request(
      RequestType.POST,
      '/client/r0/search',
      data: query,
    );
  }

  /// This will listen for new events related to a particular room and return them to the
  /// caller. This will block until an event is received, or until the timeout is reached.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-events
  Future<EventsSyncUpdate> requestEvents({
    String from,
    int timeout,
    String roomId,
  }) async {
    var action = '/client/r0/events';
    var atLeastOneParameter = false;
    if (from != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'from=${Uri.encodeQueryComponent(from)}';
      atLeastOneParameter = true;
    }
    if (timeout != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'timeout=${Uri.encodeQueryComponent(timeout.toString())}';
      atLeastOneParameter = true;
    }
    if (roomId != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'roomId=${Uri.encodeQueryComponent(roomId)}';
      atLeastOneParameter = true;
    }
    final response = await request(RequestType.GET, action);
    return EventsSyncUpdate.fromJson(response);
  }

  /// List the tags set by a user on a room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-user-userid-rooms-roomid-tags
  Future<Map<String, Tag>> requestRoomTags(String userId, String roomId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/user/${Uri.encodeQueryComponent(userId)}/rooms/${Uri.encodeQueryComponent(roomId)}/tags',
    );
    return (response['tags'] as Map).map(
      (k, v) => MapEntry(k, Tag.fromJson(v)),
    );
  }

  /// Add a tag to the room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-user-userid-rooms-roomid-tags-tag
  Future<void> addRoomTag(
    String userId,
    String roomId,
    String tag, {
    double order,
  }) async {
    await request(RequestType.PUT,
        '/client/r0/user/${Uri.encodeQueryComponent(userId)}/rooms/${Uri.encodeQueryComponent(roomId)}/tags/${Uri.encodeQueryComponent(tag)}',
        data: {
          if (order != null) 'order': order,
        });
    return;
  }

  /// Remove a tag from the room.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-user-userid-rooms-roomid-tags-tag
  Future<void> removeRoomTag(String userId, String roomId, String tag) async {
    await request(
      RequestType.DELETE,
      '/client/r0/user/${Uri.encodeQueryComponent(userId)}/rooms/${Uri.encodeQueryComponent(roomId)}/tags/${Uri.encodeQueryComponent(tag)}',
    );
    return;
  }

  /// Set some account_data for the client. This config is only visible to the user that set the account_data.
  /// The config will be synced to clients in the top-level account_data.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-user-userid-account-data-type
  Future<void> setAccountData(
    String userId,
    String type,
    Map<String, dynamic> content,
  ) async {
    await request(
      RequestType.PUT,
      '/client/r0/user/${Uri.encodeQueryComponent(userId)}/account_data/${Uri.encodeQueryComponent(type)}',
      data: content,
    );
    return;
  }

  /// Get some account_data for the client. This config is only visible to the user that set the account_data.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-user-userid-account-data-type
  Future<Map<String, dynamic>> requestAccountData(
    String userId,
    String type,
  ) async {
    return await request(
      RequestType.GET,
      '/client/r0/user/${Uri.encodeQueryComponent(userId)}/account_data/${Uri.encodeQueryComponent(type)}',
    );
  }

  /// Set some account_data for the client on a given room. This config is only visible to the user that set
  /// the account_data. The config will be synced to clients in the per-room account_data.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#put-matrix-client-r0-user-userid-rooms-roomid-account-data-type
  Future<void> setRoomAccountData(
    String userId,
    String roomId,
    String type,
    Map<String, dynamic> content,
  ) async {
    await request(
      RequestType.PUT,
      '/client/r0/user/${Uri.encodeQueryComponent(userId)}/rooms/${Uri.encodeQueryComponent(roomId)}/account_data/${Uri.encodeQueryComponent(type)}',
      data: content,
    );
    return;
  }

  /// Get some account_data for the client on a given room. This config is only visible to the user that set the account_data.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-user-userid-rooms-roomid-account-data-type
  Future<Map<String, dynamic>> requestRoomAccountData(
    String userId,
    String roomId,
    String type,
  ) async {
    return await request(
      RequestType.GET,
      '/client/r0/user/${Uri.encodeQueryComponent(userId)}/rooms/${Uri.encodeQueryComponent(roomId)}/account_data/${Uri.encodeQueryComponent(type)}',
    );
  }

  /// Gets information about a particular user.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-admin-whois-userid
  Future<WhoIsInfo> requestWhoIsInfo(String userId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/admin/whois/${Uri.encodeQueryComponent(userId)}',
    );
    return WhoIsInfo.fromJson(response);
  }

  /// This API returns a number of events that happened just before and after the specified event.
  /// This allows clients to get the context surrounding an event.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-rooms-roomid-context-eventid
  Future<EventContext> requestEventContext(
    String roomId,
    String eventId, {
    int limit,
    String filter,
  }) async {
    var action =
        '/client/r0/rooms/${Uri.encodeQueryComponent(roomId)}/context/${Uri.encodeQueryComponent(eventId)}';
    var atLeastOneParameter = false;
    if (filter != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'filter=${Uri.encodeQueryComponent(filter)}';
      atLeastOneParameter = true;
    }
    if (limit != null) {
      action += atLeastOneParameter ? '&' : '?';
      action += 'limit=${Uri.encodeQueryComponent(limit.toString())}';
      atLeastOneParameter = true;
    }
    final response = await request(RequestType.GET, action);
    return EventContext.fromJson(response);
  }

  /// Reports an event as inappropriate to the server, which may then notify the appropriate people.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#post-matrix-client-r0-rooms-roomid-report-eventid
  Future<void> reportEvent(
    String roomId,
    String eventId,
    String reason,
    int score,
  ) async {
    await request(RequestType.POST,
        '/client/r0/rooms/${Uri.encodeQueryComponent(roomId)}/report/${Uri.encodeQueryComponent(eventId)}',
        data: {
          'reason': reason,
          'score': score,
        });
    return;
  }

  /// Fetches the overall metadata about protocols supported by the homeserver. Includes
  /// both the available protocols and all fields required for queries against each protocol.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-thirdparty-protocols
  Future<Map<String, SupportedProtocol>> requestSupportedProtocols() async {
    final response = await request(
      RequestType.GET,
      '/client/r0/thirdparty/protocols',
    );
    return response.map((k, v) => MapEntry(k, SupportedProtocol.fromJson(v)));
  }

  /// Fetches the metadata from the homeserver about a particular third party protocol.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-thirdparty-protocol-protocol
  Future<SupportedProtocol> requestSupportedProtocol(String protocol) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/thirdparty/protocol/${Uri.encodeComponent(protocol)}',
    );
    return SupportedProtocol.fromJson(response);
  }

  /// Requesting this endpoint with a valid protocol name results in a list of successful
  /// mapping results in a JSON array.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-thirdparty-location-protocol
  Future<List<ThirdPartyLocation>> requestThirdPartyLocations(
      String protocol) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/thirdparty/location/${Uri.encodeComponent(protocol)}',
    );
    return (response['chunk'] as List)
        .map((i) => ThirdPartyLocation.fromJson(i))
        .toList();
  }

  /// Retrieve a Matrix User ID linked to a user on the third party service, given a set of
  /// user parameters.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-thirdparty-user-protocol
  Future<List<ThirdPartyUser>> requestThirdPartyUsers(String protocol) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/thirdparty/user/${Uri.encodeComponent(protocol)}',
    );
    return (response['chunk'] as List)
        .map((i) => ThirdPartyUser.fromJson(i))
        .toList();
  }

  /// Retrieve an array of third party network locations from a Matrix room alias.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-thirdparty-location
  Future<List<ThirdPartyLocation>> requestThirdPartyLocationsByAlias(
      String alias) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/thirdparty/location?alias=${Uri.encodeComponent(alias)}',
    );
    return (response['chunk'] as List)
        .map((i) => ThirdPartyLocation.fromJson(i))
        .toList();
  }

  /// Retrieve an array of third party users from a Matrix User ID.
  /// https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-thirdparty-user
  Future<List<ThirdPartyUser>> requestThirdPartyUsersByUserId(
      String userId) async {
    final response = await request(
      RequestType.GET,
      '/client/r0/thirdparty/user?userid=${Uri.encodeComponent(userId)}',
    );
    return (response['chunk'] as List)
        .map((i) => ThirdPartyUser.fromJson(i))
        .toList();
  }

  Future<OpenIdCredentials> requestOpenIdCredentials(String userId) async {
    final response = await request(
      RequestType.POST,
      '/client/r0/user/${Uri.encodeComponent(userId)}/openid/request_token',
    );
    return OpenIdCredentials.fromJson(response);
  }

  Future<void> upgradeRoom(String roomId, String version) async {
    await request(
      RequestType.POST,
      '/client/r0/rooms/${Uri.encodeComponent(roomId)}/upgrade',
      data: {'new_version': version},
    );
    return;
  }
}
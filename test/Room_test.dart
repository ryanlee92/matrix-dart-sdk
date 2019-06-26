/*
 * Copyright (c) 2019 Zender & Kurtz GbR.
 *
 * Authors:
 *   Christian Pauly <krille@famedly.com>
 *   Marcel Radzio <mtrnord@famedly.com>
 *
 * This file is part of famedlysdk.
 *
 * famedlysdk is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * famedlysdk is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with famedlysdk.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:famedlysdk/src/Room.dart';
import 'package:famedlysdk/src/Client.dart';
import 'package:famedlysdk/src/User.dart';
import 'FakeMatrixApi.dart';

void main() {
  Client matrix;
  Room room;

  /// All Tests related to the Event
  group("Room", () {
    test('Login', () async {
      matrix = Client("testclient", debug: true);
      matrix.connection.httpClient = FakeMatrixApi();

      final bool checkResp =
          await matrix.checkServer("https://fakeServer.notExisting");

      final bool loginResp = await matrix.login("test", "1234");

      expect(checkResp, true);
      expect(loginResp, true);
    });

    test("Create from json", () async {
      final String id = "!localpart:server.abc";
      final String name = "My Room";
      final String membership = "join";
      final String topic = "This is my own room";
      final int unread = DateTime.now().millisecondsSinceEpoch;
      final int notificationCount = 2;
      final int highlightCount = 1;
      final String fullyRead = "fjh82jdjifd:server.abc";
      final String notificationSettings = "all";
      final String guestAccess = "forbidden";
      final String historyVisibility = "invite";
      final String joinRules = "invite";
      final int now = DateTime.now().millisecondsSinceEpoch;
      final String msgtype = "m.text";
      final String body = "Hello World";
      final String formatted_body = "<b>Hello</b> World";
      final String contentJson =
          '{"msgtype":"$msgtype","body":"$body","formatted_body":"$formatted_body"}';

      final Map<String, dynamic> jsonObj = {
        "id": id,
        "membership": membership,
        "topic": name,
        "description": topic,
        "avatar_url": "",
        "notification_count": notificationCount,
        "highlight_count": highlightCount,
        "unread": unread,
        "fully_read": fullyRead,
        "notification_settings": notificationSettings,
        "direct_chat_matrix_id": "",
        "draft": "",
        "prev_batch": "",
        "guest_access": guestAccess,
        "history_visibility": historyVisibility,
        "join_rules": joinRules,
        "power_events_default": 0,
        "power_state_default": 0,
        "power_redact": 0,
        "power_invite": 0,
        "power_ban": 0,
        "power_kick": 0,
        "power_user_default": 0,
        "power_event_avatar": 0,
        "power_event_history_visibility": 0,
        "power_event_canonical_alias": 0,
        "power_event_aliases": 0,
        "power_event_name": 0,
        "power_event_power_levels": 0,
        "content_json": contentJson,
      };

      room = await Room.getRoomFromTableRow(jsonObj, matrix);

      expect(room.id, id);
      expect(room.membership, membership);
      expect(room.name, name);
      expect(room.topic, topic);
      expect(room.avatar.mxc, "");
      expect(room.notificationCount, notificationCount);
      expect(room.highlightCount, highlightCount);
      expect(room.unread.toTimeStamp(), unread);
      expect(room.fullyRead, fullyRead);
      expect(room.notificationSettings, notificationSettings);
      expect(room.directChatMatrixID, "");
      expect(room.draft, "");
      expect(room.prev_batch, "");
      expect(room.guestAccess, guestAccess);
      expect(room.historyVisibility, historyVisibility);
      expect(room.joinRules, joinRules);
      expect(room.lastMessage, body);
      expect(room.timeCreated.toTimeStamp() >= now, true);
      room.powerLevels.forEach((String key, int value) {
        expect(value, 0);
      });
    });

    test("sendReadReceipt", () async {
      final dynamic resp =
          await room.sendReadReceipt("§1234:fakeServer.notExisting");
      expect(resp, {});
    });

    test("requestParticipants", () async {
      final List<User> participants = await room.requestParticipants();
      expect(participants.length, 1);
      User user = participants[0];
      expect(user.id, "@alice:example.org");
      expect(user.displayName, "Alice Margatroid");
      expect(user.membership, "join");
      expect(user.avatarUrl.mxc, "mxc://example.org/SEsfnsuifSDFSSEF");
      expect(user.room.id, "!localpart:server.abc");
    });
  });
}
using Singularity.MediaSources;
using Singularity.MediaPlugins;

const string SP_TRACK = """{"id":"t1","uri":"spotify:track:t1","name":"Low Tide","duration_ms":200000,"artists":[{"name":"Northfield Quartet"}],"album":{"name":"Glass Harbor","images":[{"url":"https://i.example/a.jpg"}]},"external_urls":{"spotify":"https://open.spotify.com/track/t1"}}""";

async void spotify_case () {
    var m = new MockServer ();
    bool playing = false;
    string last_play = "";
    bool premium = true;
    int limited = 0;
    m.route ("/v1/me/tracks", (msg, path, q, body) => {
        if (msg.get_request_headers ().get_one ("Authorization") != "Bearer at") {
            msg.set_status (401, null);
            return;
        }
        int off = int.parse (q.lookup ("offset") ?? "0");
        assert (q.lookup ("limit") == "20");
        var sb = new StringBuilder ();
        int n = off == 0 ? 20 : 5;
        for (int i = 0; i < n; i++) {
            if (i > 0) sb.append (",");
            sb.append ("{\"track\":" + SP_TRACK + "}");
        }
        MockServer.json (msg, "{\"items\":[%s],\"total\":25}".printf (sb.str));
    });
    m.route ("/v1/me/following", (msg, path, q, body) => {
        assert (q.lookup ("type") == "artist");
        if (q.lookup ("after") == null) MockServer.json (msg, """{"artists":{"items":[{"id":"ar1","name":"Northfield Quartet","images":[]}],"total":2,"cursors":{"after":"ar1"}}}""");
        else MockServer.json (msg, """{"artists":{"items":[{"id":"ar2","name":"The Lattice","images":[]}],"total":2,"cursors":{"after":null}}}""");
    });
    m.route ("/v1/artists/ar1/albums", (msg, path, q, body) => {
        MockServer.json (msg, """{"items":[{"id":"al1","name":"Glass Harbor","artists":[{"name":"Northfield Quartet"}],"images":[]}],"total":1}""");
    });
    m.route ("/v1/me/player/queue", (msg, path, q, body) => {
        if (msg.get_method () == "POST") {
            assert (q.lookup ("uri") == "spotify:track:t1");
            msg.set_status (204, null);
            return;
        }
        MockServer.json (msg, "{\"currently_playing\":%s,\"queue\":[%s,{\"type\":\"episode\",\"name\":\"Pod\"}]}".printf (SP_TRACK, SP_TRACK));
    });
    m.route ("/v1/me/playlists", (msg, path, q, body) => {
        MockServer.json (msg, """{"items":[{"id":"pl1","name":"Morning","owner":{"display_name":"alice"},"images":[{"url":"https://i.example/p.jpg"}],"external_urls":{"spotify":"https://open.spotify.com/playlist/pl1"}}],"total":1}""");
    });
    m.route ("/v1/playlists/pl1/items", (msg, path, q, body) => {
        MockServer.json (msg, "{\"items\":[{\"item\":%s},{\"item\":{\"type\":\"episode\",\"name\":\"Pod\"}}],\"total\":2}".printf (SP_TRACK));
    });
    m.route ("/v1/search", (msg, path, q, body) => {
        if (limited > 0) {
            limited--;
            msg.set_status (429, null);
            msg.get_response_headers ().replace ("Retry-After", "1");
            return;
        }
        assert (q.lookup ("limit") == "10");
        MockServer.json (msg, "{\"tracks\":{\"items\":[%s],\"total\":30},\"albums\":{\"items\":[{\"id\":\"al1\",\"name\":\"Glass Harbor\",\"artists\":[{\"name\":\"Northfield Quartet\"}],\"release_date\":\"2021-01-01\",\"images\":[]}]},\"playlists\":{\"items\":[null]}}".printf (SP_TRACK));
    });
    m.route ("/v1/me/player/devices", (msg, path, q, body) => {
        MockServer.json (msg, """{"devices":[{"id":"dev1","name":"Kitchen","type":"Speaker","is_active":false,"volume_percent":40},{"id":"dev2","name":"Phone","type":"Smartphone","is_active":true,"volume_percent":70}]}""");
    });
    m.route ("PUT /v1/me/player/play", (msg, path, q, body) => {
        if (!premium) {
            MockServer.json (msg, """{"error":{"status":403,"message":"Player command failed: Premium required","reason":"PREMIUM_REQUIRED"}}""", 403);
            return;
        }
        playing = true;
        last_play = body;
        msg.set_status (204, null);
    });
    m.route ("PUT /v1/me/player/pause", (msg, path, q, body) => {
        playing = false;
        msg.set_status (204, null);
    });
    m.route ("PUT /v1/me/player", (msg, path, q, body) => {
        last_play = body;
        msg.set_status (204, null);
    });
    m.route ("GET /v1/me/player", (msg, path, q, body) => {
        MockServer.json (msg, "{\"is_playing\":%s,\"progress_ms\":12000,\"item\":%s,\"device\":{\"id\":\"dev2\",\"name\":\"Phone\",\"type\":\"Smartphone\",\"is_active\":true,\"volume_percent\":70}}".printf (playing ? "true" : "false", SP_TRACK));
    });
    var host = new TestHost ();
    var src = new SpotifySource ();
    src.activate (host);
    src.links_override = new Gee.ArrayList<AccountLink> ();
    assert (!src.available);
    assert ((src.features & SourceFeatures.ISOLATED) != 0);
    var l = test_link ("sp", "spotify", "", "alice", "at");
    l.mechanism = "oauth2";
    l.set_endpoint ("spotify-api", m.base_url + "/v1/");
    src.links_override.add (l);
    try {
        var root = yield src.browse (null, null, null);
        assert (root.items.size == 5);
        var arts = yield src.browse (root.items[3].id, null, null);
        assert (arts.items.size == 1 && arts.next_token == "ar1" && arts.items[0].kind == ItemKind.ARTIST);
        var arts2 = yield src.browse (root.items[3].id, arts.next_token, null);
        assert (arts2.items.size == 1 && arts2.next_token == null);
        var discs = yield src.browse (arts.items[0].id, null, null);
        assert (discs.items.size == 1 && discs.items[0].kind == ItemKind.ALBUM);
        var queue = yield src.browse (root.items[4].id, null, null);
        assert (queue.items.size == 2);
        var liked = yield src.browse (root.items[0].id, null, null);
        assert (liked.items.size == 20 && liked.next_token == "20");
        var t = liked.items[0];
        assert (t.attribution == "Spotify" && t.external_url == "https://open.spotify.com/track/t1" && t.image_url == "https://i.example/a.jpg");
        var more = yield src.browse (root.items[0].id, liked.next_token, null);
        assert (more.items.size == 5 && more.next_token == null);
        var pls = yield src.browse (root.items[1].id, null, null);
        assert (pls.items.size == 1 && pls.items[0].kind == ItemKind.PLAYLIST);
        var pl = yield src.browse (pls.items[0].id, null, null);
        assert (pl.items.size == 1);
        var found = yield src.search ("low", MediaKind.AUDIO, null, null);
        assert (found.items.size == 2 && found.next_token == "10");
        var pb = yield src.resolve (t, null);
        assert (pb.kind == PlaybackKind.REMOTE && pb.remote != null);
        var player = pb.remote;
        int changes = 0;
        player.state_changed.connect (() => changes++);
        var devs = yield player.devices (null);
        assert (devs.size == 2 && devs[1].active && devs[0].device_type == "speaker");
        yield player.play_item (t, pls.items[0]);
        assert (last_play.contains ("\"context_uri\":\"spotify:playlist:pl1\"") && last_play.contains ("\"uri\":\"spotify:track:t1\""));
        assert (m.saw ("PUT /v1/me/player/play?device_id=dev2"));
        assert (player.state == PlaybackState.PLAYING);
        yield ((RemoteQueue) player).add_to_queue (t);
        assert (m.saw ("POST /v1/me/player/queue"));
        yield player.pause ();
        assert (player.state == PlaybackState.PAUSED && !playing);
        yield ((SpotifyConnect) player).refresh ();
        assert (player.position_ms == 12000 && player.device.name == "Phone" && player.current.title == "Low Tide");
        yield player.transfer ("dev1", true);
        assert (last_play.contains ("\"device_ids\":[\"dev1\"]"));
        assert (changes >= 3);
        premium = false;
        try {
            yield player.resume ();
            assert_not_reached ();
        } catch (MediaError.UNSUPPORTED e) {
            assert (e.message.contains ("Premium"));
        }
        limited = 1;
        try {
            yield src.search ("again", MediaKind.AUDIO, null, null);
            assert_not_reached ();
        } catch (MediaError.RATE_LIMITED e) {
            assert (e.message.contains ("1"));
        }
        try {
            yield src.search ("again", MediaKind.AUDIO, null, null);
            assert_not_reached ();
        } catch (MediaError.RATE_LIMITED e) {
        }
    } catch (Error e) {
        error ("spotify: %s", e.message);
    }
    m.stop ();
}

void test_spotify () {
    var loop = new MainLoop ();
    spotify_case.begin ((o, r) => {
        spotify_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

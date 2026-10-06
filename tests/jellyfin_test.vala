using Singularity.MediaSources;
using Singularity.MediaPlugins;

MockServer jellyfin_mock () {
    var m = new MockServer ();
    m.route ("/Users/AuthenticateByName", (msg, path, q, body) => {
        if (body.contains ("\"Pw\":\"secret\"")) MockServer.json (msg, """{"AccessToken":"tok1","User":{"Id":"u1","Name":"Alice"}}""");
        else msg.set_status (401, null);
    });
    m.route ("/Users/u1/Views", (msg, path, q, body) => {
        if (msg.get_request_headers ().get_one ("X-Emby-Token") != "tok1") {
            msg.set_status (401, null);
            return;
        }
        MockServer.json (msg, """{"Items":[{"Id":"lib-music","Name":"Music","CollectionType":"music"},{"Id":"lib-movies","Name":"Movies","CollectionType":"movies"}],"TotalRecordCount":2}""");
    });
    m.route ("/Users/u1/Items", (msg, path, q, body) => {
        string types = q != null ? (q.lookup ("IncludeItemTypes") ?? "") : "";
        int start = q != null ? int.parse (q.lookup ("StartIndex") ?? "0") : 0;
        if (q != null && q.lookup ("searchTerm") != null) {
            MockServer.json (msg, """{"Items":[{"Id":"t2","Name":"Lantern Walk","Type":"Audio","Artists":["Northfield Quartet"],"Album":"Glass Harbor","RunTimeTicks":270000000}],"TotalRecordCount":1}""");
            return;
        }
        if (types == "MusicAlbum") {
            if (start == 0) {
                var sb = new StringBuilder ("""{"Items":[""");
                for (int i = 0; i < 60; i++) {
                    if (i > 0) sb.append (",");
                    sb.append ("""{"Id":"al%d","Name":"Album %02d","Type":"MusicAlbum","AlbumArtist":"Band","ProductionYear":2020,"ImageTags":{"Primary":"tag%d"}}""".printf (i, i, i));
                }
                sb.append ("""],"TotalRecordCount":61}""");
                MockServer.json (msg, sb.str);
            } else {
                MockServer.json (msg, """{"Items":[{"Id":"al60","Name":"Album 60","Type":"MusicAlbum","AlbumArtist":"Band"}],"TotalRecordCount":61}""");
            }
            return;
        }
        if (q != null && q.lookup ("ParentId") == "al1") {
            MockServer.json (msg, """{"Items":[{"Id":"t1","Name":"Low Tide","Type":"Audio","Artists":["Northfield Quartet"],"Album":"Glass Harbor","IndexNumber":1,"RunTimeTicks":2000000000,"AlbumId":"al1","AlbumPrimaryImageTag":"x"}],"TotalRecordCount":1}""");
            return;
        }
        MockServer.json (msg, """{"Items":[],"TotalRecordCount":0}""");
    });
    m.route ("/Sessions/*", (msg, path, q, body) => {
        assert (body.contains ("\"ItemId\":\"t1\""));
        msg.set_status (204, null);
    });
    m.route ("/Artists/AlbumArtists", (msg, path, q, body) => {
        MockServer.json (msg, """{"Items":[{"Id":"ar1","Name":"Northfield Quartet","Type":"MusicArtist"}],"TotalRecordCount":1}""");
    });
    return m;
}

async void jellyfin_case () {
    var m = jellyfin_mock ();
    var host = new TestHost ();
    var src = new JellyfinSource ();
    src.activate (host);
    src.links_override = new Gee.ArrayList<AccountLink> ();
    assert (!src.available);
    try {
        var empty = yield src.browse (null, null, null);
        assert (empty.items.size == 0 && empty.action_uri == "settings:accounts");
    } catch (Error e) {
        assert_not_reached ();
    }
    var l = test_link ("acc1", "jellyfin", m.base_url, "alice", "secret");
    l.set_endpoint ("jellyfin", m.base_url + "/");
    src.links_override.add (l);
    assert (src.available);
    try {
        var root = yield src.browse (null, null, null);
        assert (root.items.size == 2);
        assert (root.items[0].title == "Music" && root.items[0].browsable);
        assert (root.items[1].title == "Playlists");
        var lib = yield src.browse (root.items[0].id, null, null);
        assert (lib.items.size == 3);
        var albums = yield src.browse (lib.items[0].id, null, null);
        assert (albums.items.size == 60 && albums.total == 61 && albums.next_token == "60");
        assert (albums.items[0].kind == ItemKind.ALBUM && albums.items[0].image_url.contains ("/Items/al0/Images/Primary") && albums.items[0].subtitle == "Band, 2020");
        var rest = yield src.browse (lib.items[0].id, albums.next_token, null);
        assert (rest.items.size == 1 && rest.next_token == null);
        var tracks = yield src.browse (albums.items[1].id, null, null);
        assert (tracks.items.size == 1 && tracks.title == "Glass Harbor");
        var t = tracks.items[0];
        assert (t.playable && t.duration_ms == 200000 && t.artist == "Northfield Quartet" && t.image_url.contains ("/Items/al1/"));
        var pb = yield src.resolve (t, null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri.has_prefix (m.base_url + "/Audio/t1/stream?") && pb.uri.contains ("api_key=tok1"));
        var artists = yield src.browse (lib.items[1].id, null, null);
        assert (artists.items.size == 1 && artists.items[0].kind == ItemKind.ARTIST);
        yield src.now_playing (t, null);
        yield src.listened (t, 200000, new DateTime.now_utc (), null);
        assert (m.saw ("POST /Sessions/Playing") && m.saw ("POST /Sessions/Playing/Stopped"));
        var found = yield src.search ("lantern", MediaKind.AUDIO, null, null);
        assert (found.items.size == 1 && found.items[0].title == "Lantern Walk");
    } catch (Error e) {
        error ("jellyfin: %s", e.message);
    }
    var bad = test_link ("acc2", "jellyfin", m.base_url, "alice", "wrong");
    src.links_override.clear ();
    src.links_override.add (bad);
    try {
        yield src.browse (null, null, null);
        assert_not_reached ();
    } catch (MediaError.AUTH_FAILED e) {
    } catch (Error e) {
        error ("jellyfin bad password: %s", e.message);
    }
    host.host_kinds = MediaKind.VIDEO;
    src.links_override.clear ();
    src.links_override.add (l);
    try {
        var vroot = yield src.browse (null, null, null);
        assert (vroot.items.size == 2 && vroot.items[0].title == "Movies");
    } catch (Error e) {
        error ("jellyfin video: %s", e.message);
    }
    m.stop ();
}

void test_jellyfin () {
    var loop = new MainLoop ();
    jellyfin_case.begin ((o, r) => {
        jellyfin_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

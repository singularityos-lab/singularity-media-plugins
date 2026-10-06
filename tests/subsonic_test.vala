using Singularity.MediaSources;
using Singularity.MediaPlugins;

bool subsonic_auth (HashTable<string, string>? q) {
    if (q == null) return false;
    string salt = q.lookup ("s") ?? "";
    return q.lookup ("u") == "alice" && q.lookup ("t") == Checksum.compute_for_string (ChecksumType.MD5, "pw" + salt) && q.lookup ("f") == "json";
}

void subsonic_reply (Soup.ServerMessage msg, HashTable<string, string>? q, string body) {
    if (!subsonic_auth (q)) {
        MockServer.json (msg, """{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}""");
        return;
    }
    MockServer.json (msg, """{"subsonic-response":{"status":"ok","version":"1.16.1",%s}}""".printf (body));
}

async void subsonic_case () {
    var m = new MockServer ();
    m.route ("/rest/getAlbumList2", (msg, path, q, b) => {
        int off = int.parse (q.lookup ("offset") ?? "0");
        var sb = new StringBuilder ();
        int n = off == 0 ? 60 : 3;
        for (int i = 0; i < n; i++) {
            if (i > 0) sb.append (",");
            sb.append ("""{"id":"al%d","name":"Album %d","artist":"Band","year":2019,"coverArt":"al-%d"}""".printf (off + i, off + i, off + i));
        }
        subsonic_reply (msg, q, """"albumList2":{"album":[%s]}""".printf (sb.str));
    });
    m.route ("/rest/getAlbum", (msg, path, q, b) => {
        subsonic_reply (msg, q, """"album":{"id":"al1","name":"Glass Harbor","song":[{"id":"s1","title":"Low Tide","artist":"Northfield Quartet","album":"Glass Harbor","track":1,"duration":200,"coverArt":"al-1"},{"id":"s2","title":"Lantern Walk","artist":"Northfield Quartet","album":"Glass Harbor","track":2,"duration":210}]}""");
    });
    m.route ("/rest/getArtists", (msg, path, q, b) => {
        subsonic_reply (msg, q, """"artists":{"index":[{"name":"N","artist":[{"id":"ar1","name":"Northfield Quartet","albumCount":2}]},{"name":"T","artist":[{"id":"ar2","name":"The Lattice","albumCount":1}]}]}""");
    });
    m.route ("/rest/search3", (msg, path, q, b) => {
        subsonic_reply (msg, q, """"searchResult3":{"artist":[{"id":"ar1","name":"Northfield Quartet"}],"song":[{"id":"s2","title":"Lantern Walk","artist":"Northfield Quartet","duration":210}]}""");
    });
    m.route ("/rest/getPlaylists", (msg, path, q, b) => {
        subsonic_reply (msg, q, """"playlists":{"playlist":[{"id":"p1","name":"Morning","songCount":12}]}""");
    });
    m.route ("/rest/scrobble", (msg, path, q, b) => subsonic_reply (msg, q, """"x":1"""));
    var host = new TestHost ();
    var src = new SubsonicSource ();
    src.activate (host);
    src.links_override = new Gee.ArrayList<AccountLink> ();
    src.links_override.add (test_link ("nd", "subsonic", m.base_url, "alice", "pw"));
    try {
        var root = yield src.browse (null, null, null);
        assert (root.items.size == 5);
        var albums = yield src.browse (root.items[0].id, null, null);
        assert (albums.items.size == 60 && albums.next_token == "60");
        assert (albums.items[1].image_url.contains ("/rest/getCoverArt?") && albums.items[1].subtitle == "Band, 2019");
        var more = yield src.browse (root.items[0].id, albums.next_token, null);
        assert (more.items.size == 3 && more.next_token == null);
        var songs = yield src.browse (albums.items[1].id, null, null);
        assert (songs.items.size == 2 && songs.title == "Glass Harbor" && songs.items[0].duration_ms == 200000);
        var pb = yield src.resolve (songs.items[0], null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri.has_prefix (m.base_url + "/rest/stream?") && pb.uri.contains ("id=s1"));
        var artists = yield src.browse (root.items[1].id, null, null);
        assert (artists.items.size == 2 && artists.items[1].title == "The Lattice");
        var pls = yield src.browse (root.items[2].id, null, null);
        assert (pls.items.size == 1 && pls.items[0].kind == ItemKind.PLAYLIST);
        var found = yield src.search ("lantern", MediaKind.AUDIO, null, null);
        assert (found.items.size == 2 && found.items[1].title == "Lantern Walk");
        yield src.listened (songs.items[0], 200000, new DateTime.now_utc (), null);
        assert (m.saw ("GET /rest/scrobble"));
    } catch (Error e) {
        error ("subsonic: %s", e.message);
    }
    src.links_override.clear ();
    src.links_override.add (test_link ("nd2", "subsonic", m.base_url, "alice", "bad"));
    try {
        var root = yield src.browse (null, null, null);
        yield src.browse (root.items[0].id, null, null);
        assert_not_reached ();
    } catch (MediaError.AUTH_FAILED e) {
    } catch (Error e) {
        error ("subsonic bad: %s", e.message);
    }
    m.stop ();
}

void test_subsonic () {
    var loop = new MainLoop ();
    subsonic_case.begin ((o, r) => {
        subsonic_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

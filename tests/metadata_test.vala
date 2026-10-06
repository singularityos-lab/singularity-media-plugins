using Singularity.MediaSources;
using Singularity.MediaPlugins;

MediaItem sample_track () {
    var it = new MediaItem ("local", "track:/m/low.ogg", ItemKind.TRACK, "Low Tide");
    it.artist = "Northfield Quartet";
    it.album = "Glass Harbor";
    it.duration_ms = 200000;
    it.track_number = 1;
    return it;
}

async void listenbrainz_case () {
    var m = new MockServer ();
    var bodies = new Gee.ArrayList<string> ();
    bool fail = false;
    m.route ("/1/submit-listens", (msg, path, q, body) => {
        if (msg.get_request_headers ().get_one ("Authorization") != "Token tok") {
            MockServer.json (msg, """{"code":401,"error":"Invalid token"}""", 401);
            return;
        }
        if (fail) {
            MockServer.json (msg, """{"error":"down"}""", 503);
            return;
        }
        bodies.add (body);
        MockServer.json (msg, """{"status":"ok"}""");
    });
    var host = new TestHost ();
    var lb = new ListenBrainzSource ();
    lb.activate (host);
    lb.links_override = new Gee.ArrayList<AccountLink> ();
    assert (!lb.enabled);
    var l = test_link ("lb1", "listenbrainz", m.base_url, "alice", "tok");
    lb.links_override.add (l);
    assert (lb.enabled);
    var t = sample_track ();
    var started = new DateTime.from_unix_utc (1700000000);
    try {
        yield lb.now_playing (t, null);
        assert (bodies.size == 1 && bodies[0].contains ("\"listen_type\":\"playing_now\"") && bodies[0].contains ("\"track_name\":\"Low Tide\"") && !bodies[0].contains ("listened_at"));
        yield lb.listened (t, 120000, started, null);
        assert (bodies.size == 2 && bodies[1].contains ("\"listen_type\":\"single\"") && bodies[1].contains ("\"listened_at\":1700000000") && bodies[1].contains ("\"duration_ms\":200000"));
    } catch (Error e) {
        error ("listenbrainz: %s", e.message);
    }
    fail = true;
    try {
        yield lb.listened (t, 120000, started, null);
        assert_not_reached ();
    } catch (Error e) {
    }
    try {
        yield lb.listened (t, 120000, new DateTime.from_unix_utc (1700000300), null);
    } catch (Error e) {
    }
    assert (lb.pending (l) == 2);
    fail = false;
    try {
        yield lb.listened (t, 120000, new DateTime.from_unix_utc (1700000600), null);
    } catch (Error e) {
        error ("listenbrainz retry: %s", e.message);
    }
    assert (lb.pending (l) == 0);
    assert (bodies[bodies.size - 1].contains ("\"listen_type\":\"import\"") && bodies[bodies.size - 1].contains ("1700000300"));
    lb.links_override.clear ();
    lb.links_override.add (test_link ("lb2", "listenbrainz", m.base_url, "alice", "bad"));
    try {
        yield lb.now_playing (t, null);
        assert_not_reached ();
    } catch (MediaError.AUTH_FAILED e) {
    } catch (Error e) {
        error ("listenbrainz bad token: %s", e.message);
    }
    m.stop ();
}

async void lrclib_case () {
    var m = new MockServer ();
    int gets = 0;
    m.route ("/api/get", (msg, path, q, body) => {
        gets++;
        if (q.lookup ("track_name") == "Low Tide" && q.lookup ("duration") == "200") {
            MockServer.json (msg, """{"id":1,"trackName":"Low Tide","artistName":"Northfield Quartet","duration":200,"instrumental":false,"plainLyrics":"One\nTwo","syncedLyrics":"[00:01.00] One\n[00:05.50] Two"}""");
        } else {
            MockServer.json (msg, """{"code":404,"name":"TrackNotFound"}""", 404);
        }
    });
    m.route ("/api/search", (msg, path, q, body) => {
        MockServer.json (msg, """[{"id":7,"trackName":"Kitebound","duration":999,"syncedLyrics":"[00:00.00]Wrong"},{"id":8,"trackName":"Kitebound","duration":34,"plainLyrics":"Only plain"}]""");
    });
    var host = new TestHost ();
    var src = new LrclibSource ();
    src.base_url = m.base_url;
    src.activate (host);
    try {
        var l = yield src.lyrics (sample_track (), null);
        assert (l != null && l.synced && l.lines.size == 2 && l.lines[1].time_ms == 5500 && l.attribution == "LRCLIB");
        var again = yield src.lyrics (sample_track (), null);
        assert (again != null && again.synced && gets == 1);
        var kite = new MediaItem ("local", "k", ItemKind.TRACK, "Kitebound");
        kite.artist = "Mira Okafor";
        kite.duration_ms = 34000;
        var p = yield src.lyrics (kite, null);
        assert (p != null && !p.synced && p.plain == "Only plain");
        var none = new MediaItem ("local", "n", ItemKind.TRACK, "");
        assert ((yield src.lyrics (none, null)) == null);
    } catch (Error e) {
        error ("lrclib: %s", e.message);
    }
    m.stop ();
}

async void musicbrainz_case () {
    var m = new MockServer ();
    var times = new Gee.ArrayList<int64?> ();
    m.route ("/ws/2/recording/", (msg, path, q, body) => {
        times.add (get_monotonic_time ());
        assert (msg.get_request_headers ().get_one ("User-Agent").has_prefix ("Singularity-Music-Test"));
        assert (q.lookup ("query").contains ("recording:\"Low Tide\""));
        MockServer.json (msg, """{"recordings":[{"id":"rec-1","score":100,"title":"Low Tide","artist-credit":[{"name":"Northfield Quartet"}],"releases":[{"id":"rel-x","title":"Other"},{"id":"rel-1","title":"Glass Harbor","date":"2021-05-01"}]}]}""");
    });
    var host = new TestHost ();
    var src = new MusicBrainzSource ();
    src.base_url = m.base_url;
    src.covers_url = m.base_url + "/caa";
    src.min_interval_us = 300000;
    src.activate (host);
    try {
        var t = sample_track ();
        var e = yield src.enrich (t, null);
        assert (e != null && e.get_extra ("musicbrainz-release") == "rel-1" && e.year == 2021 && e.image_url == m.base_url + "/caa/release/rel-1/front-500");
        var t2 = sample_track ();
        t2.album = "";
        t2.title = "Low Tide";
        t2.artist = "Northfield Quartet ";
        yield src.enrich (t2, null);
        assert (times.size == 2 && times[1] - times[0] >= 280000);
        var cached = yield src.enrich (sample_track (), null);
        assert (cached != null && times.size == 2);
    } catch (Error e) {
        error ("musicbrainz: %s", e.message);
    }
    m.stop ();
}

void test_listenbrainz () {
    var loop = new MainLoop ();
    listenbrainz_case.begin ((o, r) => {
        listenbrainz_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

void test_lrclib () {
    var loop = new MainLoop ();
    lrclib_case.begin ((o, r) => {
        lrclib_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

void test_musicbrainz () {
    var loop = new MainLoop ();
    musicbrainz_case.begin ((o, r) => {
        musicbrainz_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

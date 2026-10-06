using Singularity.MediaSources;
using Singularity.MediaPlugins;

delegate void AsyncCase (MainLoop loop);

void run_case (owned AsyncCase body) {
    var loop = new MainLoop ();
    body (loop);
    loop.run ();
}

string yt_video (string id, string title, string channel) {
    return """{"id":"%s","snippet":{"title":"%s","channelTitle":"%s","publishedAt":"2024-03-01T10:00:00Z","thumbnails":{"medium":{"url":"https://i.ytimg.invalid/%s/mq.jpg"}}},"contentDetails":{"duration":"PT1H2M3S"},"status":{"embeddable":true}}""".printf (id, title, channel, id);
}

MockServer youtube_mock (out int searches) {
    var m = new MockServer ();
    int count = 0;
    m.route ("/youtube/v3/search", (msg, path, q, body) => {
        count++;
        if (q.lookup ("key") != "test-key" && msg.get_request_headers ().get_one ("Authorization") != "Bearer yt-token") {
            MockServer.json (msg, """{"error":{"code":400,"errors":[{"reason":"keyInvalid"}]}}""", 400);
            return;
        }
        if (q.lookup ("q") == "quota") {
            MockServer.json (msg, """{"error":{"code":403,"errors":[{"reason":"quotaExceeded"}]}}""", 403);
            return;
        }
        if (q.lookup ("pageToken") == "P2") {
            MockServer.json (msg, """{"pageInfo":{"totalResults":3},"items":[{"id":{"kind":"youtube#video","videoId":"v3"},"snippet":{"title":"Third","channelTitle":"Chan"}}]}""");
            return;
        }
        MockServer.json (msg, """{"nextPageToken":"P2","pageInfo":{"totalResults":3},"items":[{"id":{"kind":"youtube#video","videoId":"v1"},"snippet":{"title":"Rock &amp; Roll &quot;Live&quot;","channelTitle":"Chan","thumbnails":{"high":{"url":"https://i.ytimg.invalid/v1/hq.jpg"}}}},{"id":{"kind":"youtube#video","videoId":"v2"},"snippet":{"title":"Second","channelTitle":"Chan"}}]}""");
    });
    m.route ("/youtube/v3/videos", (msg, path, q, body) => {
        if (q.lookup ("myRating") == "like") {
            if (msg.get_request_headers ().get_one ("Authorization") != "Bearer yt-token") {
                msg.set_status (401, null);
                return;
            }
            MockServer.json (msg, """{"pageInfo":{"totalResults":1},"items":[%s]}""".printf (yt_video ("lk1", "Liked One", "Chan")));
            return;
        }
        var sb = new StringBuilder ("""{"items":[""");
        bool first = true;
        foreach (var id in q.lookup ("id").split (",")) {
            if (!first) sb.append (",");
            first = false;
            sb.append ("""{"id":"%s","contentDetails":{"duration":"PT4M5S"},"status":{"embeddable":%s}}""".printf (id, id == "v2" ? "false" : "true"));
        }
        sb.append ("]}");
        MockServer.json (msg, sb.str);
    });
    m.route ("/youtube/v3/subscriptions", (msg, path, q, body) => {
        assert (q.lookup ("mine") == "true");
        MockServer.json (msg, """{"pageInfo":{"totalResults":1},"items":[{"snippet":{"title":"Blender","resourceId":{"kind":"youtube#channel","channelId":"UCblender"},"thumbnails":{"default":{"url":"https://i.ytimg.invalid/c.jpg"}}}}]}""");
    });
    m.route ("/youtube/v3/playlists", (msg, path, q, body) => {
        MockServer.json (msg, """{"pageInfo":{"totalResults":1},"items":[{"id":"PLmine","snippet":{"title":"Watch Later Mix"},"contentDetails":{"itemCount":2}}]}""");
    });
    m.route ("/youtube/v3/channels", (msg, path, q, body) => {
        assert (q.lookup ("id") == "UCblender");
        MockServer.json (msg, """{"items":[{"id":"UCblender","contentDetails":{"relatedPlaylists":{"uploads":"UUblender"}}}]}""");
    });
    m.route ("/youtube/v3/playlistItems", (msg, path, q, body) => {
        string pl = q.lookup ("playlistId");
        if (pl == "UUblender") {
            MockServer.json (msg, """{"pageInfo":{"totalResults":2},"items":[{"snippet":{"title":"Big Buck Bunny","videoOwnerChannelTitle":"Blender"},"contentDetails":{"videoId":"bbb"}},{"snippet":{"title":"Private video"},"contentDetails":{"videoId":"hidden"}}]}""");
            return;
        }
        MockServer.json (msg, """{"pageInfo":{"totalResults":1},"items":[{"snippet":{"title":"Mix Song","videoOwnerChannelTitle":"Band"},"contentDetails":{"videoId":"mx1"}}]}""");
    });
    searches = 0;
    return m;
}

async void youtube_case () {
    int unused;
    var m = youtube_mock (out unused);
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    host.set_value ("youtube", "api-base", m.base_url + "/youtube/v3/");
    var src = new YouTubeSource ();
    src.links_override = new Gee.ArrayList<AccountLink> ();
    src.config_paths_override = {};
    src.activate (host);
    try {
        assert (!src.available);
        var none = yield src.browse (null, null, null);
        assert (none.items.size == 0 && none.action_uri == "settings:accounts");

        string cfg = Path.build_filename (host.dir, "oauth-clients.json");
        FileUtils.set_contents (cfg, """{"google":{"client_id":"x"},"youtube":{"api_key":"test-key"}}""");
        src.config_paths_override = { cfg };
        assert (src.api_key () == "test-key" && src.available);
        host.set_value ("youtube", "api-key", "  user-key ");
        assert (src.api_key () == "user-key");
        host.set_value ("youtube", "api-key", null);

        var keyroot = yield src.browse (null, null, null);
        assert (keyroot.items.size == 0 && keyroot.notice != "");

        var res = yield src.search ("rock", MediaKind.VIDEO, null, null);
        assert (res.items.size == 2 && res.next_token == "P2" && res.total == 3);
        assert (res.items[0].title == "Rock & Roll \"Live\"");
        assert (res.items[0].duration_ms == 245000 && res.items[0].image_url == "https://i.ytimg.invalid/v1/hq.jpg");
        assert (res.items[0].external_url == "https://www.youtube.com/watch?v=v1");
        assert (res.items[1].get_extra ("embeddable") == "false");
        assert (src.units_used () == 101);
        int before = m.log.size;
        var again = yield src.search ("rock", MediaKind.VIDEO, null, null);
        assert (again.items.size == 2 && m.log.size == before && src.units_used () == 101);
        var more = yield src.search ("rock", MediaKind.VIDEO, "P2", null);
        assert (more.items.size == 1 && more.next_token == null);

        var ext = yield src.resolve (res.items[1], null);
        assert (ext.kind == PlaybackKind.EXTERNAL && ext.uri == "https://www.youtube.com/watch?v=v2");
        var pb = yield src.resolve (res.items[0], null);
#if HAVE_WEBKIT
        assert (pb.kind == PlaybackKind.EMBED && pb.embed != null && pb.get_header ("Referer") == "https://videos.sinty.dev/");
        string page = src.player_page ("v1", 75000);
        assert (page.contains ("videoId: \"v1\"") && page.contains ("start: 75") && page.contains ("origin: \"https://videos.sinty.dev\""));
        assert (page.contains ("https://www.youtube.com/iframe_api"));
        assert (WebPlayer.js_string ("a\"</script>") == "\"a\\\"\\u003c/script\\u003e\"");
#else
        assert (pb.kind == PlaybackKind.EXTERNAL);
#endif
        try {
            yield src.search ("quota", MediaKind.VIDEO, null, null);
            assert_not_reached ();
        } catch (MediaError.RATE_LIMITED e) {
        }

        var link = test_link ("g1", "google", "https://accounts.google.com", "alice@example.invalid", "yt-token");
        link.mechanism = "oauth2";
        src.links_override.add (link);
        var root = yield src.browse (null, null, null);
        assert (root.items.size == 3 && root.items[0].title == "Subscriptions" && root.items[2].title == "Liked Videos");
        var subs = yield src.browse (root.items[0].id, null, null);
        assert (subs.items.size == 1 && subs.items[0].kind == ItemKind.CHANNEL && subs.items[0].title == "Blender");
        var chan = yield src.browse (subs.items[0].id, null, null);
        assert (chan.items.size == 1 && chan.items[0].title == "Big Buck Bunny" && chan.title == "Blender");
        assert (host.get_value ("youtube", "uploads-UCblender") == "UUblender");
        var lists = yield src.browse (root.items[1].id, null, null);
        assert (lists.items.size == 1 && lists.items[0].kind == ItemKind.PLAYLIST && lists.items[0].subtitle == "2 videos");
        var mix = yield src.browse (lists.items[0].id, null, null);
        assert (mix.items.size == 1 && mix.items[0].subtitle == "Band");
        var liked = yield src.browse (root.items[2].id, null, null);
        assert (liked.items.size == 1 && liked.items[0].duration_ms == 3723000 && liked.items[0].year == 2024);
        assert (m.saw ("GET /youtube/v3/videos?maxResults=25&myRating=like"));
        assert (!m.log[m.log.size - 1].contains ("key="));
    } catch (Error e) {
        error ("youtube: %s", e.message);
    }
    assert (YouTubeSource.parse_duration ("PT45S") == 45000 && YouTubeSource.parse_duration ("P1DT1M") == 86460000);
    m.stop ();
}

MockServer peertube_mock () {
    var m = new MockServer ();
    m.route ("/api/v1/videos", (msg, path, q, body) => {
        int start = int.parse (q.lookup ("start") ?? "0");
        if (q.lookup ("sort") == "-trending" && start == 0) {
            MockServer.json (msg, """{"total":3,"data":[{"uuid":"u1","name":"Free Software Talk","duration":125,"thumbnailPath":"/static/thumbnails/u1.jpg","publishedAt":"2023-05-01T00:00:00Z","channel":{"displayName":"Talks","name":"talks","host":"127.0.0.1"},"account":{"host":"127.0.0.1"}},{"uuid":"u2","name":"Remote","duration":60,"url":"https://other.example.invalid/w/u2","thumbnailPath":"/x.jpg","channel":{"displayName":"Elsewhere"},"account":{"host":"other.example.invalid"}}]}""");
            return;
        }
        MockServer.json (msg, """{"total":3,"data":[{"uuid":"u3","name":"Last","duration":10,"channel":{"displayName":"Talks"}}]}""");
    });
    m.route ("/api/v1/search/videos", (msg, path, q, body) => {
        assert (q.lookup ("search") == "linux");
        MockServer.json (msg, """{"total":1,"data":[{"uuid":"s1","name":"Linux Basics","duration":300,"url":"%s/w/s1","thumbnailUrl":"https://cdn.invalid/s1.jpg","channel":{"displayName":"Edu"},"account":{"host":"127.0.0.1"}}]}""".printf (m.base_url));
    });
    m.route ("/api/v1/videos/u1", (msg, path, q, body) => {
        MockServer.json (msg, """{"uuid":"u1","files":[{"resolution":{"id":2160},"fileUrl":"%s/static/u1-2160.mp4"},{"resolution":{"id":720},"fileUrl":"%s/static/u1-720.mp4"},{"resolution":{"id":360},"fileUrl":"%s/static/u1-360.mp4"}],"streamingPlaylists":[]}""".printf (m.base_url, m.base_url, m.base_url));
    });
    m.route ("/api/v1/videos/s1", (msg, path, q, body) => {
        MockServer.json (msg, """{"uuid":"s1","files":[],"streamingPlaylists":[{"playlistUrl":"%s/static/streaming-playlists/hls/s1/master.m3u8"}]}""".printf (m.base_url));
    });
    m.route ("/api/v1/video-channels/talks@127.0.0.1/videos", (msg, path, q, body) => {
        MockServer.json (msg, """{"total":1,"data":[{"uuid":"c1","name":"Channel Clip","duration":42,"channel":{"displayName":"Talks"}}]}""");
    });
    return m;
}

async void peertube_case () {
    var m = peertube_mock ();
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    var src = new PeerTubeSource ();
    src.activate (host);
    host.set_value ("peertube", "instances", m.base_url + "/, " + m.base_url);
    host.set_value ("peertube", "search-index", "");
    try {
        assert (src.instances ().size == 1);
        var root = yield src.browse (null, null, null);
        assert (root.items.size == 3 && root.items[0].title == "Trending");
        var trending = yield src.browse (root.items[0].id, null, null);
        assert (trending.items.size == 2 && trending.total == 3 && trending.next_token == "2");
        var v = trending.items[0];
        assert (v.duration_ms == 125000 && v.image_url == m.base_url + "/static/thumbnails/u1.jpg" && v.subtitle == "Talks" && v.year == 2023);
        assert (v.get_extra ("channel") == "talks@127.0.0.1");
        assert (trending.items[1].attribution == "other.example.invalid");
        var rest = yield src.browse (root.items[0].id, trending.next_token, null);
        assert (rest.items.size == 1 && rest.next_token == null);
        var pb = yield src.resolve (v, null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri == m.base_url + "/static/u1-720.mp4");
        var found = yield src.search ("linux", MediaKind.VIDEO, null, null);
        assert (found.items.size == 1 && found.items[0].image_url == "https://cdn.invalid/s1.jpg");
        var hls = yield src.resolve (found.items[0], null);
        assert (hls.kind == PlaybackKind.STREAM && hls.uri.has_suffix ("master.m3u8"));
        var chan = yield src.browse (AccountLinks.node (Uri.escape_string (m.base_url, null, false), "channel", "talks@127.0.0.1"), null, null);
        assert (chan.items.size == 1 && chan.title == "Talks");
        host.set_value ("peertube", "instances", m.base_url + ",https://two.example.invalid");
        var two = yield src.browse (null, null, null);
        assert (two.items.size == 2 && two.items[1].title == "two.example.invalid");
    } catch (Error e) {
        error ("peertube: %s", e.message);
    }
    m.stop ();
}

async void nextcloud_case () {
    var m = new MockServer ();
    m.route ("/remote.php/dav/files/alice/Videos/", (msg, path, q, body) => {
        assert (msg.get_method () == "PROPFIND" && msg.get_request_headers ().get_one ("Authorization") != null);
        string xml = """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
<d:response><d:href>/remote.php/dav/files/alice/Videos/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/files/alice/Videos/Holidays/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/files/alice/Videos/Beach%20Day.mp4</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontenttype>video/mp4</d:getcontenttype></d:prop></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/files/alice/Videos/notes.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontenttype>text/plain</d:getcontenttype></d:prop></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/files/alice/Videos/clip.MKV</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
</d:multistatus>""";
        msg.set_status (207, null);
        msg.set_response ("application/xml", Soup.MemoryUse.COPY, xml.data);
    });
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    var src = new NextcloudVideosSource ();
    src.activate (host);
    src.links_override = new Gee.ArrayList<AccountLink> ();
    try {
        var empty = yield src.browse (null, null, null);
        assert (empty.items.size == 0 && empty.action_uri == "settings:accounts");
        src.links_override.add (test_link ("nc1", "nextcloud", m.base_url, "alice", "pw"));
        var root = yield src.browse (null, null, null);
        assert (root.items.size == 3);
        assert (root.items[0].kind == ItemKind.FOLDER && root.items[0].title == "Holidays");
        assert (root.items[1].kind == ItemKind.VIDEO && root.items[1].title == "Beach Day");
        assert (root.items[2].title == "clip");
        var pb = yield src.resolve (root.items[1], null);
        assert (pb.uri == m.base_url + "/remote.php/dav/files/alice/Videos/Beach%20Day.mp4" && pb.get_header ("Authorization").has_prefix ("Basic "));
    } catch (Error e) {
        error ("nextcloud videos: %s", e.message);
    }
    m.stop ();
}

async void jellyfin_video_case () {
    var m = new MockServer ();
    m.route ("/Users/AuthenticateByName", (msg, path, q, body) => MockServer.json (msg, """{"AccessToken":"tok","User":{"Id":"u1"}}"""));
    m.route ("/Users/u1/Views", (msg, path, q, body) => {
        MockServer.json (msg, """{"Items":[{"Id":"lib-music","Name":"Music","CollectionType":"music"},{"Id":"lib-movies","Name":"Movies","CollectionType":"movies"}],"TotalRecordCount":2}""");
    });
    m.route ("/Users/u1/Items", (msg, path, q, body) => {
        assert (q.lookup ("ParentId") == "lib-movies");
        MockServer.json (msg, """{"Items":[{"Id":"mv1","Name":"Sintel","Type":"Movie","ProductionYear":2010,"RunTimeTicks":8880000000,"ImageTags":{"Primary":"p"}}],"TotalRecordCount":1}""");
    });
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    var src = new JellyfinSource ();
    src.activate (host);
    src.links_override = new Gee.ArrayList<AccountLink> ();
    src.links_override.add (test_link ("jf1", "jellyfin", m.base_url, "alice", "secret"));
    try {
        var root = yield src.browse (null, null, null);
        assert (root.items.size >= 1 && root.items[0].title == "Movies");
        foreach (var it in root.items) assert (it.title != "Music");
        var lib = yield src.browse (root.items[0].id, null, null);
        assert (lib.items.size == 1 && lib.items[0].kind == ItemKind.VIDEO && lib.items[0].duration_ms == 888000);
        var pb = yield src.resolve (lib.items[0], null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri.has_prefix (m.base_url + "/Videos/mv1/stream?") && pb.uri.contains ("api_key=tok"));
    } catch (Error e) {
        error ("jellyfin video: %s", e.message);
    }
    m.stop ();
}

const string DLNA_DESC = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><friendlyName>Test Media Box</friendlyName><UDN>uuid:box-1</UDN>
<serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/cd</controlURL></service></serviceList></device></root>""";

string dlna_reply (string action, string didl, int n) {
    return "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:%sResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result>%s</Result><NumberReturned>%d</NumberReturned><TotalMatches>%d</TotalMatches><UpdateID>1</UpdateID></u:%sResponse></s:Body></s:Envelope>".printf (
        action, Markup.escape_text (didl), n, n, action);
}

async void dlna_video_case () {
    var m = new MockServer ();
    m.route ("/desc.xml", (msg, path, q, body) => MockServer.text (msg, "text/xml", DLNA_DESC));
    m.route ("/cd", (msg, path, q, body) => {
        string head = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">";
        string items = "<item id=\"a\" parentID=\"0\"><dc:title>Song</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><res>%s/a.ogg</res></item>".printf (m.base_url)
            + "<item id=\"v\" parentID=\"0\"><dc:title>Home Movie</dc:title><upnp:class>object.item.videoItem.movie</upnp:class><res duration=\"0:01:30.000\" protocolInfo=\"http-get:*:video/mp4:*\">%s/v.mp4</res></item>".printf (m.base_url);
        MockServer.text (msg, "text/xml", dlna_reply ("Browse", head + items + "</DIDL-Lite>", 2));
    });
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    var src = new DlnaSource ();
    src.use_multicast = false;
    src.extra_locations = { m.base_url + "/desc.xml" };
    src.activate (host);
    try {
        yield src.discover ();
        var root = yield src.browse (null, null, null);
        MediaItem? movie = null;
        foreach (var it in root.items) {
            assert (it.kind != ItemKind.TRACK);
            if (it.kind == ItemKind.VIDEO) movie = it;
        }
        assert (movie != null && movie.title == "Home Movie" && movie.duration_ms == 90000);
        var pb = yield src.resolve (movie, null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri == m.base_url + "/v.mp4");
    } catch (Error e) {
        error ("dlna video: %s", e.message);
    }
    m.stop ();
}

string fixture (string name, MockServer? m = null) {
    string dir = Environment.get_variable ("VIDEOS_FIXTURES") ?? "fixtures";
    string text;
    try {
        FileUtils.get_contents (Path.build_filename (dir, name), out text);
    } catch (FileError e) {
        error ("fixture %s: %s", name, e.message);
    }
    if (m != null) {
        foreach (unowned string h in new string[] { "https://spectra-prod.us-east-1.linodeobjects.com", "https://spectra.video", "https://framatube.org", "https://tube.tchncs.de", "https://peertube.opencloud.lu", "https://i.ytimg.com" })
            text = text.replace (h, m.base_url);
    }
    return text;
}

async void youtube_real_case () {
    var m = new MockServer ();
    string last_query = "";
    m.route ("/youtube/v3/search", (msg, path, q, body) => {
        last_query = Web.query (q);
        string key = q.lookup ("key") ?? "";
        if (key == "" && msg.get_request_headers ().get_one ("Authorization") == null) { MockServer.json (msg, fixture ("youtube-nokey.json"), 403); return; }
        if (key == "bad") { MockServer.json (msg, fixture ("youtube-badkey.json"), 400); return; }
        if (key == "quota") { MockServer.json (msg, fixture ("youtube-quota.json"), 403); return; }
        if (key == "off") { MockServer.json (msg, fixture ("youtube-disabled.json"), 403); return; }
        string? auth = msg.get_request_headers ().get_one ("Authorization");
        if (auth != null && auth != "Bearer good") { MockServer.json (msg, fixture ("youtube-badtoken.json"), 401); return; }
        MockServer.json (msg, fixture ("youtube-search.json", m));
    });
    m.route ("/youtube/v3/videos", (msg, path, q, body) => {
        assert (q.lookup ("maxResults") == null);
        if (msg.get_request_headers ().get_one ("Authorization") == "Bearer narrow") { MockServer.json (msg, fixture ("youtube-scope.json"), 403); return; }
        MockServer.json (msg, fixture ("youtube-videos.json", m));
    });
    m.route ("/oembed", (msg, path, q, body) => {
        assert (q.lookup ("format") == "json" && q.lookup ("url").has_prefix ("https://www.youtube.com/watch?v="));
        MockServer.json (msg, fixture ("youtube-oembed.json", m));
    });
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    host.set_value ("youtube", "api-base", m.base_url + "/youtube/v3");
    host.set_value ("youtube", "oembed-base", m.base_url + "/oembed");
    var src = new YouTubeSource ();
    src.links_override = new Gee.ArrayList<AccountLink> ();
    src.config_paths_override = {};
    src.activate (host);
    try {
        host.set_value ("youtube", "api-key", "good");
        var res = yield src.search ("big buck bunny", MediaKind.VIDEO, null, null);
        assert (last_query == "key=good&maxResults=25&part=snippet&q=big%20buck%20bunny&safeSearch=moderate&type=video");
        assert (res.items.size == 2 && res.next_token == "CAIQAA");
        assert (res.items[0].title.has_prefix ("Big Buck Bunny") && res.items[0].duration_ms == 635000);
        assert (res.items[0].image_url == m.base_url + "/vi/aqz-KE-bpKQ/hqdefault.jpg");
        assert (res.items[1].title == "Sintel - Open Movie by Blender Foundation & friends" && res.items[1].get_extra ("embeddable") == "false");
        var page2 = yield src.search ("big buck bunny", MediaKind.VIDEO, "CAIQAA", null);
        assert (last_query.contains ("pageToken=CAIQAA") && page2.items.size == 2);
        foreach (unowned string k in new string[] { "bad", "quota", "off" }) {
            host.set_value ("youtube", "api-key", k);
            try {
                yield src.search ("x " + k, MediaKind.VIDEO, null, null);
                assert_not_reached ();
            } catch (MediaError e) {
                if (k == "bad") assert (e is MediaError.NOT_CONFIGURED && e.message.contains ("not valid"));
                if (k == "quota") assert (e is MediaError.RATE_LIMITED);
                if (k == "off") assert (e is MediaError.NOT_CONFIGURED && e.message.contains ("not enabled"));
            }
        }
        var err = YouTubeSource.parse_error (403, fixture ("youtube-nokey.json"));
        assert (YouTubeSource.error_for (err, false) is MediaError.NOT_CONFIGURED);
        err = YouTubeSource.parse_error (401, fixture ("youtube-badtoken.json"));
        assert (YouTubeSource.error_for (err, true) is MediaError.AUTH_FAILED);
        err = YouTubeSource.parse_error (403, fixture ("youtube-scope.json"));
        assert (YouTubeSource.error_for (err, true) is MediaError.NEEDS_ACCOUNT);

        var bad = test_link ("g1", "google", "https://accounts.google.com", "a@example.invalid", "expired");
        bad.mechanism = "oauth2";
        src.links_override.add (bad);
        host.set_value ("youtube", "api-key", "good");
        var fell = yield src.search ("fallback", MediaKind.VIDEO, null, null);
        assert (fell.items.size == 2 && last_query.contains ("key=good"));
        src.links_override.clear ();

        host.set_value ("youtube", "api-key", null);
        var url = yield src.browse (YouTubeSource.URL_NODE + "https://youtu.be/aqz-KE-bpKQ?t=1m5s", null, null);
        assert (url.items.size == 1 && url.items[0].title.has_prefix ("Big Buck Bunny") && url.items[0].subtitle == "Blender");
        assert (url.items[0].get_extra ("start-ms") == "65000");
        try {
            yield src.browse (YouTubeSource.URL_NODE + "https://example.org/watch?v=aqz-KE-bpKQ", null, null);
            assert_not_reached ();
        } catch (MediaError.NOT_FOUND e) {
        }
        host.set_value ("youtube", "api-key", "good");
        var url2 = yield src.browse (YouTubeSource.URL_NODE + "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=PLx", null, null);
        assert (url2.items[0].duration_ms == 635000);
    } catch (Error e) {
        error ("youtube real: %s", e.message);
    }
    string v, l;
    int64 st;
    assert (YouTubeSource.parse_url ("https://m.youtube.com/shorts/abcDEF12345", out v, out l, out st) && v == "abcDEF12345");
    assert (YouTubeSource.parse_url ("https://www.youtube.com/embed/abcDEF12345?start=30", out v, out l, out st) && st == 30000);
    assert (YouTubeSource.parse_url ("https://www.youtube.com/playlist?list=PLabc", out v, out l, out st) && v == "" && l == "PLabc");
    assert (!YouTubeSource.parse_url ("https://vimeo.com/123", out v, out l, out st));
    m.stop ();
}

async void peertube_real_case () {
    var m = new MockServer ();
    string last = "";
    m.route ("/api/v1/search/videos", (msg, path, q, body) => {
        last = Web.query (q);
        MockServer.json (msg, fixture ("peertube-sepia-search.json", m));
    });
    m.route ("/api/v1/videos", (msg, path, q, body) => {
        last = Web.query (q);
        MockServer.json (msg, fixture ("peertube-videos-trending.json", m));
    });
    m.route ("/api/v1/videos/*", (msg, path, q, body) => {
        if (path.has_suffix ("/missing0")) {
            MockServer.json (msg, """{"type":"about:blank","title":"Not Found","detail":"Video not found","status":404}""", 404);
            return;
        }
        MockServer.json (msg, fixture ("peertube-video.json", m));
    });
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    host.set_value ("peertube", "instances", m.base_url);
    host.set_value ("peertube", "search-index", m.base_url);
    var src = new PeerTubeSource ();
    src.activate (host);
    try {
        var found = yield src.search ("linux", MediaKind.VIDEO, null, null);
        assert (last == "count=24&nsfw=false&search=linux&start=0");
        assert (found.items.size == 2 && found.total == 15247 && found.next_token == "2");
        var it = found.items[0];
        assert (it.title == "A Sample Talk About Linux" && it.duration_ms == 639000);
        assert (it.image_url.has_prefix (m.base_url + "/lazy-static/thumbnails/"));
        var pb = yield src.resolve (it, null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri.has_suffix ("-1080-fragmented.mp4"));
        var root = yield src.browse (null, null, null);
        var trending = yield src.browse (root.items[0].id, null, null);
        assert (last == "count=24&nsfw=false&sort=-trending&start=0");
        assert (trending.items.size == 2 && trending.items[0].image_url.has_prefix (m.base_url + "/lazy-static/"));
        var url = yield src.browse (PeerTubeSource.URL_NODE + m.base_url + "/w/sXGnj113k5GYzdzzYmr4cY", null, null);
        assert (url.items.size == 1 && url.items[0].title.has_prefix ("A Sample Talk"));
        try {
            yield src.browse (PeerTubeSource.URL_NODE + m.base_url + "/w/missing0", null, null);
            assert_not_reached ();
        } catch (MediaError.NOT_FOUND e) {
        }
    } catch (Error e) {
        error ("peertube real: %s", e.message);
    }
    string inst, vid;
    assert (PeerTubeSource.parse_url ("https://framatube.org/videos/watch/3f6a4d43-4f6d-4f98-becd-b5aa629a0fe0", out inst, out vid) && inst == "https://framatube.org");
    assert (!PeerTubeSource.parse_url ("https://framatube.org/w/p/abcdefgh", out inst, out vid));
    assert (!PeerTubeSource.parse_url ("https://example.org/about", out inst, out vid));
    m.stop ();
}

int main (string[] args) {
    Test.init (ref args);
    Environment.set_variable ("XDG_CONFIG_HOME", Path.build_filename (Environment.get_tmp_dir (), "videos-plugins-test-config"), true);
    Test.add_func ("/videos-plugins/youtube", () => run_case ((loop) => youtube_case.begin ((o, r) => { youtube_case.end (r); loop.quit (); })));
    Test.add_func ("/videos-plugins/peertube", () => run_case ((loop) => peertube_case.begin ((o, r) => { peertube_case.end (r); loop.quit (); })));
    Test.add_func ("/videos-plugins/nextcloud", () => run_case ((loop) => nextcloud_case.begin ((o, r) => { nextcloud_case.end (r); loop.quit (); })));
    Test.add_func ("/videos-plugins/jellyfin", () => run_case ((loop) => jellyfin_video_case.begin ((o, r) => { jellyfin_video_case.end (r); loop.quit (); })));
    Test.add_func ("/videos-plugins/youtube-real", () => run_case ((loop) => youtube_real_case.begin ((o, r) => { youtube_real_case.end (r); loop.quit (); })));
    Test.add_func ("/videos-plugins/peertube-real", () => run_case ((loop) => peertube_real_case.begin ((o, r) => { peertube_real_case.end (r); loop.quit (); })));
    Test.add_func ("/videos-plugins/dlna", () => run_case ((loop) => dlna_video_case.begin ((o, r) => { dlna_video_case.end (r); loop.quit (); })));
    return Test.run ();
}

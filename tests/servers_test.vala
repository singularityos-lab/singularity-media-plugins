using Singularity.MediaSources;
using Singularity.MediaPlugins;

string dav_entry (string href, bool dir, string ctype = "") {
    return "<d:response><d:href>%s</d:href><d:propstat><d:prop><d:resourcetype>%s</d:resourcetype>%s</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>".printf (
        href, dir ? "<d:collection/>" : "", ctype != "" ? "<d:getcontenttype>%s</d:getcontenttype>".printf (ctype) : "");
}

async void nextcloud_case () {
    var m = new MockServer ();
    string auth = "Basic " + Base64.encode ("alice:apppw".data);
    m.route ("/remote.php/dav/files/alice/*", (msg, path, q, body) => {
        if (msg.get_request_headers ().get_one ("Authorization") != auth) {
            msg.set_status (401, null);
            return;
        }
        if (msg.get_method () == "GET") {
            MockServer.text (msg, "audio/ogg", "OggS");
            return;
        }
        string xml;
        if (path == "/remote.php/dav/files/alice/Music/") {
            xml = dav_entry ("/remote.php/dav/files/alice/Music/", true)
                + dav_entry ("/remote.php/dav/files/alice/Music/Glass%20Harbor/", true)
                + dav_entry ("/remote.php/dav/files/alice/Music/02%20Lantern%20Walk.mp3", false, "audio/mpeg")
                + dav_entry ("/remote.php/dav/files/alice/Music/notes.txt", false, "text/plain")
                + dav_entry ("/remote.php/dav/files/alice/Music/.hidden", true);
        } else if (path == "/remote.php/dav/files/alice/Music/Glass%20Harbor/" || path == "/remote.php/dav/files/alice/Music/Glass Harbor/") {
            xml = dav_entry ("/remote.php/dav/files/alice/Music/Glass%20Harbor/", true)
                + dav_entry ("/remote.php/dav/files/alice/Music/Glass%20Harbor/01%20Low%20Tide.ogg", false, "application/octet-stream")
                + dav_entry ("/remote.php/dav/files/alice/Music/Glass%20Harbor/cover.jpg", false, "image/jpeg");
        } else {
            msg.set_status (404, null);
            return;
        }
        msg.set_status (207, null);
        msg.set_response ("application/xml", Soup.MemoryUse.COPY, ("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">" + xml + "</d:multistatus>").data);
    });
    var host = new TestHost ();
    var src = new NextcloudMusicSource ();
    src.activate (host);
    src.links_override = new Gee.ArrayList<AccountLink> ();
    var l = test_link ("nc", "nextcloud", m.base_url, "alice", "apppw");
    l.set_endpoint ("webdav", m.base_url + "/remote.php/dav/files/alice/");
    src.links_override.add (l);
    try {
        var root = yield src.browse (null, null, null);
        assert (root.title == "Music");
        assert (root.items.size == 2);
        assert (root.items[0].kind == ItemKind.FOLDER && root.items[0].title == "Glass Harbor");
        assert (root.items[1].kind == ItemKind.TRACK && root.items[1].title == "Lantern Walk");
        var album = yield src.browse (root.items[0].id, null, null);
        assert (album.items.size == 1 && album.items[0].title == "Low Tide" && album.title == "Glass Harbor");
        var pb = yield src.resolve (album.items[0], null);
        assert (pb.kind == PlaybackKind.STREAM && pb.uri == m.base_url + "/remote.php/dav/files/alice/Music/Glass%20Harbor/01%20Low%20Tide.ogg");
        assert (pb.get_header ("Authorization") == auth);
        var found = yield src.search ("tide", MediaKind.AUDIO, null, null);
        assert (found.items.size == 1 && found.items[0].title == "Low Tide");
        host.set_value (NextcloudMusicSource.ID, "folder-nc", "Missing");
        try {
            yield src.browse (null, null, null);
            assert_not_reached ();
        } catch (MediaError.NOT_FOUND e) {
        }
    } catch (Error e) {
        error ("nextcloud: %s", e.message);
    }
    m.stop ();
}

const string DESCRIPTION = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Living Room NAS</friendlyName>
    <UDN>uuid:nas-1</UDN>
    <iconList><icon><mimetype>image/png</mimetype><url>/icon.png</url></icon></iconList>
    <serviceList>
      <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/cm</controlURL></service>
      <service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/cd/control</controlURL></service>
    </serviceList>
  </device>
</root>""";

string soap_reply (string action, string didl, int returned, int total) {
    return "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:%sResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result>%s</Result><NumberReturned>%d</NumberReturned><TotalMatches>%d</TotalMatches><UpdateID>1</UpdateID></u:%sResponse></s:Body></s:Envelope>".printf (
        action, Markup.escape_text (didl), returned, total, action);
}

async void dlna_case () {
    var m = new MockServer ();
    m.route ("/desc.xml", (msg, path, q, body) => MockServer.text (msg, "text/xml", DESCRIPTION));
    m.route ("/cd/control", (msg, path, q, body) => {
        string action = msg.get_request_headers ().get_one ("SOAPACTION") ?? "";
        string didl_head = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">";
        if (action.contains ("#Search")) {
            assert (body.contains ("dc:title contains &quot;walk&quot;"));
            MockServer.text (msg, "text/xml", soap_reply ("Search", didl_head + "<item id=\"t2\" parentID=\"a1\"><dc:title>Lantern Walk</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo=\"http-get:*:audio/ogg:*\">%s/media/t2.ogg</res></item></DIDL-Lite>".printf (m.base_url), 1, 1));
            return;
        }
        if (body.contains ("<ObjectID>0</ObjectID>")) {
            MockServer.text (msg, "text/xml", soap_reply ("Browse", didl_head + "<container id=\"music\" parentID=\"0\" childCount=\"2\"><dc:title>Music</dc:title><upnp:class>object.container.storageFolder</upnp:class></container><container id=\"video\" parentID=\"0\"><dc:title>Video</dc:title><upnp:class>object.container.storageFolder</upnp:class></container></DIDL-Lite>", 2, 2));
        } else if (body.contains ("<ObjectID>music</ObjectID>")) {
            bool second = body.contains ("<StartingIndex>2</StartingIndex>");
            string items = second
                ? "<item id=\"v1\" parentID=\"music\"><dc:title>Clip</dc:title><upnp:class>object.item.videoItem</upnp:class><res>%s/media/v1.mp4</res></item>".printf (m.base_url)
                : "<container id=\"a1\" parentID=\"music\" childCount=\"4\"><dc:title>Glass Harbor</dc:title><upnp:class>object.container.album.musicAlbum</upnp:class><upnp:albumArtURI>%s/art/a1.jpg</upnp:albumArtURI></container><item id=\"t1\" parentID=\"music\"><dc:title>Low Tide</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><upnp:artist>Northfield Quartet</upnp:artist><upnp:album>Glass Harbor</upnp:album><upnp:originalTrackNumber>1</upnp:originalTrackNumber><res protocolInfo=\"http-get:*:audio/ogg:*\" duration=\"0:03:20.500\">%s/media/t1.ogg</res></item>".printf (m.base_url, m.base_url);
            MockServer.text (msg, "text/xml", soap_reply ("Browse", didl_head + items + "</DIDL-Lite>", second ? 1 : 2, 3));
        } else {
            msg.set_status (500, null);
        }
    });
    assert (Upnp.parse_ssdp ("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://10.0.0.2:8200/rootDesc.xml\r\nST: urn:schemas-upnp-org:service:ContentDirectory:1\r\n\r\n")[0] == "http://10.0.0.2:8200/rootDesc.xml");
    assert (Upnp.parse_duration ("1:02:03.250") == 3723250);
    var host = new TestHost ();
    var src = new DlnaSource ();
    src.use_multicast = false;
    src.extra_locations = { m.base_url + "/desc.xml" };
    src.activate (host);
    try {
        yield src.discover ();
        assert (src.available);
        var root = yield src.browse (null, null, null);
        assert (root.title == "Living Room NAS" && root.items.size == 2);
        var music = yield src.browse (root.items[0].id, null, null);
        assert (music.items.size == 2 && music.total == 3 && music.next_token == "2");
        assert (music.items[0].kind == ItemKind.ALBUM && music.items[0].image_url == m.base_url + "/art/a1.jpg");
        var t = music.items[1];
        assert (t.kind == ItemKind.TRACK && t.artist == "Northfield Quartet" && t.duration_ms == 200500 && t.track_number == 1);
        var more = yield src.browse (root.items[0].id, music.next_token, null);
        assert (more.items.size == 0 && more.next_token == null);
        var pb = yield src.resolve (t, null);
        assert (pb.uri == m.base_url + "/media/t1.ogg");
        var found = yield src.search ("walk", MediaKind.AUDIO, null, null);
        assert (found.items.size == 1 && found.items[0].title == "Lantern Walk");
        host.host_kinds = MediaKind.VIDEO;
        var vids = yield src.browse (root.items[0].id, "2", null);
        assert (vids.items.size == 1 && vids.items[0].kind == ItemKind.VIDEO);
    } catch (Error e) {
        error ("dlna: %s", e.message);
    }
    m.stop ();
}

void test_nextcloud () {
    var loop = new MainLoop ();
    nextcloud_case.begin ((o, r) => {
        nextcloud_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

void test_dlna () {
    var loop = new MainLoop ();
    dlna_case.begin ((o, r) => {
        dlna_case.end (r);
        loop.quit ();
    });
    loop.run ();
}

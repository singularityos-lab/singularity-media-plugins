using Singularity.MediaSources;

public delegate void MockHandler (Soup.ServerMessage msg, string path, HashTable<string, string>? query, string body);

public class MockServer : Object {
    private Soup.Server _server;
    private Gee.HashMap<string, MockHandlerBox> _routes = new Gee.HashMap<string, MockHandlerBox> ();
    public Gee.ArrayList<string> log = new Gee.ArrayList<string> ();
    public string base_url { get; private set; }

    private class MockHandlerBox {
        public MockHandler handler;
        public MockHandlerBox (owned MockHandler h) {
            handler = (owned) h;
        }
    }

    public MockServer () {
        _server = new Soup.Server ("server-header", "mock");
        _server.add_handler (null, (srv, msg, path, query) => {
            string body = "";
            var b = msg.get_request_body ().flatten ();
            if (b != null && b.get_size () > 0) {
                var sb = new StringBuilder.sized (b.get_size () + 1);
                sb.append_len ((string) b.get_data (), (ssize_t) b.get_size ());
                body = sb.str;
            }
            log.add (msg.get_method () + " " + path + (query != null && query.size () > 0 ? "?" + Web.query (query) : ""));
            var route = _routes[msg.get_method () + " " + path] ?? _routes[path];
            if (route == null) {
                foreach (var e in _routes.entries) {
                    if (e.key.has_suffix ("*") && path.has_prefix (e.key.substring (0, e.key.length - 1))) {
                        route = e.value;
                        break;
                    }
                }
            }
            if (route == null) {
                msg.set_status (404, null);
                return;
            }
            route.handler (msg, path, query, body);
        });
        try {
            _server.listen_local (0, Soup.ServerListenOptions.IPV4_ONLY);
        } catch (Error e) {
            error ("mock: %s", e.message);
        }
        uint port = 0;
        foreach (var u in _server.get_uris ()) port = u.get_port ();
        base_url = "http://127.0.0.1:%u".printf (port);
    }

    public void route (string path, owned MockHandler handler) {
        _routes[path] = new MockHandlerBox ((owned) handler);
    }

    public static void json (Soup.ServerMessage msg, string text, uint status = 200) {
        msg.set_status (status, null);
        msg.set_response ("application/json", Soup.MemoryUse.COPY, text.data);
    }

    public static void text (Soup.ServerMessage msg, string type, string text, uint status = 200) {
        msg.set_status (status, null);
        msg.set_response (type, Soup.MemoryUse.COPY, text.data);
    }

    public bool saw (string prefix) {
        foreach (var l in log) if (l.has_prefix (prefix)) return true;
        return false;
    }

    public void stop () {
        _server.disconnect ();
    }
}

public class TestHost : Object, MediaHost {
    public HashTable<string, string> values = new HashTable<string, string> (str_hash, str_equal);
    public Gee.ArrayList<string> messages = new Gee.ArrayList<string> ();
    public Gee.ArrayList<string> opened = new Gee.ArrayList<string> ();
    private Soup.Session _session = new Soup.Session ();
    public MediaKind host_kinds = MediaKind.AUDIO;
    public string dir;

    public TestHost () {
        try {
            dir = DirUtils.make_tmp ("media-plugins-XXXXXX");
        } catch (Error e) {
            dir = Environment.get_tmp_dir ();
        }
    }

    public string app_id { owned get { return "dev.sinty.music"; } }
    public MediaKind kinds { get { return host_kinds; } }
    public string user_agent { owned get { return "Singularity-Music-Test/1"; } }
    public Soup.Session session { get { return _session; } }
    public bool network_available { get { return true; } }
    public bool window_visible { get { return true; } }

    public string cache_dir (string source_id) {
        string d = Path.build_filename (dir, source_id);
        DirUtils.create_with_parents (d, 0700);
        return d;
    }

    public string? get_value (string source_id, string key) {
        return values.lookup (source_id + "/" + key);
    }

    public void set_value (string source_id, string key, string? value) {
        if (value == null) values.remove (source_id + "/" + key);
        else values.insert (source_id + "/" + key, value);
    }

    public Gee.List<Singularity.Accounts.Account> accounts (Singularity.Accounts.Capability capability) {
        return new Gee.ArrayList<Singularity.Accounts.Account> ();
    }

    public void show_message (string source_id, string message) {
        messages.add (message);
    }

    public void open_external (string uri) {
        opened.add (uri);
    }
}

public Singularity.MediaSources.AccountLink test_link (string id, string provider, string server, string user, string secret) {
    var l = new Singularity.MediaSources.AccountLink ();
    l.id = id;
    l.title = user + " on test";
    l.provider = provider;
    l.server = server;
    l.username = user;
    l.secret = secret;
    return l;
}

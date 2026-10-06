using Singularity.MediaSources;
using Singularity.Accounts;

namespace Singularity.MediaPlugins {

    public class SpotifyApi : Object {
        public AccountLink link { get; construct; }
        public Soup.Session session { get; construct; }
        public int64 blocked_until = 0;

        public SpotifyApi (AccountLink link, Soup.Session session) {
            Object (link: link, session: session);
        }

        public string base_url {
            owned get {
                string u = link.endpoint ("spotify-api", "https://api.spotify.com/v1/");
                return u.has_suffix ("/") ? u : u + "/";
            }
        }

        private static string reason_of (WebReply reply) {
            try {
                var e = Web.obj (reply.json ().get_object (), "error");
                return Web.str (e, "reason", Web.str (e, "message"));
            } catch (Error e) {
                return "";
            }
        }

        public async WebReply send (string method, string path, string? json_body, Cancellable? c) throws Error {
            if (get_real_time () < blocked_until) {
                int secs = (int) ((blocked_until - get_real_time ()) / 1000000) + 1;
                throw new MediaError.RATE_LIMITED (_("Spotify asks to wait %d seconds before the next request").printf (secs));
            }
            for (int attempt = 0; attempt < 2; attempt++) {
                var creds = yield link.credentials (Capability.MUSIC, attempt > 0);
                var headers = new HashTable<string, string> (str_hash, str_equal);
                headers.insert ("Authorization", "Bearer " + creds.secret);
                string url = path.has_prefix ("http") ? path : base_url + path;
                var reply = yield Web.request (session, method, url, headers, json_body != null ? "application/json" : null,
                    json_body != null ? new Bytes (json_body.data) : (method == "PUT" || method == "POST" ? new Bytes ("".data) : null), c);
                if (reply.status == 401 && attempt == 0) continue;
                if (reply.status == 429) {
                    int wait = int.max (reply.retry_after (), 1);
                    blocked_until = get_real_time () + (int64) wait * 1000000;
                    throw new MediaError.RATE_LIMITED (_("Spotify asks to wait %d seconds before the next request").printf (wait));
                }
                if (reply.status == 403) {
                    string reason = reason_of (reply);
                    if (reason == "PREMIUM_REQUIRED" || reason.contains ("Premium")) throw new MediaError.UNSUPPORTED (_("Controlling playback needs Spotify Premium"));
                    throw new MediaError.AUTH_FAILED (_("Spotify refused the request. Your developer app may not include this account."));
                }
                if (reply.status == 404 && path.has_prefix ("me/player")) throw new MediaError.NOT_FOUND (_("Open Spotify on one of your devices first"));
                if (reply.status == 401) {
                    yield link.report_problem (Capability.MUSIC);
                    throw new MediaError.AUTH_FAILED (_("Sign in to Spotify again in Online Accounts"));
                }
                Web.check (reply, "Spotify");
                return reply;
            }
            throw new MediaError.AUTH_FAILED (_("Sign in to Spotify again in Online Accounts"));
        }

        public async Json.Object get_object (string path, Cancellable? c) throws Error {
            var reply = yield send ("GET", path, null, c);
            if (reply.status == 204 || reply.body.get_size () == 0) return new Json.Object ();
            return reply.json ().get_object ();
        }
    }

    public class SpotifyConnect : Object, RemotePlayer, RemoteQueue {
        private SpotifyApi _api;
        private PlaybackState _state = PlaybackState.STOPPED;
        private MediaItem? _current = null;
        private int64 _position = 0;
        private int64 _duration = 0;
        private double _volume = 1;
        private RemoteDevice? _device = null;
        private uint _poll = 0;
        private bool _reading = false;
        public uint interval_ms = 1000;

        public PlaybackState state { get { return _state; } }
        public MediaItem? current { owned get { return _current; } }
        public int64 position_ms { get { return _position; } }
        public int64 duration_ms { get { return _duration; } }
        public double volume { get { return _volume; } }
        public RemoteDevice? device { owned get { return _device; } }

        public SpotifyConnect (SpotifyApi api) {
            _api = api;
        }

        public void set_active (bool active) {
            if (active && _poll == 0) {
                refresh.begin ();
                _poll = Timeout.add (interval_ms, () => {
                    refresh.begin ();
                    return Source.CONTINUE;
                });
            } else if (!active && _poll != 0) {
                Source.remove (_poll);
                _poll = 0;
            }
        }

        public async void refresh () {
            if (_reading) return;
            _reading = true;
            try {
                var o = yield _api.get_object ("me/player", null);
                apply (o);
            } catch (Error e) {
                debug ("spotify: %s", e.message);
            }
            _reading = false;
        }

        public void apply (Json.Object o) {
            if (!o.has_member ("is_playing")) {
                _state = PlaybackState.STOPPED;
                _current = null;
                state_changed ();
                return;
            }
            _state = Web.flag (o, "is_playing") ? PlaybackState.PLAYING : PlaybackState.PAUSED;
            _position = Web.num (o, "progress_ms");
            var item = Web.obj (o, "item");
            if (item != null) {
                _current = SpotifySource.track (_api.link, item);
                _duration = _current.duration_ms;
            }
            var d = Web.obj (o, "device");
            if (d != null) {
                _device = SpotifySource.device_of (d);
                if (_device.volume >= 0) _volume = _device.volume / 100.0;
            }
            state_changed ();
        }

        public async Gee.List<RemoteDevice> devices (Cancellable? c) throws Error {
            var o = yield _api.get_object ("me/player/devices", c);
            var list = new Gee.ArrayList<RemoteDevice> ();
            var arr = Web.arr (o, "devices");
            if (arr != null) arr.foreach_element ((a, i, n) => list.add (SpotifySource.device_of (n.get_object ())));
            return list;
        }

        public async void transfer (string device_id, bool play) throws Error {
            yield _api.send ("PUT", "me/player", "{\"device_ids\":[\"%s\"],\"play\":%s}".printf (device_id, play ? "true" : "false"), null);
            yield refresh ();
        }

        public static string uri_of (MediaItem item) {
            string link_id, kind, sid;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out sid)) return "";
            if (sid.has_prefix ("spotify:")) return sid;
            return "spotify:%s:%s".printf (kind, sid);
        }

        public async void play_item (MediaItem item, MediaItem? context) throws Error {
            string uri = uri_of (item);
            string body;
            string ctx = context != null ? uri_of (context) : "";
            if (ctx.has_prefix ("spotify:playlist:") || ctx.has_prefix ("spotify:album:")) body = "{\"context_uri\":\"%s\",\"offset\":{\"uri\":\"%s\"}}".printf (ctx, uri);
            else body = "{\"uris\":[\"%s\"]}".printf (uri);
            string path = "me/player/play";
            if (_device == null || !_device.active) {
                var list = yield devices (null);
                RemoteDevice? pick = null;
                foreach (var d in list) if (d.active) pick = d;
                if (pick == null && list.size > 0) pick = list[0];
                if (pick == null) throw new MediaError.NOT_FOUND (_("Open Spotify on one of your devices first"));
                path += "?device_id=" + Uri.escape_string (pick.id, null, false);
            }
            yield _api.send ("PUT", path, body, null);
            _current = item;
            _duration = item.duration_ms;
            _position = 0;
            _state = PlaybackState.PLAYING;
            state_changed ();
            Timeout.add (600, () => {
                refresh.begin ();
                return Source.REMOVE;
            });
        }

        public async void add_to_queue (MediaItem item) throws Error {
            yield _api.send ("POST", "me/player/queue?uri=" + Uri.escape_string (uri_of (item), null, false), null, null);
        }

        public async void resume () throws Error {
            yield _api.send ("PUT", "me/player/play", null, null);
            _state = PlaybackState.PLAYING;
            state_changed ();
        }

        public async void pause () throws Error {
            yield _api.send ("PUT", "me/player/pause", null, null);
            _state = PlaybackState.PAUSED;
            state_changed ();
        }

        public async void next () throws Error {
            yield _api.send ("POST", "me/player/next", null, null);
            yield refresh ();
        }

        public async void previous () throws Error {
            yield _api.send ("POST", "me/player/previous", null, null);
            yield refresh ();
        }

        public async void seek (int64 position_ms) throws Error {
            yield _api.send ("PUT", "me/player/seek?position_ms=%lld".printf (position_ms), null, null);
            _position = position_ms;
            state_changed ();
        }

        public async void set_volume (double volume) throws Error {
            int pct = (int) Math.round (volume.clamp (0, 1) * 100);
            yield _api.send ("PUT", "me/player/volume?volume_percent=%d".printf (pct), null, null);
            _volume = pct / 100.0;
            state_changed ();
        }
    }

    public class SpotifySource : Object, MediaSource, SourceAvailability, Browsable, Searchable, PlaybackResolver {
        public const string ID = "spotify";
        public const int GROUP = 20;
        public const int SEARCH_PAGE = 10;

        private MediaHost? _host = null;
        private ulong _accounts_handler = 0;
        private Gee.HashMap<string, SpotifyApi> _apis = new Gee.HashMap<string, SpotifyApi> ();
        private Gee.HashMap<string, SpotifyConnect> _players = new Gee.HashMap<string, SpotifyConnect> ();
        public Gee.List<AccountLink>? links_override = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return "Spotify"; } }
        public string icon_name { owned get { return "audio-x-generic-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.REMOTE | SourceFeatures.ISOLATED; } }
        public string? account_capability { owned get { return "music"; } }
        public bool available { get { return links ().size > 0; } }
        public string unavailable_reason { owned get { return _("Sign in to Spotify in Online Accounts with your own developer client ID."); } }

        public void activate (MediaHost host) {
            _host = host;
            _accounts_handler = host.accounts_changed.connect (() => changed ());
        }

        public void deactivate () {
            if (_host != null && _accounts_handler != 0) _host.disconnect (_accounts_handler);
            foreach (var p in _players.values) p.set_active (false);
            _host = null;
        }

        public Gee.List<AccountLink> links () {
            if (links_override != null) return links_override;
            if (_host == null) return new Gee.ArrayList<AccountLink> ();
            return AccountLinks.find (_host, Capability.MUSIC, "spotify");
        }

        private SpotifyApi api (AccountLink l) {
            if (!_apis.has_key (l.id)) _apis[l.id] = new SpotifyApi (l, _host != null ? _host.session : new Soup.Session ());
            return _apis[l.id];
        }

        public SpotifyConnect player (AccountLink l) {
            if (!_players.has_key (l.id)) _players[l.id] = new SpotifyConnect (api (l));
            return _players[l.id];
        }

        private AccountLink? link (string id) {
            foreach (var l in links ()) if (l.id == id) return l;
            return null;
        }

        private static string image (Json.Object? o) {
            var imgs = Web.arr (o, "images");
            if (imgs == null || imgs.get_length () == 0) return "";
            return Web.str (imgs.get_object_element (0), "url");
        }

        private static string artists (Json.Object o) {
            var arr = Web.arr (o, "artists");
            if (arr == null) return "";
            string[] names = {};
            for (uint i = 0; i < arr.get_length (); i++) names += Web.str (arr.get_object_element (i), "name");
            return string.joinv (", ", names);
        }

        private static void brand (MediaItem it, Json.Object o) {
            it.attribution = "Spotify";
            it.external_url = Web.str (Web.obj (o, "external_urls"), "spotify");
            it.external_label = _("Open Spotify");
        }

        public static MediaItem track (AccountLink l, Json.Object o) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "track", Web.str (o, "uri", "spotify:track:" + Web.str (o, "id"))), ItemKind.TRACK, Web.str (o, "name"));
            it.artist = artists (o);
            it.subtitle = it.artist;
            var album = Web.obj (o, "album");
            it.album = Web.str (album, "name");
            it.image_url = image (album);
            it.duration_ms = Web.num (o, "duration_ms");
            it.track_number = (int) Web.num (o, "track_number");
            it.playable = Web.flag (o, "is_playable", true);
            brand (it, o);
            return it;
        }

        private static MediaItem album_item (AccountLink l, Json.Object o) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "album", Web.str (o, "id")), ItemKind.ALBUM, Web.str (o, "name"));
            it.artist = artists (o);
            it.subtitle = it.artist;
            it.image_url = image (o);
            string date = Web.str (o, "release_date");
            if (date.length >= 4) it.year = int.parse (date.substring (0, 4));
            brand (it, o);
            return it;
        }

        private static MediaItem playlist_item (AccountLink l, Json.Object o) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "playlist", Web.str (o, "id")), ItemKind.PLAYLIST, Web.str (o, "name"));
            it.subtitle = Web.str (Web.obj (o, "owner"), "display_name");
            it.image_url = image (o);
            brand (it, o);
            return it;
        }

        private static MediaItem artist_item (AccountLink l, Json.Object o) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "artist", Web.str (o, "id")), ItemKind.ARTIST, Web.str (o, "name"));
            it.image_url = image (o);
            brand (it, o);
            return it;
        }

        public static RemoteDevice device_of (Json.Object o) {
            var d = new RemoteDevice (Web.str (o, "id"), Web.str (o, "name"));
            d.device_type = Web.str (o, "type").down ();
            d.active = Web.flag (o, "is_active");
            d.restricted = Web.flag (o, "is_restricted");
            d.volume = (int) Web.num (o, "volume_percent", -1);
            return d;
        }

        private static MediaItem folder (AccountLink l, string kind, string title, string icon) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, kind), ItemKind.FOLDER, title);
            it.set_extra ("icon", icon);
            return it;
        }

        private MediaPage no_account () {
            var page = new MediaPage (title);
            page.notice = unavailable_reason;
            page.action_label = _("Online Accounts");
            page.action_uri = "settings:accounts";
            return page;
        }

        private static string paged (string path, int offset, int limit) {
            return "%s%slimit=%d&offset=%d".printf (path, path.contains ("?") ? "&" : "?", limit, offset);
        }

        private static void finish (MediaPage page, Json.Object o, int offset) {
            page.total = (int) Web.num (o, "total", page.items.size);
            page.next_token = Paging.next_of (offset, page.items.size, page.total);
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            var all = links ();
            if (all.size == 0) return no_account ();
            if (node == null || node == "") {
                var l = all[0];
                var page = new MediaPage (title);
                page.add (folder (l, "liked", _("Liked Songs"), "singularity-music-liked"));
                page.add (folder (l, "playlists", _("Playlists"), "singularity-music-playlist"));
                page.add (folder (l, "albums", _("Albums"), "singularity-music-album"));
                page.add (folder (l, "artists", _("Artists"), "singularity-music-artist"));
                page.add (folder (l, "queue", _("Queue"), "singularity-music-queue"));
                return page;
            }
            string link_id, kind, sid;
            if (!AccountLinks.parse (node, out link_id, out kind, out sid)) throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            int offset = Paging.offset_of (token);
            var a = api (l);
            switch (kind) {
                case "liked": {
                    var o = yield a.get_object (paged ("me/tracks", offset, GROUP), c);
                    var page = new MediaPage (_("Liked Songs"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        var t = Web.obj (n.get_object (), "track");
                        if (t != null) page.add (track (l, t));
                    });
                    finish (page, o, offset);
                    return page;
                }
                case "playlists": {
                    var o = yield a.get_object (paged ("me/playlists", offset, GROUP), c);
                    var page = new MediaPage (_("Playlists"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        if (n.get_node_type () == Json.NodeType.OBJECT) page.add (playlist_item (l, n.get_object ()));
                    });
                    finish (page, o, offset);
                    return page;
                }
                case "albums": {
                    var o = yield a.get_object (paged ("me/albums", offset, GROUP), c);
                    var page = new MediaPage (_("Albums"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        var al = Web.obj (n.get_object (), "album");
                        if (al != null) page.add (album_item (l, al));
                    });
                    finish (page, o, offset);
                    return page;
                }
                case "artists": {
                    string path = "me/following?type=artist&limit=%d".printf (GROUP);
                    if (token != null && token != "") path += "&after=" + Uri.escape_string (token, null, false);
                    var o = Web.obj (yield a.get_object (path, c), "artists");
                    var page = new MediaPage (_("Artists"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        if (n.get_node_type () == Json.NodeType.OBJECT) page.add (artist_item (l, n.get_object ()));
                    });
                    page.total = (int) Web.num (o, "total", page.items.size);
                    string after = Web.str (Web.obj (o, "cursors"), "after");
                    page.next_token = after != "" ? after : null;
                    return page;
                }
                case "artist": {
                    var o = yield a.get_object (paged ("artists/" + sid + "/albums?include_groups=album,single", offset, GROUP), c);
                    var page = new MediaPage (_("Albums"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        if (n.get_node_type () == Json.NodeType.OBJECT) page.add (album_item (l, n.get_object ()));
                    });
                    finish (page, o, offset);
                    return page;
                }
                case "queue": {
                    var o = yield a.get_object ("me/player/queue", c);
                    var page = new MediaPage (_("Queue"));
                    var cur = Web.obj (o, "currently_playing");
                    if (cur != null && Web.str (cur, "type", "track") == "track") page.add (track (l, cur));
                    var arr = Web.arr (o, "queue");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        if (n.get_node_type () != Json.NodeType.OBJECT) return;
                        var t = n.get_object ();
                        if (Web.str (t, "type", "track") == "track" && page.items.size < GROUP) page.add (track (l, t));
                    });
                    if (page.items.size == 0) page.notice = _("Nothing is queued on your Spotify devices.");
                    return page;
                }
                case "playlist": {
                    Json.Object o;
                    try {
                        o = yield a.get_object (paged ("playlists/" + sid + "/items", offset, GROUP), c);
                    } catch (MediaError.NOT_FOUND e) {
                        o = yield a.get_object (paged ("playlists/" + sid + "/tracks", offset, GROUP), c);
                    }
                    var page = new MediaPage (_("Playlist"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        var e = n.get_object ();
                        var t = Web.obj (e, "item") ?? Web.obj (e, "track");
                        if (t != null && Web.str (t, "type", "track") == "track") page.add (track (l, t));
                    });
                    finish (page, o, offset);
                    return page;
                }
                case "album": {
                    var al = yield a.get_object ("albums/" + sid, c);
                    var o = yield a.get_object (paged ("albums/" + sid + "/tracks", offset, GROUP), c);
                    var page = new MediaPage (Web.str (al, "name"));
                    var arr = Web.arr (o, "items");
                    if (arr != null) arr.foreach_element ((x, i, n) => {
                        var t = n.get_object ();
                        if (!t.has_member ("album")) t.set_object_member ("album", al);
                        page.add (track (l, t));
                    });
                    finish (page, o, offset);
                    return page;
                }
                default:
                    throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            }
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            var all = links ();
            if (all.size == 0) return no_account ();
            var l = all[0];
            int offset = Paging.offset_of (token);
            var o = yield api (l).get_object ("search?" + "q=%s&type=track,album,artist,playlist&limit=%d&offset=%d".printf (Uri.escape_string (query, null, false), SEARCH_PAGE, offset), c);
            var page = new MediaPage (_("Results"));
            int most = 0;
            var tracks = Web.obj (o, "tracks");
            var arr = Web.arr (tracks, "items");
            if (arr != null) arr.foreach_element ((x, i, n) => {
                if (n.get_node_type () == Json.NodeType.OBJECT) page.add (track (l, n.get_object ()));
            });
            most = int.max (most, (int) Web.num (tracks, "total"));
            if (offset == 0) {
                var arts = Web.arr (Web.obj (o, "artists"), "items");
                if (arts != null) arts.foreach_element ((x, i, n) => {
                    if (n.get_node_type () == Json.NodeType.OBJECT) page.add (artist_item (l, n.get_object ()));
                });
                var albums = Web.arr (Web.obj (o, "albums"), "items");
                if (albums != null) albums.foreach_element ((x, i, n) => {
                    if (n.get_node_type () == Json.NodeType.OBJECT) page.add (album_item (l, n.get_object ()));
                });
                var pls = Web.arr (Web.obj (o, "playlists"), "items");
                if (pls != null) pls.foreach_element ((x, i, n) => {
                    if (n.get_node_type () == Json.NodeType.OBJECT) page.add (playlist_item (l, n.get_object ()));
                });
            }
            if (offset + SEARCH_PAGE < most && offset + SEARCH_PAGE < 100) page.next_token = (offset + SEARCH_PAGE).to_string ();
            return page;
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            var all = links ();
            string link_id, kind, sid;
            AccountLink? l = null;
            if (AccountLinks.parse (item.id, out link_id, out kind, out sid)) l = link (link_id);
            if (l == null && all.size > 0) l = all[0];
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            return Playback.remote_control (player (l));
        }
    }
}

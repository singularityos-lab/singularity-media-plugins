using Singularity.MediaSources;
using Singularity.Accounts;

namespace Singularity.MediaPlugins {

    public class SubsonicSource : Object, MediaSource, SourceAvailability, Browsable, Searchable, PlaybackResolver, Scrobbler {
        public const string ID = "subsonic";
        public const string API_VERSION = "1.16.1";
        private const int PAGE = 60;

        private MediaHost? _host = null;
        private ulong _accounts_handler = 0;
        private Gee.HashMap<string, AccountCredentials> _creds = new Gee.HashMap<string, AccountCredentials> ();
        public Gee.List<AccountLink>? links_override = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return "Navidrome"; } }
        public string icon_name { owned get { return "network-server-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY | SourceFeatures.SCROBBLE; } }
        public string? account_capability { owned get { return "music"; } }
        public bool available { get { return links ().size > 0; } }
        public string unavailable_reason { owned get { return _("Add your Navidrome or Subsonic server in Online Accounts."); } }
        public bool enabled { get { return links ().size > 0; } }

        public void activate (MediaHost host) {
            _host = host;
            _accounts_handler = host.accounts_changed.connect (() => {
                _creds.clear ();
                changed ();
            });
        }

        public void deactivate () {
            if (_host != null && _accounts_handler != 0) _host.disconnect (_accounts_handler);
            _host = null;
        }

        public Gee.List<AccountLink> links () {
            if (links_override != null) return links_override;
            if (_host == null) return new Gee.ArrayList<AccountLink> ();
            return AccountLinks.find (_host, Capability.MUSIC, "subsonic");
        }

        private AccountLink? link (string id) {
            foreach (var l in links ()) if (l.id == id) return l;
            return null;
        }

        private static string base_url (AccountLink l) {
            return AccountLinks.trim_slash (l.endpoint ("subsonic", l.server));
        }

        private Soup.Session session () {
            return _host != null ? _host.session : new Soup.Session ();
        }

        private async AccountCredentials creds (AccountLink l, bool fresh = false) throws Error {
            if (!fresh && _creds.has_key (l.id)) return _creds[l.id];
            var c = yield l.credentials (Capability.MUSIC, fresh);
            _creds[l.id] = c;
            return c;
        }

        public static string auth_query (string user, string secret, string salt) {
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("u", user);
            p.insert ("t", Checksum.compute_for_string (ChecksumType.MD5, secret + salt));
            p.insert ("s", salt);
            p.insert ("v", API_VERSION);
            p.insert ("c", "singularity");
            p.insert ("f", "json");
            return Web.query (p);
        }

        private static string salt () {
            var sb = new StringBuilder ();
            for (int i = 0; i < 12; i++) sb.append_c ("abcdefghijklmnopqrstuvwxyz0123456789"[Random.int_range (0, 36)]);
            return sb.str;
        }

        private async string url (AccountLink l, string method, HashTable<string, string>? params) throws Error {
            var c = yield creds (l);
            string u = base_url (l) + "/rest/" + method + "?" + auth_query (c.username, c.secret, salt ());
            if (params != null && params.size () > 0) u += "&" + Web.query (params);
            return u;
        }

        private async Json.Object call (AccountLink l, string method, HashTable<string, string>? params, Cancellable? cancel) throws Error {
            var reply = yield Web.request (session (), "GET", yield url (l, method, params), null, null, null, cancel);
            Web.check (reply, "Subsonic");
            var root = Web.obj (reply.json ().get_object (), "subsonic-response");
            if (root == null) throw new MediaError.PROTOCOL (_("The server did not answer like a Subsonic server"));
            if (Web.str (root, "status") != "ok") {
                var err = Web.obj (root, "error");
                int64 code = Web.num (err, "code");
                if (code == 40 || code == 41 || code == 44) {
                    _creds.unset (l.id);
                    yield l.report_problem (Capability.MUSIC);
                    throw new MediaError.AUTH_FAILED (_("The server refused the user name or password. Enter it again in Online Accounts."));
                }
                if (code == 70) throw new MediaError.NOT_FOUND (Web.str (err, "message", _("Not found")));
                throw new MediaError.PROTOCOL (Web.str (err, "message", _("The server reported an error")));
            }
            return root;
        }

        private static HashTable<string, string> p (string k1 = "", string v1 = "", string k2 = "", string v2 = "", string k3 = "", string v3 = "") {
            var t = new HashTable<string, string> (str_hash, str_equal);
            if (k1 != "") t.insert (k1, v1);
            if (k2 != "") t.insert (k2, v2);
            if (k3 != "") t.insert (k3, v3);
            return t;
        }

        private async string cover_url (AccountLink l, string cover) throws Error {
            if (cover == "") return "";
            return yield url (l, "getCoverArt", p ("id", cover, "size", "400"));
        }

        private async MediaItem song (AccountLink l, Json.Object o) throws Error {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "song", Web.str (o, "id")), ItemKind.TRACK, Web.str (o, "title"));
            it.artist = Web.str (o, "artist");
            it.album = Web.str (o, "album");
            it.subtitle = it.artist;
            it.track_number = (int) Web.num (o, "track");
            it.year = (int) Web.num (o, "year");
            it.duration_ms = Web.num (o, "duration") * 1000;
            it.image_url = yield cover_url (l, Web.str (o, "coverArt"));
            it.attribution = title;
            return it;
        }

        private async MediaItem album (AccountLink l, Json.Object o) throws Error {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "album", Web.str (o, "id")), ItemKind.ALBUM, Web.str (o, "name", Web.str (o, "title")));
            it.artist = Web.str (o, "artist");
            it.year = (int) Web.num (o, "year");
            it.subtitle = it.year > 0 && it.artist != "" ? "%s, %d".printf (it.artist, it.year) : it.artist;
            it.image_url = yield cover_url (l, Web.str (o, "coverArt"));
            return it;
        }

        private MediaItem artist (AccountLink l, Json.Object o) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, "artist", Web.str (o, "id")), ItemKind.ARTIST, Web.str (o, "name"));
            int n = (int) Web.num (o, "albumCount");
            if (n > 0) it.subtitle = ngettext ("%d album", "%d albums", n).printf (n);
            return it;
        }

        private MediaPage no_server () {
            var page = new MediaPage (title);
            page.notice = unavailable_reason;
            page.action_label = _("Online Accounts");
            page.action_uri = "settings:accounts";
            return page;
        }

        private MediaItem folder (AccountLink l, string kind, string t) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, kind), ItemKind.FOLDER, t);
            switch (kind) {
                case "albums": it.set_extra ("icon", "singularity-music-album"); break;
                case "artists": it.set_extra ("icon", "singularity-music-artist"); break;
                case "playlists": it.set_extra ("icon", "singularity-music-playlist"); break;
                case "starred": it.set_extra ("icon", "singularity-music-liked"); break;
                case "recent": it.set_extra ("icon", "singularity-music-recent"); break;
                case "server": it.set_extra ("icon", "network-server"); break;
            }
            return it;
        }

        private MediaPage root_of (AccountLink l) {
            var page = new MediaPage (links ().size > 1 ? l.title : title);
            page.add (folder (l, "albums", _("Albums")));
            page.add (folder (l, "artists", _("Artists")));
            page.add (folder (l, "playlists", _("Playlists")));
            page.add (folder (l, "starred", _("Favorites")));
            page.add (folder (l, "recent", _("Recently Added")));
            return page;
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            var all = links ();
            if (all.size == 0) return no_server ();
            if (node == null || node == "") {
                if (all.size == 1) return root_of (all[0]);
                var page = new MediaPage (title);
                foreach (var l in all) page.add (folder (l, "server", l.title));
                return page;
            }
            string link_id, kind, sid;
            if (!AccountLinks.parse (node, out link_id, out kind, out sid)) throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            int offset = Paging.offset_of (token);
            switch (kind) {
                case "server":
                    return root_of (l);
                case "albums":
                case "recent": {
                    var o = yield call (l, "getAlbumList2", p ("type", kind == "recent" ? "newest" : "alphabeticalByName", "size", PAGE.to_string (), "offset", offset.to_string ()), c);
                    var page = new MediaPage (kind == "recent" ? _("Recently Added") : _("Albums"));
                    var list = Web.arr (Web.obj (o, "albumList2"), "album");
                    if (list != null) for (uint i = 0; i < list.get_length (); i++) page.add (yield album (l, list.get_object_element (i)));
                    if (page.items.size == PAGE && kind == "albums") page.next_token = (offset + PAGE).to_string ();
                    return page;
                }
                case "artists": {
                    var o = yield call (l, "getArtists", null, c);
                    var page = new MediaPage (_("Artists"));
                    var index = Web.arr (Web.obj (o, "artists"), "index");
                    if (index != null) index.foreach_element ((a, i, n) => {
                        var arts = Web.arr (n.get_object (), "artist");
                        if (arts != null) arts.foreach_element ((a2, j, n2) => page.add (artist (l, n2.get_object ())));
                    });
                    page.total = page.items.size;
                    return page;
                }
                case "artist": {
                    var o = yield call (l, "getArtist", p ("id", sid), c);
                    var a = Web.obj (o, "artist");
                    var page = new MediaPage (Web.str (a, "name"));
                    var list = Web.arr (a, "album");
                    if (list != null) for (uint i = 0; i < list.get_length (); i++) page.add (yield album (l, list.get_object_element (i)));
                    return page;
                }
                case "album": {
                    var o = yield call (l, "getAlbum", p ("id", sid), c);
                    var a = Web.obj (o, "album");
                    var page = new MediaPage (Web.str (a, "name"));
                    var list = Web.arr (a, "song");
                    if (list != null) for (uint i = 0; i < list.get_length (); i++) page.add (yield song (l, list.get_object_element (i)));
                    return page;
                }
                case "playlists": {
                    var o = yield call (l, "getPlaylists", null, c);
                    var page = new MediaPage (_("Playlists"));
                    var list = Web.arr (Web.obj (o, "playlists"), "playlist");
                    if (list != null) for (uint i = 0; i < list.get_length (); i++) {
                        var x = list.get_object_element (i);
                        var it = new MediaItem (ID, AccountLinks.node (l.id, "playlist", Web.str (x, "id")), ItemKind.PLAYLIST, Web.str (x, "name"));
                        int n = (int) Web.num (x, "songCount");
                        it.subtitle = ngettext ("%d song", "%d songs", n).printf (n);
                        it.image_url = yield cover_url (l, Web.str (x, "coverArt"));
                        page.add (it);
                    }
                    return page;
                }
                case "playlist": {
                    var o = yield call (l, "getPlaylist", p ("id", sid), c);
                    var pl = Web.obj (o, "playlist");
                    var page = new MediaPage (Web.str (pl, "name"));
                    var list = Web.arr (pl, "entry");
                    if (list != null) for (uint i = 0; i < list.get_length (); i++) page.add (yield song (l, list.get_object_element (i)));
                    return page;
                }
                case "starred": {
                    var o = yield call (l, "getStarred2", null, c);
                    var s = Web.obj (o, "starred2");
                    var page = new MediaPage (_("Favorites"));
                    var albums = Web.arr (s, "album");
                    if (albums != null) for (uint i = 0; i < albums.get_length (); i++) page.add (yield album (l, albums.get_object_element (i)));
                    var songs = Web.arr (s, "song");
                    if (songs != null) for (uint i = 0; i < songs.get_length (); i++) page.add (yield song (l, songs.get_object_element (i)));
                    return page;
                }
                default:
                    throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            }
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            var page = new MediaPage (_("Results"));
            int offset = Paging.offset_of (token);
            foreach (var l in links ()) {
                var o = yield call (l, "search3", p ("query", query, "songCount", "40", "songOffset", offset.to_string ()), c);
                var r = Web.obj (o, "searchResult3");
                if (offset == 0) {
                    var arts = Web.arr (r, "artist");
                    if (arts != null) arts.foreach_element ((a, i, n) => page.add (artist (l, n.get_object ())));
                    var albums = Web.arr (r, "album");
                    if (albums != null) for (uint i = 0; i < albums.get_length (); i++) page.add (yield album (l, albums.get_object_element (i)));
                }
                var songs = Web.arr (r, "song");
                if (songs != null) {
                    for (uint i = 0; i < songs.get_length (); i++) page.add (yield song (l, songs.get_object_element (i)));
                    if (songs.get_length () == 40) page.next_token = (offset + 40).to_string ();
                }
            }
            return page;
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            string link_id, kind, sid;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out sid) || kind != "song") throw new MediaError.NOT_FOUND (_("Unknown item"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            return Playback.stream (yield url (l, "stream", p ("id", sid)));
        }

        public async void now_playing (MediaItem item, Cancellable? c) throws Error {
            yield scrobble (item, false, c);
        }

        public async void listened (MediaItem item, int64 played_ms, DateTime started, Cancellable? c) throws Error {
            yield scrobble (item, true, c);
        }

        private async void scrobble (MediaItem item, bool submission, Cancellable? c) throws Error {
            if (item.source_id != ID) return;
            string link_id, kind, sid;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out sid) || kind != "song") return;
            var l = link (link_id);
            if (l == null) return;
            yield call (l, "scrobble", p ("id", sid, "submission", submission ? "true" : "false"), c);
        }
    }
}

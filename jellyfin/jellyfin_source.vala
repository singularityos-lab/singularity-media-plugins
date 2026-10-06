using Singularity.MediaSources;
using Singularity.Accounts;

namespace Singularity.MediaPlugins {

    public class JellyfinSource : Object, MediaSource, SourceAvailability, Browsable, Searchable, PlaybackResolver, Scrobbler {
        public const string ID = "jellyfin";
        private const int PAGE = 60;
        private const string FIELDS = "PrimaryImageAspectRatio,ChildCount,AlbumArtist,RunTimeTicks,ProductionYear";

        private MediaHost? _host = null;
        private Gee.HashMap<string, string> _tokens = new Gee.HashMap<string, string> ();
        private ulong _accounts_handler = 0;
        public Gee.List<AccountLink>? links_override = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return "Jellyfin"; } }
        public string icon_name { owned get { return "network-server-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO | MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY | SourceFeatures.SCROBBLE; } }
        public bool enabled { get { return links ().size > 0; } }
        public string? account_capability { owned get { return audio () ? "music" : "videos"; } }
        public bool available { get { return links ().size > 0; } }
        public string unavailable_reason { owned get { return _("Add your Jellyfin server in Online Accounts."); } }

        public void activate (MediaHost host) {
            _host = host;
            _accounts_handler = host.accounts_changed.connect (() => {
                _tokens.clear ();
                changed ();
            });
        }

        public void deactivate () {
            if (_host != null && _accounts_handler != 0) _host.disconnect (_accounts_handler);
            _host = null;
        }

        private bool audio () {
            return _host == null || (_host.kinds & MediaKind.AUDIO) != 0;
        }

        private Capability capability () {
            return audio () ? Capability.MUSIC : Capability.VIDEOS;
        }

        public Gee.List<AccountLink> links () {
            if (links_override != null) return links_override;
            if (_host == null) return new Gee.ArrayList<AccountLink> ();
            return AccountLinks.find (_host, capability (), "jellyfin");
        }

        private AccountLink? link (string id) {
            foreach (var l in links ()) if (l.id == id) return l;
            return null;
        }

        private static string base_url (AccountLink l) {
            return AccountLinks.trim_slash (l.endpoint ("jellyfin", l.server));
        }

        private static string device_id (AccountLink l) {
            return l.endpoint ("jellyfin-device", Checksum.compute_for_string (ChecksumType.SHA256, l.id).substring (0, 16));
        }

        private static string auth_header (AccountLink l, string? token) {
            string h = "MediaBrowser Client=\"Singularity\", Device=\"Singularity\", DeviceId=\"%s\", Version=\"1.0\"".printf (device_id (l));
            if (token != null) h += ", Token=\"%s\"".printf (token);
            return h;
        }

        private Soup.Session session () {
            return _host != null ? _host.session : new Soup.Session ();
        }

        private async string token (AccountLink l, Cancellable? c, bool fresh = false) throws Error {
            if (!fresh && _tokens.has_key (l.id)) return _tokens[l.id];
            var creds = yield l.credentials (capability ());
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("Username").add_string_value (creds.username);
            b.set_member_name ("Pw").add_string_value (creds.secret);
            b.end_object ();
            var g = new Json.Generator ();
            g.set_root (b.get_root ());
            var headers = new HashTable<string, string> (str_hash, str_equal);
            headers.insert ("X-Emby-Authorization", auth_header (l, null));
            headers.insert ("Authorization", auth_header (l, null));
            var reply = yield Web.request (session (), "POST", base_url (l) + "/Users/AuthenticateByName", headers, "application/json", new Bytes (g.to_data (null).data), c);
            if (reply.status == 401) {
                yield l.report_problem (capability ());
                throw new MediaError.AUTH_FAILED (_("Jellyfin refused the user name or password. Enter it again in Online Accounts."));
            }
            Web.check (reply, "Jellyfin");
            var o = reply.json ().get_object ();
            string t = Web.str (o, "AccessToken");
            if (t == "") throw new MediaError.PROTOCOL (_("Jellyfin did not return a session"));
            var user = Web.obj (o, "User");
            if (user != null && Web.str (user, "Id") != "") l.set_endpoint ("jellyfin-user-id", Web.str (user, "Id"));
            _tokens[l.id] = t;
            return t;
        }

        private async Json.Object api_get (AccountLink l, string path, HashTable<string, string>? query, Cancellable? c) throws Error {
            for (int attempt = 0; attempt < 2; attempt++) {
                string t = yield token (l, c, attempt > 0);
                var headers = new HashTable<string, string> (str_hash, str_equal);
                headers.insert ("X-Emby-Authorization", auth_header (l, t));
                headers.insert ("Authorization", auth_header (l, t));
                headers.insert ("X-Emby-Token", t);
                string url = base_url (l) + path + (query != null ? "?" + Web.query (query) : "");
                var reply = yield Web.request (session (), "GET", url, headers, null, null, c);
                if (reply.status == 401 && attempt == 0) {
                    _tokens.unset (l.id);
                    continue;
                }
                Web.check (reply, "Jellyfin");
                var node = reply.json ();
                if (node.get_node_type () == Json.NodeType.ARRAY) {
                    var wrap = new Json.Object ();
                    wrap.set_array_member ("Items", node.get_array ());
                    return wrap;
                }
                return node.get_object ();
            }
            throw new MediaError.AUTH_FAILED (_("Jellyfin refused the session"));
        }

        private string user_id (AccountLink l) {
            return l.endpoint ("jellyfin-user-id");
        }

        private static string image_url (AccountLink l, string item_id, string? tag) {
            string url = base_url (l) + "/Items/" + item_id + "/Images/Primary?fillHeight=400&quality=90";
            if (tag != null && tag != "") url += "&tag=" + tag;
            return url;
        }

        private MediaItem to_item (AccountLink l, Json.Object o) {
            string type = Web.str (o, "Type");
            string jid = Web.str (o, "Id");
            ItemKind kind;
            string node_kind;
            switch (type) {
                case "MusicAlbum": kind = ItemKind.ALBUM; node_kind = "album"; break;
                case "MusicArtist": kind = ItemKind.ARTIST; node_kind = "artist"; break;
                case "Playlist": kind = ItemKind.PLAYLIST; node_kind = "playlist"; break;
                case "Audio": kind = ItemKind.TRACK; node_kind = "track"; break;
                case "Movie": kind = ItemKind.VIDEO; node_kind = "video"; break;
                case "Episode": kind = ItemKind.EPISODE; node_kind = "video"; break;
                case "Video": case "MusicVideo": kind = ItemKind.VIDEO; node_kind = "video"; break;
                case "Series": kind = ItemKind.CHANNEL; node_kind = "series"; break;
                case "Season": kind = ItemKind.FOLDER; node_kind = "season"; break;
                default: kind = ItemKind.FOLDER; node_kind = "folder"; break;
            }
            var it = new MediaItem (ID, AccountLinks.node (l.id, node_kind, jid), kind, Web.str (o, "Name"));
            var artists = Web.arr (o, "Artists");
            if (artists != null && artists.get_length () > 0) it.artist = artists.get_string_element (0);
            if (Web.str (o, "AlbumArtist") != "") it.artist = it.artist != "" ? it.artist : Web.str (o, "AlbumArtist");
            it.album = Web.str (o, "Album");
            it.track_number = (int) Web.num (o, "IndexNumber");
            it.year = (int) Web.num (o, "ProductionYear");
            it.duration_ms = Web.num (o, "RunTimeTicks") / 10000;
            var tags = Web.obj (o, "ImageTags");
            string? primary = tags != null ? Web.str (tags, "Primary") : null;
            if (primary != null && primary != "") it.image_url = image_url (l, jid, primary);
            else if (Web.str (o, "AlbumId") != "" && Web.str (o, "AlbumPrimaryImageTag") != "") it.image_url = image_url (l, Web.str (o, "AlbumId"), Web.str (o, "AlbumPrimaryImageTag"));
            if (kind == ItemKind.ALBUM) {
                it.subtitle = Web.str (o, "AlbumArtist");
                if (it.year > 0) it.subtitle = it.subtitle != "" ? "%s, %d".printf (it.subtitle, it.year) : it.year.to_string ();
            } else if (kind == ItemKind.TRACK) {
                it.subtitle = it.artist;
            } else if (kind == ItemKind.PLAYLIST || kind == ItemKind.FOLDER || kind == ItemKind.CHANNEL) {
                int64 n = Web.num (o, "ChildCount", -1);
                if (n >= 0) it.subtitle = ngettext ("%d item", "%d items", (int) n).printf ((int) n);
            } else if (kind == ItemKind.EPISODE) {
                it.subtitle = Web.str (o, "SeriesName");
            }
            it.attribution = "Jellyfin";
            it.external_url = base_url (l) + "/web/#/details?id=" + jid;
            it.external_label = _("Open in Jellyfin");
            return it;
        }

        private MediaPage page_of (AccountLink l, Json.Object o, string title, int offset) {
            var page = new MediaPage (title);
            var items = Web.arr (o, "Items");
            if (items != null) items.foreach_element ((a, i, n) => {
                if (n.get_node_type () == Json.NodeType.OBJECT) page.add (to_item (l, n.get_object ()));
            });
            page.total = (int) Web.num (o, "TotalRecordCount", page.items.size);
            page.next_token = Paging.next_of (offset, page.items.size, page.total);
            return page;
        }

        private HashTable<string, string> q (int offset, string sort = "SortName") {
            var t = new HashTable<string, string> (str_hash, str_equal);
            t.insert ("StartIndex", offset.to_string ());
            t.insert ("Limit", PAGE.to_string ());
            t.insert ("SortBy", sort);
            t.insert ("SortOrder", "Ascending");
            t.insert ("Fields", FIELDS);
            t.insert ("EnableImageTypes", "Primary");
            return t;
        }

        private MediaPage no_server () {
            var page = new MediaPage ("Jellyfin");
            page.notice = unavailable_reason;
            page.action_label = _("Online Accounts");
            page.action_uri = "settings:accounts";
            return page;
        }

        public async MediaPage browse (string? node, string? token_s, Cancellable? c) throws Error {
            var all = links ();
            if (all.size == 0) return no_server ();
            if (node == null || node == "") {
                if (all.size == 1) return yield libraries (all[0], c);
                var page = new MediaPage ("Jellyfin");
                foreach (var l in all) {
                    var it = new MediaItem (ID, AccountLinks.node (l.id, "server"), ItemKind.FOLDER, l.title);
                    it.subtitle = base_url (l);
                    page.add (it);
                }
                return page;
            }
            string link_id, kind, jid;
            if (!AccountLinks.parse (node, out link_id, out kind, out jid)) throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            int offset = Paging.offset_of (token_s);
            yield token (l, c);
            string uid = user_id (l);
            switch (kind) {
                case "server":
                    return yield libraries (l, c);
                case "library": {
                    var page = new MediaPage (_("Library"));
                    string ctype = "";
                    var parts = jid.split ("|", 2);
                    string lib = parts[0];
                    if (parts.length > 1) ctype = parts[1];
                    if (ctype == "music") {
                        page.add (folder (l, "albums", lib, _("Albums")));
                        page.add (folder (l, "artists", lib, _("Artists")));
                        page.add (folder (l, "songs", lib, _("Songs")));
                        return page;
                    }
                    var t = q (offset);
                    t.insert ("ParentId", lib);
                    return page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Library"), offset);
                }
                case "albums": {
                    var t = q (offset);
                    t.insert ("ParentId", jid);
                    t.insert ("IncludeItemTypes", "MusicAlbum");
                    t.insert ("Recursive", "true");
                    return page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Albums"), offset);
                }
                case "songs": {
                    var t = q (offset);
                    t.insert ("ParentId", jid);
                    t.insert ("IncludeItemTypes", "Audio");
                    t.insert ("Recursive", "true");
                    return page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Songs"), offset);
                }
                case "artists": {
                    var t = q (offset);
                    t.insert ("ParentId", jid);
                    t.insert ("UserId", uid);
                    return page_of (l, yield api_get (l, "/Artists/AlbumArtists", t, c), _("Artists"), offset);
                }
                case "artist": {
                    var t = q (offset, "ProductionYear,SortName");
                    t.insert ("AlbumArtistIds", jid);
                    t.insert ("IncludeItemTypes", "MusicAlbum");
                    t.insert ("Recursive", "true");
                    return page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Albums"), offset);
                }
                case "album": {
                    var t = q (offset, "ParentIndexNumber,IndexNumber,SortName");
                    t.insert ("ParentId", jid);
                    var page = page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Album"), offset);
                    if (page.items.size > 0 && page.items[0].album != "") page.title = page.items[0].album;
                    return page;
                }
                case "playlists": {
                    var t = q (offset);
                    t.insert ("IncludeItemTypes", "Playlist");
                    t.insert ("Recursive", "true");
                    if (audio ()) t.insert ("MediaTypes", "Audio");
                    return page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Playlists"), offset);
                }
                case "playlist": {
                    var t = q (offset, "");
                    t.remove ("SortBy");
                    t.remove ("SortOrder");
                    t.insert ("UserId", uid);
                    return page_of (l, yield api_get (l, "/Playlists/" + jid + "/Items", t, c), _("Playlist"), offset);
                }
                case "series":
                case "season":
                case "folder": {
                    var t = q (offset, kind == "folder" ? "SortName" : "ParentIndexNumber,IndexNumber,SortName");
                    t.insert ("ParentId", jid);
                    return page_of (l, yield api_get (l, "/Users/" + uid + "/Items", t, c), _("Items"), offset);
                }
                default:
                    throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            }
        }

        private MediaItem folder (AccountLink l, string kind, string id, string title) {
            var it = new MediaItem (ID, AccountLinks.node (l.id, kind, id), ItemKind.FOLDER, title);
            switch (kind) {
                case "albums": it.set_extra ("icon", "singularity-music-album"); break;
                case "artists": it.set_extra ("icon", "singularity-music-artist"); break;
                case "songs": it.set_extra ("icon", "singularity-music-songs"); break;
                case "playlists": it.set_extra ("icon", "singularity-music-playlist"); break;
            }
            return it;
        }

        private async MediaPage libraries (AccountLink l, Cancellable? c) throws Error {
            yield token (l, c);
            var o = yield api_get (l, "/Users/" + user_id (l) + "/Views", null, c);
            var page = new MediaPage (links ().size > 1 ? l.title : "Jellyfin");
            var items = Web.arr (o, "Items");
            bool want_audio = audio ();
            if (items != null) items.foreach_element ((a, i, n) => {
                var v = n.get_object ();
                string ctype = Web.str (v, "CollectionType");
                bool music = ctype == "music";
                bool video = ctype == "movies" || ctype == "tvshows" || ctype == "homevideos" || ctype == "musicvideos";
                if (want_audio ? !music : !video) return;
                var it = new MediaItem (ID, AccountLinks.node (l.id, "library", Web.str (v, "Id") + "|" + ctype), ItemKind.FOLDER, Web.str (v, "Name"));
                var tags = Web.obj (v, "ImageTags");
                if (tags != null && Web.str (tags, "Primary") != "") it.image_url = image_url (l, Web.str (v, "Id"), Web.str (tags, "Primary"));
                page.add (it);
            });
            page.add (folder (l, "playlists", "", _("Playlists")));
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token_s, Cancellable? c) throws Error {
            var page = new MediaPage (_("Results"));
            int offset = Paging.offset_of (token_s);
            foreach (var l in links ()) {
                yield token (l, c);
                var t = q (offset);
                t.insert ("searchTerm", query);
                t.insert ("Recursive", "true");
                t.insert ("IncludeItemTypes", audio () ? "MusicAlbum,MusicArtist,Audio,Playlist" : "Movie,Series,Episode,Video");
                var part = page_of (l, yield api_get (l, "/Users/" + user_id (l) + "/Items", t, c), _("Results"), offset);
                page.items.add_all (part.items);
                if (part.next_token != null) page.next_token = part.next_token;
            }
            return page;
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            string link_id, kind, jid;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out jid)) throw new MediaError.NOT_FOUND (_("Unknown item"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            string t = yield token (l, c);
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("static", "true");
            p.insert ("api_key", t);
            p.insert ("DeviceId", device_id (l));
            string path = kind == "track" ? "/Audio/" + jid + "/stream" : "/Videos/" + jid + "/stream";
            var pb = Playback.stream (base_url (l) + path + "?" + Web.query (p));
            if (_host != null) pb.set_header ("User-Agent", _host.user_agent);
            return pb;
        }

        private async void report (MediaItem item, string path, int64 position_ms, Cancellable? c) throws Error {
            if (item.source_id != ID) return;
            string link_id, kind, jid;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out jid)) return;
            var l = link (link_id);
            if (l == null) return;
            string t = yield token (l, c);
            var headers = new HashTable<string, string> (str_hash, str_equal);
            headers.insert ("X-Emby-Authorization", auth_header (l, t));
            headers.insert ("Authorization", auth_header (l, t));
            headers.insert ("X-Emby-Token", t);
            string body = "{\"ItemId\":\"%s\",\"PositionTicks\":%lld,\"CanSeek\":true}".printf (jid, position_ms * 10000);
            var reply = yield Web.request (session (), "POST", base_url (l) + path, headers, "application/json", new Bytes (body.data), c);
            Web.check (reply, "Jellyfin");
        }

        public async void now_playing (MediaItem item, Cancellable? c) throws Error {
            yield report (item, "/Sessions/Playing", 0, c);
        }

        public async void listened (MediaItem item, int64 played_ms, DateTime started, Cancellable? c) throws Error {
            yield report (item, "/Sessions/Playing/Stopped", item.duration_ms > 0 ? item.duration_ms : played_ms, c);
        }
    }
}


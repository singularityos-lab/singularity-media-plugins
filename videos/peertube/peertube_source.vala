using Singularity.MediaSources;

namespace Singularity.MediaPlugins {

    public class PeerTubeSource : Object, MediaSource, Browsable, Searchable, PlaybackResolver {
        public const string ID = "peertube";
        public const string URL_NODE = "url:";
        public const string DEFAULT_INSTANCES = "https://framatube.org";
        public const string DEFAULT_INDEX = "https://sepiasearch.org";
        private const int PAGE = 24;

        private MediaHost? _host = null;
        public string? instances_override = null;
        public string? index_override = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return "PeerTube"; } }
        public string icon_name { owned get { return "network-workgroup-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY; } }
        public string? account_capability { owned get { return null; } }
        public bool handles_urls { get { return true; } }

        public void activate (MediaHost host) {
            _host = host;
        }

        public void deactivate () {
            _host = null;
        }

        public Gee.List<string> instances () {
            var list = new Gee.ArrayList<string> ();
            string? v = instances_override;
            if (v == null && _host != null) v = _host.get_value (ID, "instances");
            if (v == null || v.strip () == "") v = DEFAULT_INSTANCES;
            foreach (string part in v.split_set ("\n ,;")) {
                string p = AccountLinks.trim_slash (part.strip ());
                if (p == "") continue;
                if (!p.has_prefix ("http://") && !p.has_prefix ("https://")) p = "https://" + p;
                if (!list.contains (p)) list.add (p);
            }
            return list;
        }

        private string search_index () {
            string? v = index_override;
            if (v == null && _host != null) v = _host.get_value (ID, "search-index");
            if (v == null) return DEFAULT_INDEX;
            return AccountLinks.trim_slash (v.strip ());
        }

        private static string key_of (string instance) {
            return Uri.escape_string (instance, null, false);
        }

        private static string instance_of (string key) {
            return Uri.unescape_string (key) ?? key;
        }

        private static string host_name (string instance) {
            try {
                return Uri.parse (instance, UriFlags.NONE).get_host () ?? instance;
            } catch (UriError e) {
                return instance;
            }
        }

        private async Json.Object get_json (string url, Cancellable? c) throws Error {
            var session = _host != null ? _host.session : new Soup.Session ();
            var reply = yield Web.request (session, "GET", url, null, null, null, c);
            if (reply.status < 200 || reply.status >= 300) {
                string detail = "";
                try {
                    var ep = new Json.Parser ();
                    ep.load_from_data (body_text (reply.body), -1);
                    var eo = ep.get_root ().get_object ();
                    detail = str (eo, "detail");
                    if (detail == "") detail = str (eo, "error");
                } catch (Error e) {
                }
                string host = host_name (url);
                if (reply.status == 404) throw new MediaError.NOT_FOUND (_("%s has no such video").printf (host));
                if (reply.status == 429) throw new MediaError.RATE_LIMITED (_("%s asks to wait before the next request").printf (host));
                if (reply.status >= 500) throw new MediaError.NETWORK (_("%s is not answering (HTTP %u)").printf (host, reply.status));
                throw new MediaError.PROTOCOL (detail != "" ? "%s: %s".printf (host, detail) : _("%s answered HTTP %u").printf (host, reply.status));
            }
            var parser = new Json.Parser ();
            parser.load_from_data (body_text (reply.body), -1);
            var node = parser.get_root ();
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) throw new MediaError.PROTOCOL (_("PeerTube sent an unexpected answer"));
            return node.get_object ();
        }

        private static string body_text (Bytes bytes) {
            if (bytes.get_size () == 0) return "";
            var sb = new StringBuilder.sized (bytes.get_size () + 1);
            sb.append_len ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            return sb.str;
        }

        private static string str (Json.Object? o, string key) {
            if (o == null || !o.has_member (key)) return "";
            var n = o.get_member (key);
            if (n.get_node_type () != Json.NodeType.VALUE || n.get_value ().type () != typeof (string)) return "";
            return n.get_string ();
        }

        private static int64 num (Json.Object? o, string key) {
            if (o == null || !o.has_member (key) || o.get_member (key).get_node_type () != Json.NodeType.VALUE) return 0;
            var v = o.get_member (key).get_value ();
            if (v.type () == typeof (int64)) return v.get_int64 ();
            if (v.type () == typeof (double)) return (int64) v.get_double ();
            return 0;
        }

        private static Json.Object? obj (Json.Object? o, string key) {
            if (o == null || !o.has_member (key) || o.get_member (key).get_node_type () != Json.NodeType.OBJECT) return null;
            return o.get_object_member (key);
        }

        private static string absolute (string instance, string path) {
            if (path == "") return "";
            if (path.has_prefix ("http://") || path.has_prefix ("https://")) return path;
            return instance + (path.has_prefix ("/") ? "" : "/") + path;
        }

        private MediaItem video_item (string instance, Json.Object v) {
            string origin = instance;
            var acc = obj (v, "account");
            string vhost = str (acc, "host");
            string url = str (v, "url");
            if (url != "") {
                try {
                    var u = Uri.parse (url, UriFlags.NONE);
                    origin = "%s://%s".printf (u.get_scheme (), u.get_host ()) + (u.get_port () > 0 ? ":%d".printf (u.get_port ()) : "");
                } catch (UriError e) {
                }
            } else if (vhost != "" && vhost != host_name (instance)) {
                origin = "https://" + vhost;
            }
            string uuid = str (v, "uuid");
            var it = new MediaItem (ID, AccountLinks.node (key_of (origin), "video", uuid), ItemKind.VIDEO, str (v, "name"));
            var ch = obj (v, "channel");
            it.subtitle = str (ch, "displayName");
            if (it.subtitle == "") it.subtitle = str (acc, "displayName");
            it.artist = it.subtitle;
            it.duration_ms = num (v, "duration") * 1000;
            string th = str (v, "thumbnailUrl");
            if (th == "") th = absolute (instance, str (v, "thumbnailPath"));
            it.image_url = th;
            it.external_url = url != "" ? url : origin + "/w/" + uuid;
            it.external_label = _("Open on %s").printf (host_name (origin));
            it.attribution = host_name (origin);
            string published = str (v, "publishedAt");
            if (published.length >= 4) it.year = int.parse (published.substring (0, 4));
            if (v.has_member ("isLive") && v.get_member ("isLive").get_node_type () == Json.NodeType.VALUE && v.get_boolean_member ("isLive")) it.set_extra ("live", "true");
            string ch_name = str (ch, "name");
            string ch_host = str (ch, "host");
            if (ch_name != "") it.set_extra ("channel", ch_host != "" ? ch_name + "@" + ch_host : ch_name);
            return it;
        }

        private MediaPage videos_page (string instance, Json.Object o, string title, int offset) {
            var page = new MediaPage (title);
            int total = (int) num (o, "total");
            page.total = total;
            int count = 0;
            if (o.has_member ("data") && o.get_member ("data").get_node_type () == Json.NodeType.ARRAY) {
                var arr = o.get_array_member ("data");
                for (uint i = 0; i < arr.get_length (); i++) {
                    var e = arr.get_element (i);
                    if (e.get_node_type () != Json.NodeType.OBJECT) continue;
                    page.add (video_item (instance, e.get_object ()));
                    count++;
                }
            }
            page.next_token = Paging.next_of (offset, (int) (o.has_member ("data") ? o.get_array_member ("data").get_length () : 0), total);
            return page;
        }

        private void add_sections (MediaPage page, string instance, bool prefix) {
            string[,] sections = {
                { "trending", _("Trending") },
                { "recent", _("Recently Added") },
                { "local", _("Local Videos") }
            };
            string host = host_name (instance);
            for (int i = 0; i < sections.length[0]; i++) {
                var it = new MediaItem (ID, AccountLinks.node (key_of (instance), sections[i, 0]), ItemKind.FOLDER,
                    prefix ? "%s, %s".printf (host, sections[i, 1]) : sections[i, 1]);
                it.attribution = host;
                page.add (it);
            }
        }

        public static bool parse_url (string url, out string instance, out string video_id) {
            instance = "";
            video_id = "";
            Uri u;
            try {
                u = Uri.parse (url.strip (), UriFlags.NONE);
            } catch (UriError e) {
                return false;
            }
            string scheme = u.get_scheme () ?? "";
            if (scheme != "https" && scheme != "http") return false;
            string path = u.get_path () ?? "";
            foreach (unowned string prefix in new string[] { "/w/", "/videos/watch/", "/videos/embed/" }) {
                if (path.has_prefix (prefix) && !path.has_prefix ("/w/p/")) {
                    video_id = path.substring (prefix.length);
                    break;
                }
            }
            int slash = video_id.index_of_char ('/');
            if (slash >= 0) video_id = video_id.substring (0, slash);
            if (video_id == "") return false;
            try {
                if (!new Regex ("^[A-Za-z0-9-]{8,40}$").match (video_id)) return false;
            } catch (RegexError e) {
                return false;
            }
            instance = "%s://%s".printf (scheme, u.get_host ()) + (u.get_port () > 0 ? ":%d".printf (u.get_port ()) : "");
            return true;
        }

        private async MediaPage open_url (string url, Cancellable? c) throws Error {
            string inst, vid;
            if (!parse_url (url, out inst, out vid)) throw new MediaError.NOT_FOUND (_("This is not a PeerTube address"));
            Json.Object v;
            try {
                v = yield get_json (inst + "/api/v1/videos/" + Uri.escape_string (vid, null, false), c);
            } catch (MediaError.PROTOCOL e) {
                throw new MediaError.NOT_FOUND (_("This is not a PeerTube address"));
            }
            if (str (v, "uuid") == "") throw new MediaError.NOT_FOUND (_("This is not a PeerTube address"));
            var page = new MediaPage ("PeerTube");
            page.add (video_item (inst, v));
            page.total = 1;
            return page;
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            if (node != null && node.has_prefix (URL_NODE)) return yield open_url (node.substring (URL_NODE.length), c);
            var list = instances ();
            if (node == null || node == "") {
                var page = new MediaPage (title);
                if (list.size == 1) {
                    add_sections (page, list[0], false);
                } else {
                    foreach (var inst in list) {
                        var it = new MediaItem (ID, AccountLinks.node (key_of (inst), "instance"), ItemKind.FOLDER, host_name (inst));
                        it.attribution = host_name (inst);
                        page.add (it);
                    }
                }
                page.total = page.items.size;
                return page;
            }
            string key, kind, rest;
            if (!AccountLinks.parse (node, out key, out kind, out rest)) throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            string inst = instance_of (key);
            int offset = Paging.offset_of (token);
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("start", offset.to_string ());
            p.insert ("count", PAGE.to_string ());
            p.insert ("nsfw", "false");
            string title_text;
            string path = "/api/v1/videos";
            switch (kind) {
                case "instance": {
                    var page = new MediaPage (host_name (inst));
                    add_sections (page, inst, false);
                    return page;
                }
                case "trending":
                    p.insert ("sort", "-trending");
                    title_text = _("Trending");
                    break;
                case "recent":
                    p.insert ("sort", "-publishedAt");
                    title_text = _("Recently Added");
                    break;
                case "local":
                    p.insert ("sort", "-publishedAt");
                    p.insert ("isLocal", "true");
                    title_text = _("Local Videos");
                    break;
                case "channel":
                    p.insert ("sort", "-publishedAt");
                    path = "/api/v1/video-channels/" + Uri.escape_string (rest, "@", false) + "/videos";
                    title_text = rest;
                    break;
                default:
                    throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            }
            var o = yield get_json (inst + path + "?" + Web.query (p), c);
            var page = videos_page (inst, o, title_text, offset);
            if (kind == "channel" && page.items.size > 0) page.title = page.items[0].subtitle;
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            int offset = Paging.offset_of (token);
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("search", query.strip ());
            p.insert ("start", offset.to_string ());
            p.insert ("count", PAGE.to_string ());
            p.insert ("nsfw", "false");
            string index = search_index ();
            string base_url = index;
            if (base_url == "") base_url = instances ()[0];
            var o = yield get_json (base_url + "/api/v1/search/videos?" + Web.query (p), c);
            return videos_page (base_url, o, _("Results for “%s”").printf (query.strip ()), offset);
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            string key, kind, uuid;
            if (!AccountLinks.parse (item.id, out key, out kind, out uuid) || kind != "video") throw new MediaError.NOT_FOUND (_("Unknown item"));
            string inst = instance_of (key);
            var v = yield get_json (inst + "/api/v1/videos/" + Uri.escape_string (uuid, null, false), c);
            string best = "";
            int64 best_res = -1;
            string hls = "";
            var candidates = new Gee.ArrayList<Json.Object> ();
            if (v.has_member ("files") && v.get_member ("files").get_node_type () == Json.NodeType.ARRAY) {
                var files = v.get_array_member ("files");
                for (uint i = 0; i < files.get_length (); i++) candidates.add (files.get_object_element (i));
            }
            if (v.has_member ("streamingPlaylists") && v.get_member ("streamingPlaylists").get_node_type () == Json.NodeType.ARRAY) {
                var sp = v.get_array_member ("streamingPlaylists");
                for (uint i = 0; i < sp.get_length (); i++) {
                    var pl = sp.get_object_element (i);
                    if (hls == "") hls = str (pl, "playlistUrl");
                    if (pl.has_member ("files") && pl.get_member ("files").get_node_type () == Json.NodeType.ARRAY) {
                        var files = pl.get_array_member ("files");
                        for (uint j = 0; j < files.get_length (); j++) candidates.add (files.get_object_element (j));
                    }
                }
            }
            foreach (var f in candidates) {
                if (f.has_member ("hasVideo") && !f.get_boolean_member ("hasVideo")) continue;
                if (f.has_member ("hasAudio") && !f.get_boolean_member ("hasAudio")) continue;
                int64 res = num (obj (f, "resolution"), "id");
                string u = str (f, "fileUrl");
                if (u != "" && res <= 1080 && res > best_res) {
                    best = u;
                    best_res = res;
                }
            }
            if (best == "") best = hls;
            if (best == "") return Playback.external (item.external_url != "" ? item.external_url : inst + "/w/" + uuid);
            var pb = Playback.stream (best);
            pb.mime_type = best.has_suffix (".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4";
            if (_host != null) pb.set_header ("User-Agent", _host.user_agent);
            return pb;
        }
    }
}

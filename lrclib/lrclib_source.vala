using Singularity.MediaSources;

namespace Singularity.MediaPlugins {

    public class LrclibSource : Object, MediaSource, MetadataProvider {
        public const string ID = "lrclib";
        public const string DEFAULT_URL = "https://lrclib.net";

        private MediaHost? _host = null;
        private int64 _blocked_until = 0;
        public string base_url { get; set; default = DEFAULT_URL; }

        construct {
            string? env = Environment.get_variable ("SINGULARITY_LRCLIB_URL");
            if (env != null && env != "") base_url = env;
        }

        public string id { owned get { return ID; } }
        public string title { owned get { return "LRCLIB"; } }
        public string icon_name { owned get { return "format-justify-left-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO; } }
        public SourceFeatures features { get { return SourceFeatures.METADATA | SourceFeatures.LYRICS; } }
        public string? account_capability { owned get { return null; } }

        public void activate (MediaHost host) {
            _host = host;
        }

        public void deactivate () {
            _host = null;
        }

        private string? cache_file (MediaItem item) {
            if (_host == null) return null;
            string key = "%s\n%s\n%s\n%lld".printf (item.artist.casefold (), item.title.casefold (), item.album.casefold (), item.duration_ms / 1000);
            return Path.build_filename (_host.cache_dir (ID), Checksum.compute_for_string (ChecksumType.MD5, key) + ".json");
        }

        private static Lyrics? from_json (Json.Object o) {
            if (Web.flag (o, "instrumental")) {
                var l = new Lyrics ();
                l.instrumental = true;
                l.attribution = "LRCLIB";
                return l;
            }
            string synced = Web.str (o, "syncedLyrics");
            string plain = Web.str (o, "plainLyrics");
            Lyrics? l = null;
            if (synced.strip () != "") l = Lyrics.parse_lrc (synced);
            else if (plain.strip () != "") l = Lyrics.from_plain (plain);
            if (l != null) l.attribution = "LRCLIB";
            return l;
        }

        public async Lyrics? lyrics (MediaItem item, Cancellable? c) throws Error {
            if (item.title == "" || item.artist == "") return null;
            string? cached = cache_file (item);
            if (cached != null && FileUtils.test (cached, FileTest.EXISTS)) {
                try {
                    string text;
                    FileUtils.get_contents (cached, out text);
                    if (text.strip () == "{}") return null;
                    var p = new Json.Parser ();
                    p.load_from_data (text);
                    return from_json (p.get_root ().get_object ());
                } catch (Error e) {
                }
            }
            if (get_real_time () < _blocked_until) return null;
            var session = _host != null ? _host.session : new Soup.Session ();
            var headers = new HashTable<string, string> (str_hash, str_equal);
            if (_host != null) headers.insert ("Lrclib-Client", _host.user_agent);
            var q = new HashTable<string, string> (str_hash, str_equal);
            q.insert ("artist_name", item.artist);
            q.insert ("track_name", item.title);
            if (item.album != "") q.insert ("album_name", item.album);
            if (item.duration_ms > 0) q.insert ("duration", (item.duration_ms / 1000).to_string ());
            var reply = yield Web.request (session, "GET", base_url + "/api/get?" + Web.query (q), headers, null, null, c);
            Json.Object? found = null;
            if (reply.status == 200) {
                found = reply.json ().get_object ();
            } else if (reply.status == 404) {
                var sq = new HashTable<string, string> (str_hash, str_equal);
                sq.insert ("artist_name", item.artist);
                sq.insert ("track_name", item.title);
                var sr = yield Web.request (session, "GET", base_url + "/api/search?" + Web.query (sq), headers, null, null, c);
                if (sr.status == 200) {
                    var arr = sr.json ().get_array ();
                    for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                        var o = arr.get_object_element (i);
                        int64 d = (int64) Web.num (o, "duration");
                        if (item.duration_ms > 0 && d > 0 && (d - item.duration_ms / 1000).abs () > 3) continue;
                        found = o;
                        if (Web.str (o, "syncedLyrics") != "") break;
                    }
                }
            } else {
                if (reply.status == 429) _blocked_until = get_real_time () + (int64) int.max (reply.retry_after (), 30) * 1000000;
                Web.check (reply, "LRCLIB");
            }
            if (cached != null) {
                try {
                    string text = "{}";
                    if (found != null) {
                        var n = new Json.Node (Json.NodeType.OBJECT);
                        n.set_object (found);
                        var g = new Json.Generator ();
                        g.set_root (n);
                        text = g.to_data (null);
                    }
                    FileUtils.set_contents (cached, text);
                } catch (Error e) {
                }
            }
            return found != null ? from_json (found) : null;
        }

        public async MediaItem? enrich (MediaItem item, Cancellable? c) throws Error {
            return null;
        }
    }
}

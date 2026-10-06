using Singularity.MediaSources;

namespace Singularity.MediaPlugins {

    public class MusicBrainzSource : Object, MediaSource, MetadataProvider {
        public const string ID = "musicbrainz";
        public const string DEFAULT_URL = "https://musicbrainz.org";
        public const string COVERS_URL = "https://coverartarchive.org";

        private MediaHost? _host = null;
        private int64 _next_request = 0;
        private int64 _blocked_until = 0;
        public string base_url { get; set; default = DEFAULT_URL; }
        public string covers_url { get; set; default = COVERS_URL; }
        public int64 min_interval_us { get; set; default = 1100000; }

        construct {
            string? env = Environment.get_variable ("SINGULARITY_MUSICBRAINZ_URL");
            if (env != null && env != "") base_url = env;
            env = Environment.get_variable ("SINGULARITY_COVERART_URL");
            if (env != null && env != "") covers_url = env;
        }

        public string id { owned get { return ID; } }
        public string title { owned get { return "MusicBrainz"; } }
        public string icon_name { owned get { return "media-optical-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO; } }
        public SourceFeatures features { get { return SourceFeatures.METADATA; } }
        public string? account_capability { owned get { return null; } }

        public void activate (MediaHost host) {
            _host = host;
        }

        public void deactivate () {
            _host = null;
        }

        public async Lyrics? lyrics (MediaItem item, Cancellable? c) throws Error {
            return null;
        }

        private async void pace (Cancellable? c) throws Error {
            int64 now = get_monotonic_time ();
            if (now < _next_request) {
                uint wait_ms = (uint) ((_next_request - now) / 1000);
                Timeout.add (wait_ms + 1, pace.callback);
                yield;
                if (c != null && c.is_cancelled ()) throw new IOError.CANCELLED ("Cancelled");
            }
            _next_request = get_monotonic_time () + min_interval_us;
        }

        private static string quote (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"") + "\"";
        }

        private string? cache_file (MediaItem item) {
            if (_host == null) return null;
            string key = "%s\n%s\n%s".printf (item.artist.casefold (), item.title.casefold (), item.album.casefold ());
            return Path.build_filename (_host.cache_dir (ID), Checksum.compute_for_string (ChecksumType.MD5, key) + ".json");
        }

        private MediaItem apply (MediaItem item, Json.Object rec) {
            var out_item = item.copy ();
            out_item.set_extra ("musicbrainz-recording", Web.str (rec, "id"));
            var credits = Web.arr (rec, "artist-credit");
            if (out_item.artist == "" && credits != null && credits.get_length () > 0) out_item.artist = Web.str (credits.get_object_element (0), "name");
            var releases = Web.arr (rec, "releases");
            if (releases != null && releases.get_length () > 0) {
                Json.Object? pick = null;
                for (uint i = 0; i < releases.get_length (); i++) {
                    var r = releases.get_object_element (i);
                    if (item.album != "" && Web.str (r, "title").casefold () == item.album.casefold ()) {
                        pick = r;
                        break;
                    }
                }
                if (pick == null) pick = releases.get_object_element (0);
                string rid = Web.str (pick, "id");
                out_item.set_extra ("musicbrainz-release", rid);
                if (out_item.album == "") out_item.album = Web.str (pick, "title");
                string date = Web.str (pick, "date");
                if (out_item.year == 0 && date.length >= 4) out_item.year = int.parse (date.substring (0, 4));
                if (out_item.image_url == "" && rid != "") out_item.image_url = covers_url + "/release/" + rid + "/front-500";
            }
            return out_item;
        }

        public async MediaItem? enrich (MediaItem item, Cancellable? c) throws Error {
            if (item.title == "" || item.artist == "") return null;
            string? cached = cache_file (item);
            if (cached != null && FileUtils.test (cached, FileTest.EXISTS)) {
                try {
                    string text;
                    FileUtils.get_contents (cached, out text);
                    if (text.strip () == "{}") return null;
                    var p = new Json.Parser ();
                    p.load_from_data (text);
                    return apply (item, p.get_root ().get_object ());
                } catch (Error e) {
                }
            }
            if (get_real_time () < _blocked_until) return null;
            yield pace (c);
            string query = "recording:%s AND artist:%s".printf (quote (item.title), quote (item.artist));
            if (item.album != "") query += " AND release:%s".printf (quote (item.album));
            var q = new HashTable<string, string> (str_hash, str_equal);
            q.insert ("query", query);
            q.insert ("fmt", "json");
            q.insert ("limit", "3");
            var headers = new HashTable<string, string> (str_hash, str_equal);
            headers.insert ("User-Agent", _host != null ? _host.user_agent : "Singularity-Music/0.1 ( https://github.com/singularityos-lab )");
            var reply = yield Web.request (_host != null ? _host.session : new Soup.Session (), "GET", base_url + "/ws/2/recording/?" + Web.query (q), headers, null, null, c);
            if (reply.status == 503 || reply.status == 429) {
                _blocked_until = get_real_time () + (int64) int.max (reply.retry_after (), 5) * 1000000;
                throw new MediaError.RATE_LIMITED ("MusicBrainz asks to wait");
            }
            Web.check (reply, "MusicBrainz");
            var recs = Web.arr (reply.json ().get_object (), "recordings");
            Json.Object? best = null;
            if (recs != null) {
                for (uint i = 0; i < recs.get_length (); i++) {
                    var r = recs.get_object_element (i);
                    if (Web.num (r, "score") < 80) continue;
                    best = r;
                    break;
                }
            }
            if (cached != null) {
                try {
                    string text = "{}";
                    if (best != null) {
                        var n = new Json.Node (Json.NodeType.OBJECT);
                        n.set_object (best);
                        var g = new Json.Generator ();
                        g.set_root (n);
                        text = g.to_data (null);
                    }
                    FileUtils.set_contents (cached, text);
                } catch (Error e) {
                }
            }
            return best != null ? apply (item, best) : null;
        }
    }
}

using Singularity.MediaSources;
using Singularity.Accounts;

namespace Singularity.MediaPlugins {

    public class ListenBrainzSource : Object, MediaSource, Scrobbler {
        public const string ID = "listenbrainz";
        public const int BATCH = 100;

        private MediaHost? _host = null;
        private int64 _blocked_until = 0;
        private bool _flushing = false;
        public Gee.List<AccountLink>? links_override = null;
        public string client_version = "0.1";

        public string id { owned get { return ID; } }
        public string title { owned get { return "ListenBrainz"; } }
        public string icon_name { owned get { return "document-open-recent-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO; } }
        public SourceFeatures features { get { return SourceFeatures.SCROBBLE; } }
        public string? account_capability { owned get { return "music"; } }
        public bool enabled { get { return links ().size > 0; } }

        public void activate (MediaHost host) {
            _host = host;
        }

        public void deactivate () {
            _host = null;
        }

        public Gee.List<AccountLink> links () {
            if (links_override != null) return links_override;
            if (_host == null) return new Gee.ArrayList<AccountLink> ();
            return AccountLinks.find (_host, Capability.MUSIC, "listenbrainz");
        }

        private static string api (AccountLink l) {
            return AccountLinks.trim_slash (l.endpoint ("listenbrainz", l.server != "" ? l.server : "https://api.listenbrainz.org"));
        }

        public Json.Node metadata (MediaItem item) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("artist_name").add_string_value (item.artist != "" ? item.artist : item.subtitle);
            b.set_member_name ("track_name").add_string_value (item.title);
            if (item.album != "") b.set_member_name ("release_name").add_string_value (item.album);
            b.set_member_name ("additional_info");
            b.begin_object ();
            if (item.duration_ms > 0) b.set_member_name ("duration_ms").add_int_value (item.duration_ms);
            if (item.track_number > 0) b.set_member_name ("tracknumber").add_int_value (item.track_number);
            string? mbid = item.get_extra ("musicbrainz-recording");
            if (mbid != null) b.set_member_name ("recording_mbid").add_string_value (mbid);
            b.set_member_name ("media_player").add_string_value ("Singularity Music");
            b.set_member_name ("submission_client").add_string_value ("Singularity Music");
            b.set_member_name ("submission_client_version").add_string_value (client_version);
            if (item.external_url.has_prefix ("http")) b.set_member_name ("origin_url").add_string_value (item.external_url);
            b.end_object ();
            b.end_object ();
            return b.get_root ();
        }

        private static string body (string type, Gee.List<Json.Node> payload) {
            var root = new Json.Object ();
            root.set_string_member ("listen_type", type);
            var arr = new Json.Array ();
            foreach (var n in payload) arr.add_element (n.copy ());
            root.set_array_member ("payload", arr);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (root);
            var g = new Json.Generator ();
            g.set_root (node);
            return g.to_data (null);
        }

        private async void submit (AccountLink l, string payload, Cancellable? c) throws Error {
            if (get_real_time () < _blocked_until) throw new MediaError.RATE_LIMITED ("ListenBrainz asks to wait");
            var creds = yield l.credentials (Capability.MUSIC);
            var headers = new HashTable<string, string> (str_hash, str_equal);
            headers.insert ("Authorization", "Token " + creds.secret);
            var reply = yield Web.request (_host != null ? _host.session : new Soup.Session (), "POST", api (l) + "/1/submit-listens", headers,
                "application/json", new Bytes (payload.data), c);
            if (reply.status == 429) {
                int wait = reply.retry_after ();
                string? reset = reply.headers.get_one ("X-RateLimit-Reset-In");
                if (wait < 0 && reset != null) wait = int.parse (reset);
                _blocked_until = get_real_time () + (int64) int.max (wait, 10) * 1000000;
            }
            if (reply.status == 401) yield l.report_problem (Capability.MUSIC);
            Web.check (reply, "ListenBrainz");
        }

        public async void now_playing (MediaItem item, Cancellable? c) throws Error {
            var payload = new Gee.ArrayList<Json.Node> ();
            var entry = new Json.Object ();
            entry.set_member ("track_metadata", metadata (item));
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (entry);
            payload.add (node);
            foreach (var l in links ()) yield submit (l, body ("playing_now", payload), c);
        }

        public Json.Node listen (MediaItem item, DateTime started) {
            var entry = new Json.Object ();
            entry.set_int_member ("listened_at", started.to_unix ());
            entry.set_member ("track_metadata", metadata (item));
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (entry);
            return node;
        }

        public async void listened (MediaItem item, int64 played_ms, DateTime started, Cancellable? c) throws Error {
            var node = listen (item, started);
            foreach (var l in links ()) {
                var one = new Gee.ArrayList<Json.Node> ();
                one.add (node);
                try {
                    yield submit (l, body ("single", one), c);
                } catch (MediaError.AUTH_FAILED e) {
                    throw e;
                } catch (Error e) {
                    enqueue (l, node);
                    throw e;
                }
                yield flush (l, c);
            }
        }

        private string queue_path (AccountLink l) {
            string dir = _host != null ? _host.cache_dir (ID) : Environment.get_tmp_dir ();
            return Path.build_filename (dir, "queue-" + Checksum.compute_for_string (ChecksumType.MD5, l.id) + ".jsonl");
        }

        public int pending (AccountLink l) {
            try {
                string text;
                FileUtils.get_contents (queue_path (l), out text);
                int n = 0;
                foreach (var line in text.split ("\n")) if (line.strip () != "") n++;
                return n;
            } catch (Error e) {
                return 0;
            }
        }

        private void enqueue (AccountLink l, Json.Node node) {
            var g = new Json.Generator ();
            g.set_root (node);
            try {
                var f = File.new_for_path (queue_path (l));
                var s = f.append_to (FileCreateFlags.PRIVATE);
                s.write ((g.to_data (null) + "\n").data);
                s.close ();
            } catch (Error e) {
                warning ("listenbrainz: %s", e.message);
            }
        }

        public async void flush (AccountLink l, Cancellable? c) {
            if (_flushing) return;
            string text;
            try {
                if (!FileUtils.get_contents (queue_path (l), out text)) return;
            } catch (Error e) {
                return;
            }
            _flushing = true;
            var nodes = new Gee.ArrayList<Json.Node> ();
            foreach (var line in text.split ("\n")) {
                if (line.strip () == "") continue;
                try {
                    var p = new Json.Parser ();
                    p.load_from_data (line);
                    nodes.add (p.get_root ().copy ());
                } catch (Error e) {
                }
            }
            int sent = 0;
            while (sent < nodes.size) {
                var batch = nodes.slice (sent, int.min (sent + BATCH, nodes.size));
                try {
                    yield submit (l, body ("import", batch), c);
                } catch (Error e) {
                    break;
                }
                sent += batch.size;
            }
            var rest = new StringBuilder ();
            for (int i = sent; i < nodes.size; i++) {
                var g = new Json.Generator ();
                g.set_root (nodes[i]);
                rest.append (g.to_data (null)).append_c ('\n');
            }
            try {
                if (rest.len == 0) FileUtils.remove (queue_path (l));
                else FileUtils.set_contents (queue_path (l), rest.str);
            } catch (Error e) {
            }
            _flushing = false;
        }
    }
}

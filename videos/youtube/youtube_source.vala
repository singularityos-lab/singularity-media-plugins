using Singularity.MediaSources;
using Singularity.Accounts;

namespace Singularity.MediaPlugins {

    public class YouTubeSource : Object, MediaSource, SourceAvailability, Browsable, Searchable, PlaybackResolver {
        public const string ID = "youtube";
        public const string URL_NODE = "url:";
        public const string DEFAULT_API = "https://www.googleapis.com/youtube/v3/";
        public const string DEFAULT_ORIGIN = "https://videos.sinty.dev";
        public const int SEARCH_COST = 100;
        public const int DAILY_UNITS = 10000;
        private const int PAGE = 25;
        private const int64 SEARCH_TTL = 24 * 3600;
        private const int64 LIST_TTL = 15 * 60;
        private const int64 DETAILS_TTL = 30 * 24 * 3600;

        private MediaHost? _host = null;
        private ulong _accounts_handler = 0;
        public Gee.List<AccountLink>? links_override = null;
        public string? key_override = null;
        public string[]? config_paths_override = null;
        public bool embed_override_disabled = false;

        public string id { owned get { return ID; } }
        public string title { owned get { return "YouTube"; } }
        public string icon_name { owned get { return "video-x-generic-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.EMBED; } }
        public string? account_capability { owned get { return "videos"; } }
        public bool handles_urls { get { return true; } }

        public bool available { get { return links ().size > 0 || api_key () != ""; } }
        public string unavailable_reason {
            owned get { return _("Add your Google account in Online Accounts and switch on Videos, or enter a personal YouTube API key in Settings."); }
        }

        public void activate (MediaHost host) {
            _host = host;
            _accounts_handler = host.accounts_changed.connect (() => changed ());
        }

        public void deactivate () {
            if (_host != null && _accounts_handler != 0) _host.disconnect (_accounts_handler);
            _accounts_handler = 0;
            _host = null;
        }

        public Gee.List<AccountLink> links () {
            if (links_override != null) return links_override;
            if (_host == null) return new Gee.ArrayList<AccountLink> ();
            return AccountLinks.find (_host, Capability.VIDEOS, "google");
        }

        private AccountLink? link (string id) {
            foreach (var l in links ()) if (l.id == id) return l;
            return null;
        }

        public string api_key () {
            if (key_override != null) return key_override;
            string? v = _host != null ? _host.get_value (ID, "api-key") : null;
            if (v != null && v.strip () != "") return v.strip ();
            string[] paths = config_paths_override ?? config_paths ();
            foreach (var p in paths) {
                string k = key_from_file (p);
                if (k != "") return k;
            }
            return "";
        }

        public static string[] config_paths () {
            string[] paths = { Path.build_filename (Environment.get_user_config_dir (), "singularity", "accounts", "oauth-clients.json") };
            paths += "/etc/singularity/oauth-clients.json";
            foreach (unowned string dir in Environment.get_system_data_dirs ()) paths += Path.build_filename (dir, "singularity", "oauth-clients.json");
            paths += "/opt/local/share/singularity/oauth-clients.json";
            return paths;
        }

        public static string key_from_file (string path) {
            if (!FileUtils.test (path, FileTest.EXISTS)) return "";
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return "";
                var all = root.get_object ();
                if (!all.has_member ("youtube") || all.get_member ("youtube").get_node_type () != Json.NodeType.OBJECT) return "";
                var o = all.get_object_member ("youtube");
                if (!o.has_member ("api_key")) return "";
                return o.get_string_member ("api_key").strip ();
            } catch (Error e) {
                return "";
            }
        }

        private string api_base (AccountLink? l) {
            string? v = _host != null ? _host.get_value (ID, "api-base") : null;
            string b = DEFAULT_API;
            if (v != null && v != "") b = v;
            else if (l != null) b = l.endpoint ("youtube", DEFAULT_API);
            if (!b.has_suffix ("/")) b = b + "/";
            return b;
        }

        public string origin () {
            string? v = _host != null ? _host.get_value (ID, "origin") : null;
            string o = DEFAULT_ORIGIN;
            if (v != null && v != "") o = AccountLinks.trim_slash (v);
            return o;
        }

        private static string today () {
            return new DateTime.now_utc ().format ("%Y-%m-%d");
        }

        public int units_used () {
            string? v = _host != null ? _host.get_value (ID, "units-" + today ()) : null;
            return v != null ? int.parse (v) : 0;
        }

        private void spend (int units) {
            if (_host == null) return;
            string key = "units-" + today ();
            _host.set_value (ID, key, (units_used () + units).to_string ());
            string? last = _host.get_value (ID, "units-day");
            if (last != null && last != today ()) _host.set_value (ID, "units-" + last, null);
            _host.set_value (ID, "units-day", today ());
        }

        private string? cache_file (string what) {
            if (_host == null) return null;
            return Path.build_filename (_host.cache_dir (ID), Checksum.compute_for_string (ChecksumType.SHA256, what) + ".json");
        }

        private string? cached (string what, int64 ttl) {
            string? f = cache_file (what);
            if (f == null) return null;
            try {
                var info = File.new_for_path (f).query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                var mod = info.get_modification_date_time ();
                if (mod == null || new DateTime.now_utc ().difference (mod) / TimeSpan.SECOND > ttl) return null;
                string text;
                FileUtils.get_contents (f, out text);
                return text;
            } catch (Error e) {
                return null;
            }
        }

        private void store (string what, string text) {
            string? f = cache_file (what);
            if (f == null) return;
            try {
                FileUtils.set_contents (f, text);
            } catch (Error e) {
            }
        }

        private async Json.Object call (AccountLink? l, string method, HashTable<string, string> params, int cost, int64 ttl, Cancellable? c) throws Error {
            string cache_key = (l != null ? l.id : "key") + "|" + method + "?" + Web.query (params);
            string? hit = ttl > 0 ? cached (cache_key, ttl) : null;
            string text;
            if (hit != null) {
                text = hit;
            } else {
                var headers = new HashTable<string, string> (str_hash, str_equal);
                var q = new HashTable<string, string> (str_hash, str_equal);
                params.foreach ((k, v) => q.insert (k, v));
                if (l != null) {
                    Singularity.Accounts.AccountCredentials cred;
                    try {
                        cred = yield l.credentials (Capability.VIDEOS);
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (MediaError e) {
                        throw e;
                    } catch (Error e) {
                        throw new MediaError.NEEDS_ACCOUNT (_("Sign in to Google again in Online Accounts to use YouTube (%s)").printf (e.message));
                    }
                    string? auth = cred.authorization_header ();
                    if (auth == null) throw new MediaError.AUTH_FAILED (_("This Google sign-in cannot be used for YouTube"));
                    headers.insert ("Authorization", auth);
                } else {
                    string key = api_key ();
                    if (key == "") throw new MediaError.NOT_CONFIGURED (unavailable_reason);
                    q.insert ("key", key);
                }
                var session = _host != null ? _host.session : new Soup.Session ();
                var reply = yield Web.request (session, "GET", api_base (l) + method + "?" + Web.query (q), headers, null, null, c);
                spend (cost);
                if (reply.status < 200 || reply.status >= 300) yield fail (l, reply);
                text = body_text (reply.body);
                if (ttl > 0) store (cache_key, text);
            }
            var parser = new Json.Parser ();
            parser.load_from_data (text, -1);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) throw new MediaError.PROTOCOL (_("YouTube sent an unexpected answer"));
            return root.get_object ();
        }

        public static string body_text (Bytes bytes) {
            if (bytes.get_size () == 0) return "";
            var sb = new StringBuilder.sized (bytes.get_size () + 1);
            sb.append_len ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            return sb.str;
        }

        public class ApiError : Object {
            public uint status;
            public string message = "";
            public Gee.HashSet<string> reasons = new Gee.HashSet<string> ();

            public bool has (string reason) {
                return reasons.contains (reason);
            }
        }

        public static ApiError parse_error (uint status, string body) {
            var err = new ApiError ();
            err.status = status;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (body, -1);
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var o = obj (root.get_object (), "error");
                    err.message = str (o, "message");
                    if (str (o, "status") != "") err.reasons.add (str (o, "status"));
                    foreach (unowned string list in new string[] { "errors", "details" }) {
                        if (o == null || !o.has_member (list) || o.get_member (list).get_node_type () != Json.NodeType.ARRAY) continue;
                        var arr = o.get_array_member (list);
                        for (uint i = 0; i < arr.get_length (); i++) {
                            var e = arr.get_element (i);
                            if (e.get_node_type () != Json.NodeType.OBJECT) continue;
                            string r = str (e.get_object (), "reason");
                            if (r != "") err.reasons.add (r);
                        }
                    }
                }
            } catch (Error e) {
            }
            return err;
        }

        public static MediaError error_for (ApiError e, bool with_account) {
            string detail = e.message != "" ? e.message : _("HTTP %u").printf (e.status);
            if (e.has ("quotaExceeded") || e.has ("dailyLimitExceeded") || e.has ("RATE_LIMIT_EXCEEDED") || e.has ("rateLimitExceeded") || e.status == 429)
                return new MediaError.RATE_LIMITED (_("The daily YouTube quota is used up. It resets at midnight Pacific Time."));
            if (e.has ("API_KEY_INVALID") || e.has ("keyInvalid"))
                return new MediaError.NOT_CONFIGURED (_("The YouTube API key is not valid. Check it in the Videos settings."));
            if (e.has ("API_KEY_SERVICE_BLOCKED") || e.has ("API_KEY_HTTP_REFERRER_BLOCKED") || e.has ("API_KEY_IP_ADDRESS_BLOCKED") || e.has ("API_KEY_ANDROID_APP_BLOCKED") || e.has ("API_KEY_IOS_APP_BLOCKED"))
                return new MediaError.NOT_CONFIGURED (_("The YouTube API key is restricted and cannot be used by this computer. Allow the YouTube Data API v3 for it, without website restrictions."));
            if (e.has ("SERVICE_DISABLED") || e.has ("accessNotConfigured"))
                return new MediaError.NOT_CONFIGURED (_("The YouTube Data API v3 is not enabled in the Google project of this %s.").printf (with_account ? _("sign-in") : _("key")));
            if (e.has ("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || e.has ("insufficientPermissions"))
                return new MediaError.NEEDS_ACCOUNT (_("Google did not allow YouTube for this account. Switch on Videos for it in Online Accounts and sign in again."));
            if (e.status == 401 && with_account)
                return new MediaError.AUTH_FAILED (_("Google refused the sign-in. Sign in again in Online Accounts."));
            if (e.status == 401)
                return new MediaError.NOT_CONFIGURED (_("YouTube needs a Google account or an API key."));
            if (e.has ("forbidden") && !with_account)
                return new MediaError.NOT_CONFIGURED (_("YouTube needs a Google account or an API key."));
            if (e.has ("youtubeSignupRequired"))
                return new MediaError.NEEDS_ACCOUNT (_("This Google account has no YouTube channel yet."));
            if (e.has ("subscriptionForbidden") || e.has ("playlistForbidden") || e.has ("forbidden"))
                return new MediaError.AUTH_FAILED (_("YouTube does not allow this list: %s").printf (detail));
            if (e.has ("channelNotFound") || e.has ("playlistNotFound") || e.has ("videoNotFound") || e.status == 404)
                return new MediaError.NOT_FOUND (_("YouTube could not find it: %s").printf (detail));
            if (e.status >= 500) return new MediaError.NETWORK (_("YouTube is not answering: %s").printf (detail));
            return new MediaError.PROTOCOL (_("YouTube refused the request: %s").printf (detail));
        }

        private async void fail (AccountLink? l, WebReply reply) throws Error {
            var e = parse_error (reply.status, body_text (reply.body));
            var err = error_for (e, l != null);
            if (l != null && (err is MediaError.AUTH_FAILED || err is MediaError.NEEDS_ACCOUNT) && e.status == 401) yield l.report_problem (Capability.VIDEOS);
            throw err;
        }

        private static string str (Json.Object? o, string key) {
            if (o == null || !o.has_member (key)) return "";
            var n = o.get_member (key);
            if (n.get_node_type () != Json.NodeType.VALUE) return "";
            return n.get_value ().type () == typeof (string) ? n.get_string () : "";
        }

        private static Json.Object? obj (Json.Object? o, string key) {
            if (o == null || !o.has_member (key) || o.get_member (key).get_node_type () != Json.NodeType.OBJECT) return null;
            return o.get_object_member (key);
        }

        private static string thumb (Json.Object? snippet) {
            var t = obj (snippet, "thumbnails");
            foreach (string size in new string[] { "high", "medium", "standard", "default" }) {
                string u = str (obj (t, size), "url");
                if (u != "") return u;
            }
            return "";
        }

        public static int64 parse_duration (string iso) {
            if (!iso.has_prefix ("P")) return 0;
            int64 total = 0;
            int64 num = 0;
            bool time = false;
            for (int i = 1; i < iso.length; i++) {
                char ch = iso[i];
                if (ch >= '0' && ch <= '9') {
                    num = num * 10 + (ch - '0');
                    continue;
                }
                switch (ch) {
                    case 'T': time = true; break;
                    case 'D': total += num * 86400; break;
                    case 'H': total += num * 3600; break;
                    case 'M': total += time ? num * 60 : num * 2592000; break;
                    case 'S': total += num; break;
                    case 'W': total += num * 604800; break;
                    default: break;
                }
                num = 0;
            }
            return total * 1000;
        }

        public static string watch_url (string video_id) {
            return "https://www.youtube.com/watch?v=" + Uri.escape_string (video_id, null, false);
        }

        private MediaItem video_item (string link_id, string vid, Json.Object? snippet) {
            var it = new MediaItem (ID, AccountLinks.node (link_id, "video", vid), ItemKind.VIDEO, str (snippet, "title"));
            string channel = str (snippet, "videoOwnerChannelTitle");
            if (channel == "") channel = str (snippet, "channelTitle");
            it.subtitle = channel;
            it.artist = channel;
            it.image_url = thumb (snippet);
            it.external_url = watch_url (vid);
            it.external_label = _("Open on YouTube");
            it.attribution = "YouTube";
            it.set_extra ("video-id", vid);
            string published = str (snippet, "publishedAt");
            if (published.length >= 4) it.year = int.parse (published.substring (0, 4));
            return it;
        }

        private async void add_durations (AccountLink? l, Gee.List<MediaItem> items, Cancellable? c) {
            string[] ids = {};
            var by_id = new Gee.HashMap<string, MediaItem> ();
            foreach (var it in items) {
                string? vid = it.get_extra ("video-id");
                if (vid == null || it.duration_ms > 0) continue;
                ids += vid;
                by_id[vid] = it;
            }
            if (ids.length == 0) return;
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("part", "contentDetails,status");
            p.insert ("id", string.joinv (",", ids));
            try {
                var o = yield call (l, "videos", p, 1, DETAILS_TTL, c);
                var arr = o.get_array_member ("items");
                for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                    var v = arr.get_object_element (i);
                    var it = by_id[str (v, "id")];
                    if (it == null) continue;
                    it.duration_ms = parse_duration (str (obj (v, "contentDetails"), "duration"));
                    var status = obj (v, "status");
                    if (status != null && status.has_member ("embeddable") && !status.get_boolean_member ("embeddable")) it.set_extra ("embeddable", "false");
                }
            } catch (Error e) {
            }
        }

        private static MediaPage page_from (Json.Object o, string title) {
            var page = new MediaPage (title);
            string next = str (o, "nextPageToken");
            page.next_token = next != "" ? next : null;
            var info = obj (o, "pageInfo");
            if (info != null && info.has_member ("totalResults")) page.total = (int) info.get_int_member ("totalResults");
            return page;
        }

        private MediaPage not_ready () {
            var page = new MediaPage (title);
            page.notice = unavailable_reason;
            page.action_label = _("Online Accounts");
            page.action_uri = "settings:accounts";
            return page;
        }

        private void add_sections (MediaPage page, AccountLink l, string? label_prefix) {
            string[,] sections = {
                { "subscriptions", _("Subscriptions") },
                { "playlists", _("Your Playlists") },
                { "liked", _("Liked Videos") }
            };
            for (int i = 0; i < sections.length[0]; i++) {
                var it = new MediaItem (ID, AccountLinks.node (l.id, sections[i, 0]), ItemKind.FOLDER,
                    label_prefix != null ? "%s, %s".printf (label_prefix, sections[i, 1]) : sections[i, 1]);
                it.attribution = "YouTube";
                page.add (it);
            }
        }

        public static bool parse_url (string url, out string video_id, out string playlist_id, out int64 start_ms) {
            video_id = "";
            playlist_id = "";
            start_ms = 0;
            Uri u;
            try {
                u = Uri.parse (url.strip (), UriFlags.NONE);
            } catch (UriError e) {
                return false;
            }
            string host = (u.get_host () ?? "").down ();
            if (host.has_prefix ("www.")) host = host.substring (4);
            if (host.has_prefix ("m.")) host = host.substring (2);
            string path = u.get_path () ?? "";
            var q = new HashTable<string, string> (str_hash, str_equal);
            string? query = u.get_query ();
            if (query != null) {
                try {
                    q = Uri.parse_params (query, -1, "&", UriParamsFlags.NONE);
                } catch (UriError e) {
                }
            }
            if (host == "youtu.be") {
                video_id = path.has_prefix ("/") ? path.substring (1) : path;
            } else if (host == "youtube.com" || host == "music.youtube.com" || host == "youtube-nocookie.com") {
                if (path == "/watch") video_id = q.lookup ("v") ?? "";
                else {
                    foreach (unowned string prefix in new string[] { "/shorts/", "/embed/", "/live/", "/v/" }) {
                        if (path.has_prefix (prefix)) video_id = path.substring (prefix.length);
                    }
                }
                if (q.lookup ("list") != null) playlist_id = q.lookup ("list");
            } else {
                return false;
            }
            int slash = video_id.index_of_char ('/');
            if (slash >= 0) video_id = video_id.substring (0, slash);
            if (video_id != "") {
                try {
                    if (!new Regex ("^[A-Za-z0-9_-]{6,20}$").match (video_id)) video_id = "";
                } catch (RegexError e) {
                    video_id = "";
                }
            }
            string? t = q.lookup ("t") ?? q.lookup ("start");
            if (t != null) start_ms = parse_offset (t);
            return video_id != "" || playlist_id != "";
        }

        private static int64 parse_offset (string t) {
            int64 total = 0;
            int64 num = 0;
            bool unit = false;
            for (int i = 0; i < t.length; i++) {
                char ch = t[i];
                if (ch >= '0' && ch <= '9') {
                    num = num * 10 + (ch - '0');
                    continue;
                }
                unit = true;
                if (ch == 'h') total += num * 3600;
                else if (ch == 'm') total += num * 60;
                else if (ch == 's') total += num;
                num = 0;
            }
            if (!unit) total = num;
            else total += num;
            return total * 1000;
        }

        private async MediaPage open_url (string url, Cancellable? c) throws Error {
            string vid, list;
            int64 start;
            if (!parse_url (url, out vid, out list, out start)) throw new MediaError.NOT_FOUND (_("This is not a YouTube address"));
            var all = links ();
            AccountLink? l = all.size > 0 ? all[0] : null;
            string link_id = l != null ? l.id : "key";
            bool api = l != null || api_key () != "";
            if (vid == "" && list != "") {
                if (!api) throw new MediaError.NOT_CONFIGURED (_("Opening a YouTube playlist needs a Google account or an API key."));
                return yield playlist_page (l, link_id, list, null, c);
            }
            var page = new MediaPage ("YouTube");
            MediaItem it;
            if (api) {
                var p = new HashTable<string, string> (str_hash, str_equal);
                p.insert ("part", "snippet,contentDetails,status");
                p.insert ("id", vid);
                try {
                    var o = yield call (l, "videos", p, 1, DETAILS_TTL, c);
                    var arr = o.get_array_member ("items");
                    if (arr == null || arr.get_length () == 0) throw new MediaError.NOT_FOUND (_("This YouTube video is private or was removed."));
                    var v = arr.get_object_element (0);
                    it = video_item (link_id, vid, obj (v, "snippet"));
                    it.duration_ms = parse_duration (str (obj (v, "contentDetails"), "duration"));
                    var status = obj (v, "status");
                    if (status != null && status.has_member ("embeddable") && !status.get_boolean_member ("embeddable")) it.set_extra ("embeddable", "false");
                } catch (MediaError.NOT_FOUND e) {
                    throw e;
                } catch (MediaError e) {
                    it = video_item (link_id, vid, null);
                }
            } else {
                it = video_item (link_id, vid, null);
            }
            if (it.title == "") yield oembed (it, vid, c);
            if (it.title == "") it.title = _("YouTube Video");
            if (start > 0) it.set_extra ("start-ms", start.to_string ());
            page.add (it);
            page.total = 1;
            return page;
        }

        public string oembed_base () {
            string? v = _host != null ? _host.get_value (ID, "oembed-base") : null;
            string b = "https://www.youtube.com/oembed";
            if (v != null && v != "") b = v;
            return b;
        }

        private async void oembed (MediaItem it, string vid, Cancellable? c) {
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("url", watch_url (vid));
            p.insert ("format", "json");
            try {
                var session = _host != null ? _host.session : new Soup.Session ();
                var reply = yield Web.request (session, "GET", oembed_base () + "?" + Web.query (p), null, null, null, c);
                if (reply.status == 401 || reply.status == 403) it.set_extra ("embeddable", "false");
                if (reply.status != 200) return;
                var parser = new Json.Parser ();
                parser.load_from_data (body_text (reply.body), -1);
                var o = parser.get_root ().get_object ();
                it.title = str (o, "title");
                it.subtitle = str (o, "author_name");
                it.artist = it.subtitle;
                it.image_url = str (o, "thumbnail_url");
            } catch (Error e) {
            }
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            if (node != null && node.has_prefix (URL_NODE)) return yield open_url (node.substring (URL_NODE.length), c);
            var all = links ();
            if (node == null || node == "") {
                if (all.size == 0) {
                    if (api_key () == "") return not_ready ();
                    var page = new MediaPage (title);
                    page.notice = _("Search YouTube with the search field, or add your Google account to see your subscriptions and playlists.");
                    page.action_label = _("Online Accounts");
                    page.action_uri = "settings:accounts";
                    return page;
                }
                var page = new MediaPage (title);
                foreach (var l in all) add_sections (page, l, all.size > 1 ? l.title : null);
                page.total = page.items.size;
                return page;
            }
            string link_id, kind, rest;
            if (!AccountLinks.parse (node, out link_id, out kind, out rest)) throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            AccountLink? l = link_id == "key" ? null : link (link_id);
            if (l == null && link_id != "key") throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("maxResults", PAGE.to_string ());
            if (token != null && token != "") p.insert ("pageToken", token);
            switch (kind) {
                case "subscriptions": {
                    p.insert ("part", "snippet");
                    p.insert ("mine", "true");
                    p.insert ("order", "alphabetical");
                    p.replace ("maxResults", "50");
                    var o = yield call (l, "subscriptions", p, 1, LIST_TTL, c);
                    var page = page_from (o, _("Subscriptions"));
                    var arr = o.get_array_member ("items");
                    for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                        var s = obj (arr.get_object_element (i), "snippet");
                        string cid = str (obj (s, "resourceId"), "channelId");
                        if (cid == "") continue;
                        var it = new MediaItem (ID, AccountLinks.node (link_id, "channel", cid), ItemKind.CHANNEL, str (s, "title"));
                        it.image_url = thumb (s);
                        it.external_url = "https://www.youtube.com/channel/" + cid;
                        it.external_label = _("Open on YouTube");
                        it.attribution = "YouTube";
                        page.add (it);
                    }
                    return page;
                }
                case "playlists": {
                    p.insert ("part", "snippet,contentDetails");
                    p.insert ("mine", "true");
                    var o = yield call (l, "playlists", p, 1, LIST_TTL, c);
                    var page = page_from (o, _("Your Playlists"));
                    var arr = o.get_array_member ("items");
                    for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                        var pl = arr.get_object_element (i);
                        var s = obj (pl, "snippet");
                        var it = new MediaItem (ID, AccountLinks.node (link_id, "playlist", str (pl, "id")), ItemKind.PLAYLIST, str (s, "title"));
                        var cd = obj (pl, "contentDetails");
                        if (cd != null && cd.has_member ("itemCount")) {
                            int64 n = cd.get_int_member ("itemCount");
                            it.subtitle = ngettext ("%d video", "%d videos", (ulong) n).printf ((int) n);
                        }
                        it.image_url = thumb (s);
                        it.external_url = "https://www.youtube.com/playlist?list=" + str (pl, "id");
                        it.external_label = _("Open on YouTube");
                        it.attribution = "YouTube";
                        page.add (it);
                    }
                    return page;
                }
                case "liked": {
                    p.insert ("part", "snippet,contentDetails,status");
                    p.insert ("myRating", "like");
                    var o = yield call (l, "videos", p, 1, LIST_TTL, c);
                    var page = page_from (o, _("Liked Videos"));
                    var arr = o.get_array_member ("items");
                    for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                        var v = arr.get_object_element (i);
                        var it = video_item (link_id, str (v, "id"), obj (v, "snippet"));
                        it.duration_ms = parse_duration (str (obj (v, "contentDetails"), "duration"));
                        var status = obj (v, "status");
                        if (status != null && status.has_member ("embeddable") && !status.get_boolean_member ("embeddable")) it.set_extra ("embeddable", "false");
                        page.add (it);
                    }
                    return page;
                }
                case "channel": {
                    string uploads = yield uploads_playlist (l, rest, c);
                    var page = yield playlist_page (l, link_id, uploads, token, c);
                    if (page.items.size > 0 && page.items[0].subtitle != "") page.title = page.items[0].subtitle;
                    return page;
                }
                case "playlist":
                    return yield playlist_page (l, link_id, rest, token, c);
                default:
                    throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            }
        }

        private async string uploads_playlist (AccountLink? l, string channel_id, Cancellable? c) throws Error {
            string? known = _host != null ? _host.get_value (ID, "uploads-" + channel_id) : null;
            if (known != null && known != "") return known;
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("part", "contentDetails");
            p.insert ("id", channel_id);
            var o = yield call (l, "channels", p, 1, DETAILS_TTL, c);
            var arr = o.get_array_member ("items");
            if (arr == null || arr.get_length () == 0) throw new MediaError.NOT_FOUND (_("This channel is not available"));
            string id = str (obj (obj (arr.get_object_element (0), "contentDetails"), "relatedPlaylists"), "uploads");
            if (id == "") throw new MediaError.NOT_FOUND (_("This channel has no public videos"));
            if (_host != null) _host.set_value (ID, "uploads-" + channel_id, id);
            return id;
        }

        private async MediaPage playlist_page (AccountLink? l, string link_id, string playlist_id, string? token, Cancellable? c) throws Error {
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("part", "snippet,contentDetails");
            p.insert ("playlistId", playlist_id);
            p.insert ("maxResults", PAGE.to_string ());
            if (token != null && token != "") p.insert ("pageToken", token);
            var o = yield call (l, "playlistItems", p, 1, LIST_TTL, c);
            var page = page_from (o, _("Playlist"));
            var arr = o.get_array_member ("items");
            for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                var pi = arr.get_object_element (i);
                var s = obj (pi, "snippet");
                string vid = str (obj (pi, "contentDetails"), "videoId");
                if (vid == "") vid = str (obj (s, "resourceId"), "videoId");
                string t = str (s, "title");
                if (vid == "" || t == "Private video" || t == "Deleted video") continue;
                page.add (video_item (link_id, vid, s));
            }
            yield add_durations (l, page.items, c);
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            var all = links ();
            AccountLink? l = all.size > 0 ? all[0] : null;
            if (l == null && api_key () == "") return not_ready ();
            var p = new HashTable<string, string> (str_hash, str_equal);
            p.insert ("part", "snippet");
            p.insert ("type", "video");
            p.insert ("q", query.strip ());
            p.insert ("maxResults", PAGE.to_string ());
            p.insert ("safeSearch", "moderate");
            if (token != null && token != "") p.insert ("pageToken", token);
            Json.Object o;
            try {
                o = yield call (l, "search", p, SEARCH_COST, SEARCH_TTL, c);
            } catch (MediaError e) {
                if (l == null || api_key () == "") throw e;
                if (!(e is MediaError.NOT_CONFIGURED || e is MediaError.NEEDS_ACCOUNT || e is MediaError.AUTH_FAILED || e is MediaError.RATE_LIMITED)) throw e;
                l = null;
                o = yield call (null, "search", p, SEARCH_COST, SEARCH_TTL, c);
            }
            var page = page_from (o, _("Results for “%s”").printf (query.strip ()));
            if (page.total > 500) page.total = -1;
            string link_id = l != null ? l.id : "key";
            var arr = o.get_array_member ("items");
            for (uint i = 0; arr != null && i < arr.get_length (); i++) {
                var r = arr.get_object_element (i);
                string vid = str (obj (r, "id"), "videoId");
                if (vid == "") continue;
                var it = video_item (link_id, vid, obj (r, "snippet"));
                it.title = unescape (it.title);
                page.add (it);
            }
            yield add_durations (l, page.items, c);
            return page;
        }

        private static string unescape (string s) {
            return s.replace ("&quot;", "\"").replace ("&#39;", "'").replace ("&amp;", "&").replace ("&lt;", "<").replace ("&gt;", ">");
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            string link_id, kind, vid;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out vid) || kind != "video") throw new MediaError.NOT_FOUND (_("Unknown item"));
            if (item.get_extra ("embeddable") == "false" || embed_override_disabled) return Playback.external (watch_url (vid));
#if HAVE_WEBKIT
            var player = new WebPlayer (_host, origin () + "/", (it, start) => player_page (it.get_extra ("video-id") ?? vid, start > 0 ? start : int64.parse (it.get_extra ("start-ms") ?? "0")));
            player.set_minimum (200, 200);
            var pb = Playback.embedded (player);
            pb.uri = watch_url (vid);
            pb.set_header ("Referer", origin () + "/");
            return pb;
#else
            return Playback.external (watch_url (vid));
#endif
        }

        public string player_page (string video_id, int64 start_ms) {
            string start = (start_ms / 1000).to_string ();
            return PLAYER_HTML
                .replace ("@BRIDGE@", WebPlayer.BRIDGE_JS)
                .replace ("@VIDEO@", WebPlayer.js_string (video_id))
                .replace ("@START@", start)
                .replace ("@ORIGIN@", WebPlayer.js_string (origin ()))
                .replace ("@E2@", WebPlayer.js_string (_("This video address is not valid.")))
                .replace ("@E5@", WebPlayer.js_string (_("This video cannot be played here.")))
                .replace ("@E100@", WebPlayer.js_string (_("This video was removed or made private.")))
                .replace ("@E150@", WebPlayer.js_string (_("The owner does not allow this video to play outside YouTube.")))
                .replace ("@E153@", WebPlayer.js_string (_("YouTube refused to start the player in this app.")));
        }

        private const string PLAYER_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}#player{width:100%;height:100%;border:0}</style>
</head><body><div id="player"></div><script>@BRIDGE@
var player = null;
var states = {"-1": "stopped", "0": "ended", "1": "playing", "2": "paused", "3": "buffering", "5": "stopped"};
var errors = {"2": @E2@, "5": @E5@, "100": @E100@, "101": @E150@, "150": @E150@, "153": @E153@};
function info(e) {
  var o = {event: e};
  if (player && player.getCurrentTime) {
    o.position = player.getCurrentTime() || 0;
    o.duration = player.getDuration() || 0;
    o.volume = (player.getVolume ? player.getVolume() : 100) / 100;
  }
  videosPost(o);
}
window.onYouTubeIframeAPIReady = function () {
  player = new YT.Player("player", {
    width: "100%", height: "100%", videoId: @VIDEO@,
    playerVars: {autoplay: 1, playsinline: 1, start: @START@, rel: 0, origin: @ORIGIN@},
    events: {
      onReady: function () { info("ready"); setInterval(function () { info("tick"); }, 1000); },
      onStateChange: function (ev) { info(states[String(ev.data)] || "tick"); },
      onError: function (ev) { videosPost({event: "error", code: ev.data, message: errors[String(ev.data)] || ""}); }
    }
  });
};
window.videosBridge = {
  play: function () { if (player) player.playVideo(); },
  pause: function () { if (player) player.pauseVideo(); },
  seek: function (s) { if (player) player.seekTo(s, true); },
  volume: function (v) { if (player) { player.setVolume(Math.round(v * 100)); if (v > 0) player.unMute(); } }
};
</script><script src="https://www.youtube.com/iframe_api"></script></body></html>""";
    }
}

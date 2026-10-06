using Singularity.MediaSources;
using Singularity.Accounts;

namespace Singularity.MediaPlugins {

    public class NextcloudVideosSource : Object, MediaSource, SourceAvailability, Browsable, Searchable, PlaybackResolver {
        public const string ID = "nextcloud-videos";
        private const string PROPFIND = """<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/></d:prop></d:propfind>""";
        private const string[] VIDEO_EXT = { ".mp4", ".m4v", ".mkv", ".webm", ".mov", ".avi", ".ogv", ".mpg", ".mpeg", ".ts", ".wmv" };

        private MediaHost? _host = null;
        private ulong _accounts_handler = 0;
        public Gee.List<AccountLink>? links_override = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return "Nextcloud"; } }
        public string icon_name { owned get { return "folder-remote-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY; } }
        public string? account_capability { owned get { return "videos"; } }
        public bool available { get { return links ().size > 0; } }
        public string unavailable_reason { owned get { return _("Add your Nextcloud in Online Accounts and switch on Files or Videos."); } }

        public void activate (MediaHost host) {
            _host = host;
            _accounts_handler = host.accounts_changed.connect (() => changed ());
        }

        public void deactivate () {
            if (_host != null && _accounts_handler != 0) _host.disconnect (_accounts_handler);
            _host = null;
        }

        public Gee.List<AccountLink> links () {
            if (links_override != null) return links_override;
            if (_host == null) return new Gee.ArrayList<AccountLink> ();
            var found = AccountLinks.find (_host, Capability.VIDEOS, "nextcloud");
            foreach (var l in AccountLinks.find (_host, Capability.FILES, "nextcloud")) {
                bool known = false;
                foreach (var k in found) if (k.id == l.id) known = true;
                if (!known) {
                    l.set_endpoint ("videos-capability", "files");
                    found.add (l);
                }
            }
            return found;
        }

        private AccountLink? link (string id) {
            foreach (var l in links ()) if (l.id == id) return l;
            return null;
        }

        public string folder_name (AccountLink l) {
            string? v = _host != null ? _host.get_value (ID, "folder-" + l.id) : null;
            string name = "Videos";
            if (v != null && v.strip () != "") name = v.strip ();
            return name;
        }

        private static string root_url (AccountLink l) {
            string u = l.endpoint ("webdav");
            if (u == "") u = AccountLinks.trim_slash (l.server) + "/remote.php/dav/files/" + Uri.escape_string (l.endpoint ("dav-user", l.username), "@", false) + "/";
            if (!u.has_suffix ("/")) u = u + "/";
            return u;
        }

        private static string origin (string url) {
            try {
                var u = Uri.parse (url, UriFlags.NONE);
                return u.get_port () > 0 ? "%s://%s:%d".printf (u.get_scheme (), u.get_host (), u.get_port ()) : "%s://%s".printf (u.get_scheme (), u.get_host ());
            } catch (UriError e) {
                return url;
            }
        }

        private async string auth (AccountLink l) throws Error {
            var c = yield l.credentials (capability_of (l));
            string? h = c.authorization_header ();
            if (h == null) throw new MediaError.UNSUPPORTED (_("This sign-in method is not supported for videos"));
            return h;
        }

        private static Capability capability_of (AccountLink l) {
            return l.endpoint ("videos-capability") == "files" ? Capability.FILES : Capability.VIDEOS;
        }

        private static bool is_video (string name, string ctype) {
            if (ctype.has_prefix ("video/")) return true;
            string n = name.down ();
            foreach (unowned string e in VIDEO_EXT) if (n.has_suffix (e)) return true;
            return false;
        }

        private static string title_of (string name) {
            string t = name;
            int dot = t.last_index_of_char ('.');
            if (dot > 0) t = t.substring (0, dot);
            try {
                var re = new Regex ("^[0-9]{1,3}[ ._-]+");
                t = re.replace (t, -1, 0, "");
            } catch (RegexError e) {
            }
            return t;
        }

        private async Gee.List<MediaItem> list (AccountLink l, string rel, Cancellable? c) throws Error {
            string url = root_url (l) + rel;
            var headers = new HashTable<string, string> (str_hash, str_equal);
            headers.insert ("Authorization", yield auth (l));
            headers.insert ("Depth", "1");
            headers.insert ("Accept", "application/xml");
            var reply = yield Web.request (_host != null ? _host.session : new Soup.Session (), "PROPFIND", url, headers, "application/xml; charset=utf-8", new Bytes (PROPFIND.data), c);
            if (reply.status == 404) throw new MediaError.NOT_FOUND (_("There is no %s folder in your Nextcloud").printf (rel != "" ? Uri.unescape_string (AccountLinks.trim_slash (rel)) : "/"));
            if (reply.status == 401) {
                yield l.report_problem (capability_of (l));
                throw new MediaError.AUTH_FAILED (_("Nextcloud refused the sign-in. Sign in again in Online Accounts."));
            }
            if (reply.status != 207) Web.check (reply, "Nextcloud");
            var ms = Multistatus.parse (reply.text ());
            var folders = new Gee.ArrayList<MediaItem> ();
            var files = new Gee.ArrayList<MediaItem> ();
            string self_path = Uri.unescape_string (url.substring (origin (url).length)) ?? "";
            foreach (var r in ms.responses) {
                string href = r.href.has_prefix ("http") ? r.href.substring (origin (r.href).length) : r.href;
                string decoded = Uri.unescape_string (href) ?? href;
                if (AccountLinks.trim_slash (decoded) == AccountLinks.trim_slash (self_path)) continue;
                string name = Path.get_basename (AccountLinks.trim_slash (decoded));
                if (name.has_prefix (".")) continue;
                string child_rel = rel + Uri.escape_string (name, null, false);
                if (r.is_type (NS_DAV, "collection")) {
                    folders.add (new MediaItem (ID, AccountLinks.node (l.id, "dir", child_rel + "/"), ItemKind.FOLDER, name));
                    continue;
                }
                string ctype = r.text (NS_DAV, "getcontenttype");
                if (!is_video (name, ctype)) continue;
                var it = new MediaItem (ID, AccountLinks.node (l.id, "file", child_rel), ItemKind.VIDEO, title_of (name));
                it.subtitle = Path.get_basename (Uri.unescape_string (AccountLinks.trim_slash (rel)) ?? "");
                it.attribution = "Nextcloud";
                files.add (it);
            }
            folders.sort ((a, b) => strcmp (a.title.casefold (), b.title.casefold ()));
            files.sort ((a, b) => strcmp (a.id, b.id));
            var all = new Gee.ArrayList<MediaItem> ();
            all.add_all (folders);
            all.add_all (files);
            return all;
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            var all = links ();
            if (all.size == 0) {
                var page = new MediaPage (title);
                page.notice = unavailable_reason;
                page.action_label = _("Online Accounts");
                page.action_uri = "settings:accounts";
                return page;
            }
            if (node == null || node == "") {
                if (all.size == 1) return yield browse (AccountLinks.node (all[0].id, "dir", Uri.escape_string (folder_name (all[0]), null, false) + "/"), token, c);
                var page = new MediaPage (title);
                foreach (var l in all) page.add (new MediaItem (ID, AccountLinks.node (l.id, "dir", Uri.escape_string (folder_name (l), null, false) + "/"), ItemKind.FOLDER, l.title));
                return page;
            }
            string link_id, kind, rel;
            if (!AccountLinks.parse (node, out link_id, out kind, out rel) || kind != "dir") throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            var page = new MediaPage (Path.get_basename (AccountLinks.trim_slash (Uri.unescape_string (rel) ?? rel)));
            foreach (var it in yield list (l, rel, c)) page.add (it);
            page.total = page.items.size;
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            var page = new MediaPage (_("Results"));
            string q = query.casefold ();
            foreach (var l in links ()) {
                var queue = new Gee.ArrayQueue<string> ();
                queue.offer (Uri.escape_string (folder_name (l), null, false) + "/");
                int visited = 0;
                while (!queue.is_empty && visited < 40 && page.items.size < 100) {
                    string rel = queue.poll ();
                    visited++;
                    Gee.List<MediaItem> items;
                    try {
                        items = yield list (l, rel, c);
                    } catch (MediaError.NOT_FOUND e) {
                        continue;
                    }
                    foreach (var it in items) {
                        string lid, k, r;
                        AccountLinks.parse (it.id, out lid, out k, out r);
                        if (k == "dir") queue.offer (r);
                        if (it.title.casefold ().contains (q) || it.subtitle.casefold ().contains (q)) page.add (it);
                    }
                }
            }
            return page;
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            string link_id, kind, rel;
            if (!AccountLinks.parse (item.id, out link_id, out kind, out rel) || kind != "file") throw new MediaError.NOT_FOUND (_("Unknown item"));
            var l = link (link_id);
            if (l == null) throw new MediaError.NEEDS_ACCOUNT (unavailable_reason);
            var pb = Playback.stream (root_url (l) + rel);
            pb.set_header ("Authorization", yield auth (l));
            return pb;
        }
    }
}

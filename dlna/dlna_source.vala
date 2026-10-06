using Singularity.MediaSources;

namespace Singularity.MediaPlugins {

    public class DlnaServer : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string location { get; set; default = ""; }
        public string control_url { get; set; default = ""; }
        public string icon_url { get; set; default = ""; }
    }

    public class DidlEntry : Object {
        public bool container = false;
        public string id = "";
        public string title = "";
        public string upnp_class = "";
        public string artist = "";
        public string album = "";
        public string art = "";
        public string res = "";
        public string protocol = "";
        public int64 duration_ms = 0;
        public int track = 0;
        public int child_count = -1;
    }

    public class Upnp : Object {
        public const string SEARCH_TARGET = "urn:schemas-upnp-org:service:ContentDirectory:1";

        private static Xml.Node* child (Xml.Node* parent, string name) {
            if (parent == null) return null;
            for (Xml.Node* c = parent->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == name) return c;
            }
            return null;
        }

        private static string text (Xml.Node* n) {
            if (n == null) return "";
            string? s = n->get_content ();
            return s != null ? s.strip () : "";
        }

        public static string resolve (string base_url, string reference) {
            if (reference.has_prefix ("http://") || reference.has_prefix ("https://")) return reference;
            try {
                return Uri.resolve_relative (base_url, reference, UriFlags.NONE);
            } catch (UriError e) {
                return reference;
            }
        }

        public static DlnaServer? parse_description (string xml, string location) {
            Xml.Doc* doc = Xml.Parser.read_memory (xml, xml.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
            if (doc == null) return null;
            DlnaServer? server = null;
            Xml.Node* root = doc->get_root_element ();
            string base_url = location;
            var url_base = text (child (root, "URLBase"));
            if (url_base != "") base_url = url_base;
            Xml.Node* device = child (root, "device");
            if (device != null) {
                server = new DlnaServer ();
                server.location = location;
                server.name = text (child (device, "friendlyName"));
                server.id = text (child (device, "UDN"));
                if (server.id == "") server.id = location;
                Xml.Node* icons = child (device, "iconList");
                if (icons != null) {
                    for (Xml.Node* ic = icons->children; ic != null; ic = ic->next) {
                        if (ic->type != Xml.ElementType.ELEMENT_NODE) continue;
                        string mime = text (child (ic, "mimetype"));
                        if (mime == "image/png" || server.icon_url == "") server.icon_url = resolve (base_url, text (child (ic, "url")));
                    }
                }
                find_cd (device, base_url, server);
            }
            delete doc;
            return server != null && server.control_url != "" ? server : null;
        }

        private static void find_cd (Xml.Node* device, string base_url, DlnaServer server) {
            Xml.Node* services = child (device, "serviceList");
            if (services != null) {
                for (Xml.Node* s = services->children; s != null; s = s->next) {
                    if (s->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (text (child (s, "serviceType")).has_prefix ("urn:schemas-upnp-org:service:ContentDirectory:")) {
                        server.control_url = resolve (base_url, text (child (s, "controlURL")));
                        return;
                    }
                }
            }
            Xml.Node* devices = child (device, "deviceList");
            if (devices == null) return;
            for (Xml.Node* d = devices->children; d != null; d = d->next) {
                if (d->type == Xml.ElementType.ELEMENT_NODE && server.control_url == "") find_cd (d, base_url, server);
            }
        }

        public static int64 parse_duration (string d) {
            var parts = d.split (":");
            if (parts.length != 3) return 0;
            double secs = double.parse (parts[2]);
            return (int64) ((int64.parse (parts[0]) * 3600 + int64.parse (parts[1]) * 60) * 1000 + secs * 1000);
        }

        public static Gee.List<DidlEntry> parse_didl (string xml) {
            var list = new Gee.ArrayList<DidlEntry> ();
            Xml.Doc* doc = Xml.Parser.read_memory (xml, xml.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
            if (doc == null) return list;
            Xml.Node* root = doc->get_root_element ();
            for (Xml.Node* n = root != null ? root->children : null; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE || (n->name != "container" && n->name != "item")) continue;
                var e = new DidlEntry ();
                e.container = n->name == "container";
                e.id = n->get_prop ("id") ?? "";
                string? cc = n->get_prop ("childCount");
                if (cc != null) e.child_count = int.parse (cc);
                for (Xml.Node* c = n->children; c != null; c = c->next) {
                    if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                    switch (c->name) {
                        case "title": e.title = text (c); break;
                        case "class": e.upnp_class = text (c); break;
                        case "artist":
                        case "creator":
                            if (e.artist == "") e.artist = text (c);
                            break;
                        case "album": e.album = text (c); break;
                        case "albumArtURI": if (e.art == "") e.art = text (c); break;
                        case "originalTrackNumber": e.track = int.parse (text (c)); break;
                        case "res":
                            if (e.res == "") {
                                e.res = text (c);
                                e.protocol = c->get_prop ("protocolInfo") ?? "";
                                string? dur = c->get_prop ("duration");
                                if (dur != null) e.duration_ms = parse_duration (dur);
                            }
                            break;
                    }
                }
                list.add (e);
            }
            delete doc;
            return list;
        }

        public static string soap_browse (string object_id, int start, int count) {
            return """<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>%s</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>%d</StartingIndex><RequestedCount>%d</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>""".printf (Markup.escape_text (object_id), start, count);
        }

        public static string soap_search (string container, string criteria, int start, int count) {
            return """<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Search xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ContainerID>%s</ContainerID><SearchCriteria>%s</SearchCriteria><Filter>*</Filter><StartingIndex>%d</StartingIndex><RequestedCount>%d</RequestedCount><SortCriteria></SortCriteria></u:Search></s:Body></s:Envelope>""".printf (Markup.escape_text (container), Markup.escape_text (criteria), start, count);
        }

        public static bool parse_result (string xml, out string didl, out int returned, out int total) {
            didl = "";
            returned = 0;
            total = 0;
            Xml.Doc* doc = Xml.Parser.read_memory (xml, xml.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
            if (doc == null) return false;
            bool ok = false;
            var stack = new Gee.ArrayQueue<Xml.Node*> ();
            stack.offer (doc->get_root_element ());
            while (!stack.is_empty) {
                Xml.Node* n = stack.poll ();
                if (n == null) continue;
                if (n->type == Xml.ElementType.ELEMENT_NODE) {
                    if (n->name == "Result") {
                        didl = text (n);
                        ok = true;
                    } else if (n->name == "NumberReturned") {
                        returned = int.parse (text (n));
                    } else if (n->name == "TotalMatches") {
                        total = int.parse (text (n));
                    }
                }
                for (Xml.Node* c = n->children; c != null; c = c->next) stack.offer (c);
            }
            delete doc;
            return ok;
        }

        public static Gee.List<string> parse_ssdp (string packet) {
            var locs = new Gee.ArrayList<string> ();
            foreach (var line in packet.split ("\n")) {
                string l = line.strip ();
                if (l.down ().has_prefix ("location:")) locs.add (l.substring (9).strip ());
            }
            return locs;
        }
    }

    public class DlnaSource : Object, MediaSource, SourceAvailability, Browsable, Searchable, PlaybackResolver {
        public const string ID = "dlna";
        private const int PAGE = 100;

        private MediaHost? _host = null;
        private Gee.HashMap<string, DlnaServer> _servers = new Gee.HashMap<string, DlnaServer> ();
        private bool _discovering = false;
        private int64 _last_discovery = 0;
        public string[] extra_locations = {};
        public bool use_multicast = true;

        public string id { owned get { return ID; } }
        public string title { owned get { return _("Media Servers"); } }
        public string icon_name { owned get { return "network-workgroup-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO | MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY; } }
        public string? account_capability { owned get { return null; } }
        public bool available { get { return _servers.size > 0; } }
        public string unavailable_reason { owned get { return _("No media servers found on this network."); } }

        construct {
            string? env = Environment.get_variable ("SINGULARITY_DLNA_LOCATIONS");
            if (env != null) {
                string[] locs = {};
                foreach (var l in env.split (";")) if (l.strip () != "") locs += l.strip ();
                extra_locations = locs;
            }
        }

        public void activate (MediaHost host) {
            _host = host;
            discover.begin ();
        }

        public void deactivate () {
            _host = null;
        }

        private bool audio () {
            return _host == null || (_host.kinds & MediaKind.AUDIO) != 0;
        }

        private Soup.Session session () {
            return _host != null ? _host.session : new Soup.Session ();
        }

        public Gee.Collection<DlnaServer> servers {
            owned get { return _servers.values; }
        }

        public async void discover () {
            if (_discovering) {
                while (_discovering) {
                    Timeout.add (50, discover.callback);
                    yield;
                }
                return;
            }
            _discovering = true;
            var found = new Gee.HashSet<string> ();
            foreach (var l in extra_locations) found.add (l);
            if (use_multicast) {
                foreach (var l in yield ssdp_search (2)) found.add (l);
            }
            bool changed_any = false;
            foreach (var loc in found) {
                try {
                    var reply = yield Web.request (session (), "GET", loc, null, null, null, null);
                    if (reply.status != 200) continue;
                    var server = Upnp.parse_description (reply.text (), loc);
                    if (server == null) continue;
                    if (!_servers.has_key (server.id)) changed_any = true;
                    _servers[server.id] = server;
                } catch (Error e) {
                    debug ("dlna: %s: %s", loc, e.message);
                }
            }
            _last_discovery = get_monotonic_time ();
            _discovering = false;
            if (changed_any) changed ();
        }

        private async Gee.List<string> ssdp_search (int seconds) {
            var result = new Gee.ArrayList<string> ();
            try {
                var sock = new Socket (SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
                sock.blocking = false;
                sock.bind (new InetSocketAddress (new InetAddress.any (SocketFamily.IPV4), 0), true);
                string msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: %d\r\nST: %s\r\nUSER-AGENT: Linux/1 UPnP/1.1 Singularity/0.1\r\n\r\n".printf (seconds, Upnp.SEARCH_TARGET);
                var target = new InetSocketAddress (new InetAddress.from_string ("239.255.255.250"), 1900);
                sock.send_to (target, msg.data);
                int64 end = get_monotonic_time () + (int64) (seconds + 1) * 1000000;
                var src = sock.create_source (IOCondition.IN);
                uint8[] buf = new uint8[4096];
                src.set_callback ((s, cond) => {
                    try {
                        ssize_t n = sock.receive (buf);
                        if (n > 0) {
                            foreach (var l in Upnp.parse_ssdp ((string) buf[0:n])) if (!result.contains (l)) result.add (l);
                        }
                    } catch (Error e) {
                    }
                    return Source.CONTINUE;
                });
                src.attach (MainContext.get_thread_default ());
                Timeout.add ((uint) ((end - get_monotonic_time ()) / 1000), ssdp_search.callback);
                yield;
                src.destroy ();
                sock.close ();
            } catch (Error e) {
                debug ("dlna: discovery: %s", e.message);
            }
            return result;
        }

        private async string soap (DlnaServer s, string action, string body, Cancellable? c) throws Error {
            var headers = new HashTable<string, string> (str_hash, str_equal);
            headers.insert ("SOAPACTION", "\"%s#%s\"".printf (Upnp.SEARCH_TARGET, action));
            headers.insert ("Accept", "text/xml");
            var reply = yield Web.request (session (), "POST", s.control_url, headers, "text/xml; charset=\"utf-8\"", new Bytes (body.data), c);
            if (reply.status == 500 && action == "Search") throw new MediaError.UNSUPPORTED (_("This server cannot search"));
            Web.check (reply, s.name);
            return reply.text ();
        }

        private bool wanted (DidlEntry e) {
            if (e.container) return true;
            if (audio ()) return e.upnp_class.has_prefix ("object.item.audioItem");
            return e.upnp_class.has_prefix ("object.item.videoItem");
        }

        private MediaItem to_item (DlnaServer s, DidlEntry e) {
            ItemKind kind;
            if (e.container) {
                if (e.upnp_class.has_prefix ("object.container.album")) kind = ItemKind.ALBUM;
                else if (e.upnp_class.has_prefix ("object.container.person")) kind = ItemKind.ARTIST;
                else if (e.upnp_class.has_prefix ("object.container.playlistContainer")) kind = ItemKind.PLAYLIST;
                else if (e.upnp_class.has_prefix ("object.container.genre")) kind = ItemKind.GENRE;
                else kind = ItemKind.FOLDER;
            } else {
                kind = e.upnp_class.has_prefix ("object.item.videoItem") ? ItemKind.VIDEO : ItemKind.TRACK;
            }
            var it = new MediaItem (ID, AccountLinks.node (s.id, e.container ? "c" : "i", e.id), kind, e.title);
            it.artist = e.artist;
            it.album = e.album;
            it.subtitle = e.container ? (e.child_count >= 0 ? ngettext ("%d item", "%d items", e.child_count).printf (e.child_count) : e.artist) : e.artist;
            it.track_number = e.track;
            it.duration_ms = e.duration_ms;
            it.image_url = e.art;
            it.stream_uri = e.res;
            if (!e.container) it.set_extra ("protocol", e.protocol);
            it.attribution = s.name;
            return it;
        }

        private DlnaServer? server (string id) {
            return _servers[id];
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            if (_servers.size == 0 || get_monotonic_time () - _last_discovery > 60 * 1000000) yield discover ();
            if (node == null || node == "") {
                if (_servers.size == 1) {
                    foreach (var only in _servers.values) return yield browse (AccountLinks.node (only.id, "c", "0"), token, c);
                }
                var page = new MediaPage (title);
                if (_servers.size == 0) {
                    page.notice = unavailable_reason;
                    return page;
                }
                foreach (var s in _servers.values) {
                    var it = new MediaItem (ID, AccountLinks.node (s.id, "c", "0"), ItemKind.FOLDER, s.name);
                    it.image_url = s.icon_url;
                    page.add (it);
                }
                return page;
            }
            string sid, kind, oid;
            if (!AccountLinks.parse (node, out sid, out kind, out oid)) throw new MediaError.NOT_FOUND (_("Nothing to show here"));
            var s = server (sid);
            if (s == null) throw new MediaError.NOT_FOUND (_("The media server is no longer on the network"));
            int offset = Paging.offset_of (token);
            string didl;
            int returned, total;
            if (!Upnp.parse_result (yield soap (s, "Browse", Upnp.soap_browse (oid, offset, PAGE), c), out didl, out returned, out total))
                throw new MediaError.PROTOCOL (_("%s sent an unexpected answer").printf (s.name));
            var page = new MediaPage (oid == "0" ? s.name : "");
            foreach (var e in Upnp.parse_didl (didl)) if (wanted (e)) page.add (to_item (s, e));
            page.total = total;
            if (returned > 0 && offset + returned < total) page.next_token = (offset + returned).to_string ();
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            if (_servers.size == 0) yield discover ();
            var page = new MediaPage (_("Results"));
            string cls = audio () ? "object.item.audioItem" : "object.item.videoItem";
            string q = query.replace ("\"", "");
            string criteria = "upnp:class derivedfrom \"%s\" and (dc:title contains \"%s\" or upnp:artist contains \"%s\" or upnp:album contains \"%s\")".printf (cls, q, q, q);
            foreach (var s in _servers.values) {
                try {
                    string didl;
                    int returned, total;
                    if (!Upnp.parse_result (yield soap (s, "Search", Upnp.soap_search ("0", criteria, 0, 100), c), out didl, out returned, out total)) continue;
                    foreach (var e in Upnp.parse_didl (didl)) if (wanted (e)) page.add (to_item (s, e));
                } catch (MediaError.UNSUPPORTED e) {
                }
            }
            return page;
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            if (item.stream_uri == "") throw new MediaError.NOT_FOUND (_("The server offers no stream for this item"));
            return Playback.stream (item.stream_uri);
        }
    }
}

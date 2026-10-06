using Singularity.MediaSources;
using Singularity.MediaPlugins;

async void probe (string[] args) {
    var host = new TestHost ();
    host.host_kinds = MediaKind.VIDEO;
    string what = args.length > 1 ? args[1] : "";
    try {
        if (what == "peertube-search" || what == "peertube-browse" || what == "peertube-url") {
            var src = new PeerTubeSource ();
            src.activate (host);
            MediaPage page;
            if (what == "peertube-search") page = yield src.search (args[2], MediaKind.VIDEO, null, null);
            else if (what == "peertube-url") page = yield src.browse (PeerTubeSource.URL_NODE + args[2], null, null);
            else {
                var root = yield src.browse (null, null, null);
                page = yield src.browse (root.items[0].id, null, null);
            }
            print ("page '%s' total=%d next=%s items=%d\n", page.title, page.total, page.next_token ?? "-", page.items.size);
            foreach (var it in page.items) print ("  %s | %s | %s | %s | %lld\n", it.id, it.title, it.subtitle, it.image_url, it.duration_ms);
            if (page.items.size > 0) {
                var pb = yield src.resolve (page.items[0], null);
                print ("resolve kind=%d uri=%s\n", (int) pb.kind, pb.uri);
            }
        } else if (what == "youtube-search" || what == "youtube-url") {
            var src = new YouTubeSource ();
            src.config_paths_override = {};
            src.links_override = new Gee.ArrayList<AccountLink> ();
            src.activate (host);
            if (args.length > 3) host.set_value ("youtube", "api-key", args[3]);
            MediaPage page;
            if (what == "youtube-url") page = yield src.browse (YouTubeSource.URL_NODE + args[2], null, null);
            else page = yield src.search (args[2], MediaKind.VIDEO, null, null);
            print ("page '%s' notice='%s' items=%d\n", page.title, page.notice, page.items.size);
            foreach (var it in page.items) print ("  %s | %s | %s\n", it.id, it.title, it.external_url);
            if (page.items.size > 0) {
                var pb = yield src.resolve (page.items[0], null);
                print ("resolve kind=%d uri=%s referer=%s\n", (int) pb.kind, pb.uri, pb.get_header ("Referer") ?? "-");
            }
        }
    } catch (Error e) {
        print ("ERROR %s %d: %s\n", e.domain.to_string (), e.code, e.message);
    }
}

int main (string[] args) {
    var loop = new MainLoop ();
    probe.begin (args, (o, r) => {
        probe.end (r);
        loop.quit ();
    });
    loop.run ();
    return 0;
}

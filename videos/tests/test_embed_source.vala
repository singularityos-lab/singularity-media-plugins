using Singularity.MediaSources;

namespace Singularity.MediaPlugins {

    public class TestEmbedSource : Object, MediaSource, Browsable, Searchable, PlaybackResolver {
        public const string ID = "test-embed";
        private MediaHost? _host = null;

        public string id { owned get { return ID; } }
        public string title { owned get { return "Test Player"; } }
        public string icon_name { owned get { return "applications-engineering-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.VIDEO; } }
        public SourceFeatures features { get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.EMBED | SourceFeatures.PLAY; } }
        public string? account_capability { owned get { return null; } }

        public void activate (MediaHost host) {
            _host = host;
        }

        public void deactivate () {
            _host = null;
        }

        private MediaItem make (string id, string title, string sub, int64 ms) {
            var it = new MediaItem (ID, id, ItemKind.VIDEO, title);
            it.subtitle = sub;
            it.duration_ms = ms;
            it.external_url = "https://example.invalid/" + id;
            it.attribution = "Test";
            return it;
        }

        public async MediaPage browse (string? node, string? token, Cancellable? c) throws Error {
            var page = new MediaPage (title);
            page.add (make ("embed", "Embedded Clock", "Local web player", 8000));
            page.add (make ("external", "Opens Outside", "Not embeddable", 60000));
            string? stream = _host != null ? _host.get_value (ID, "stream-uri") : null;
            if (stream != null) page.add (make ("stream", "Direct Stream", "Played by GStreamer", 30000));
            page.total = page.items.size;
            return page;
        }

        public async MediaPage search (string query, MediaKind kinds, string? token, Cancellable? c) throws Error {
            var all = yield browse (null, null, c);
            var page = new MediaPage (query);
            foreach (var it in all.items) if (it.title.down ().contains (query.down ())) page.add (it);
            return page;
        }

        public async Playback resolve (MediaItem item, Cancellable? c) throws Error {
            if (item.id == "external") return Playback.external (item.external_url);
            if (item.id == "stream") return Playback.stream (_host.get_value (ID, "stream-uri"));
            var player = new WebPlayer (_host, "https://player.invalid/", (it, start) => PAGE.replace ("@BRIDGE@", WebPlayer.BRIDGE_JS).replace ("@START@", (start / 1000.0).to_string ()));
            return Playback.embedded (player);
        }

        private const string PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#101418;color:#e8eef3;font:600 48px sans-serif;display:flex;align-items:center;justify-content:center;flex-direction:column}
#t{font-variant-numeric:tabular-nums}#s{font-size:20px;opacity:.7;margin-top:12px}</style></head>
<body><div id="t">0.0</div><div id="s">Fake web player</div><script>@BRIDGE@
var pos = @START@, dur = 8, playing = false, vol = 1, last = 0;
function show() { document.getElementById("t").textContent = pos.toFixed(1) + " / " + dur.toFixed(1); document.getElementById("s").textContent = playing ? "Playing" : "Paused"; }
function post(e) { videosPost({event: e, position: pos, duration: dur, volume: vol}); }
window.videosBridge = {
  play: function () { if (pos >= dur) pos = 0; playing = true; last = Date.now(); post("playing"); show(); },
  pause: function () { playing = false; post("paused"); show(); },
  seek: function (s) { pos = Math.max(0, Math.min(dur, s)); post("tick"); show(); },
  volume: function (v) { vol = v; post("tick"); }
};
setInterval(function () {
  if (!playing) return;
  var now = Date.now(); pos += (now - last) / 1000; last = now;
  if (pos >= dur) { pos = dur; playing = false; show(); post("ended"); return; }
  show(); post("tick");
}, 250);
post("ready"); window.videosBridge.play();
</script></body></html>""";
    }
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (typeof (Singularity.MediaSources.MediaSource), typeof (Singularity.MediaPlugins.TestEmbedSource));
}

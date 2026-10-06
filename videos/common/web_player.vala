using Singularity.MediaSources;

[CCode (cheader_filename = "webkit/webkit.h", cname = "webkit_settings_get_all_features")]
extern void* videos_webkit_all_features ();
[CCode (cheader_filename = "webkit/webkit.h", cname = "webkit_feature_list_get_length")]
extern size_t videos_webkit_feature_count (void* list);
[CCode (cheader_filename = "webkit/webkit.h", cname = "webkit_feature_list_get")]
extern void* videos_webkit_feature_get (void* list, size_t index);
[CCode (cheader_filename = "webkit/webkit.h", cname = "webkit_feature_get_identifier")]
extern unowned string videos_webkit_feature_id (void* feature);
[CCode (cheader_filename = "webkit/webkit.h", cname = "webkit_settings_set_feature_enabled")]
extern void videos_webkit_set_feature (WebKit.Settings settings, void* feature, bool enabled);
[CCode (cheader_filename = "webkit/webkit.h", cname = "webkit_feature_list_unref")]
extern void videos_webkit_features_unref (void* list);

namespace Singularity.MediaPlugins {

    public class WebPlayer : Object, EmbeddedPlayer {
        public const string BRIDGE = "videos";

        private WebKit.WebView? _view = null;
        private Gtk.Widget? _frame = null;
        private MediaHost? _host;
        private ulong _visibility_handler = 0;
        private PlaybackState _state = PlaybackState.STOPPED;
        private int64 _position_ms = 0;
        private int64 _duration_ms = 0;
        private double _volume = 1.0;
        private string _base_uri;
        private bool _ready = false;
        private string[] _pending = {};

        private int _min_width = 480;
        private int _min_height = 270;
        public int min_width { get { return _min_width; } }
        public int min_height { get { return _min_height; } }

        public void set_minimum (int width, int height) {
            _min_width = width;
            _min_height = height;
            if (_view != null) _view.set_size_request (width, height);
        }
        public string last_error { get; private set; default = ""; }

        public delegate string PageBuilder (MediaItem item, int64 start_ms);
        private PageBuilder _builder;

        public WebPlayer (MediaHost? host, string base_uri, owned PageBuilder builder) {
            _host = host;
            _base_uri = base_uri;
            _builder = (owned) builder;
            if (host != null) {
                _visibility_handler = host.visibility_changed.connect (() => {
                    if (!host.window_visible && _state == PlaybackState.PLAYING) pause ();
                });
            }
        }

        ~WebPlayer () {
            if (_host != null && _visibility_handler != 0) _host.disconnect (_visibility_handler);
        }

        public Gtk.Widget widget {
            get {
                if (_frame == null) _build ();
                return _frame;
            }
        }

        public PlaybackState state { get { return _state; } }
        public int64 position_ms { get { return _position_ms; } }
        public int64 duration_ms { get { return _duration_ms; } }
        public double volume { get { return _volume; } }

        public WebKit.WebView? view { get { return _view; } }

        private void _build () {
            var ucm = new WebKit.UserContentManager ();
            ucm.script_message_received[BRIDGE].connect (_on_message);
            ucm.register_script_message_handler (BRIDGE, (string) null);
            _view = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "user-content-manager", ucm);
            var s = _view.get_settings ();
            s.set_enable_media (true);
            s.set_media_playback_requires_user_gesture (false);
            s.set_enable_developer_extras (false);
            var features = videos_webkit_all_features ();
            for (size_t i = 0; i < videos_webkit_feature_count (features); i++) {
                var f = videos_webkit_feature_get (features, i);
                if (videos_webkit_feature_id (f) == "MediaSession") videos_webkit_set_feature (s, f, false);
            }
            videos_webkit_features_unref (features);
            if (_host != null) s.set_user_agent_with_application_details ("Singularity", "1.0");
            _view.hexpand = true;
            _view.vexpand = true;
            _view.set_size_request (min_width, min_height);
            _view.add_css_class ("sx-embedded-player");
            _view.create.connect ((action) => {
                string? uri = action.get_request ().get_uri ();
                if (uri != null && uri != "") _open_external (uri);
                return (Gtk.Widget) null;
            });
            _view.web_process_terminated.connect ((reason) => {
                _ready = false;
                _set_state (PlaybackState.STOPPED);
                failed (_("The player stopped unexpectedly"));
            });
            _frame = _view;
        }

        private void _open_external (string uri) {
            if (_host != null) _host.open_external (uri);
        }

        private void _on_message (JSC.Value value) {
            string text = value.to_string ();
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text, -1);
            } catch (Error e) {
                return;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
            var o = root.get_object ();
            string ev = o.has_member ("event") ? o.get_string_member ("event") : "";
            if (o.has_member ("position")) _position_ms = (int64) (o.get_double_member ("position") * 1000);
            if (o.has_member ("duration")) {
                int64 d = (int64) (o.get_double_member ("duration") * 1000);
                if (d > 0) _duration_ms = d;
            }
            if (o.has_member ("volume")) _volume = o.get_double_member ("volume");
            switch (ev) {
                case "ready":
                    _ready = true;
                    foreach (var js in _pending) _run (js);
                    _pending = {};
                    state_changed ();
                    break;
                case "playing": _set_state (PlaybackState.PLAYING); break;
                case "paused": _set_state (PlaybackState.PAUSED); break;
                case "buffering": _set_state (PlaybackState.BUFFERING); break;
                case "stopped": _set_state (PlaybackState.STOPPED); break;
                case "ended":
                    _set_state (PlaybackState.STOPPED);
                    ended ();
                    break;
                case "error":
                    last_error = o.has_member ("message") ? o.get_string_member ("message") : "";
                    failed (last_error);
                    break;
                case "open":
                    if (o.has_member ("uri")) _open_external (o.get_string_member ("uri"));
                    break;
                default:
                    state_changed ();
                    break;
            }
        }

        private void _set_state (PlaybackState s) {
            _state = s;
            state_changed ();
        }

        private void _run (string js) {
            if (_view == null) return;
            if (!_ready) {
                _pending += js;
                return;
            }
            _view.evaluate_javascript.begin (js, -1, null, null, null, (o, r) => {
                try {
                    _view.evaluate_javascript.end (r);
                } catch (Error e) {
                }
            });
        }

        public void load (MediaItem item, int64 start_ms) {
            if (_frame == null) _build ();
            _ready = false;
            _pending = {};
            _position_ms = start_ms;
            _duration_ms = item.duration_ms;
            last_error = "";
            _set_state (PlaybackState.BUFFERING);
            _view.load_html (_builder (item, start_ms), _base_uri);
        }

        public void play () {
            _run ("window.videosBridge && window.videosBridge.play()");
        }

        public void pause () {
            _run ("window.videosBridge && window.videosBridge.pause()");
        }

        public void seek (int64 position_ms) {
            _position_ms = position_ms;
            _run ("window.videosBridge && window.videosBridge.seek(%s)".printf (_seconds (position_ms)));
        }

        public void set_volume (double volume) {
            _volume = volume.clamp (0, 1);
            _run ("window.videosBridge && window.videosBridge.volume(%s)".printf (_number (_volume)));
        }

        public void stop () {
            if (_view != null) {
                _view.stop_loading ();
                _view.load_uri ("about:blank");
            }
            _ready = false;
            _pending = {};
            _set_state (PlaybackState.STOPPED);
        }

        private static string _number (double v) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return v.to_str (buf);
        }

        private static string _seconds (int64 ms) {
            return _number (ms / 1000.0);
        }

        public static string js_string (string s) {
            var sb = new StringBuilder ("\"");
            unichar c;
            for (int i = 0; s.get_next_char (ref i, out c);) {
                if (c == '"' || c == '\\') sb.append_c ('\\').append_unichar (c);
                else if (c == '<') sb.append ("\\u003c");
                else if (c == '>') sb.append ("\\u003e");
                else if (c < 0x20 || c == 0x2028 || c == 0x2029) sb.append ("\\u%04x".printf ((uint) c));
                else sb.append_unichar (c);
            }
            sb.append_c ('"');
            return sb.str;
        }

        public const string BRIDGE_JS = """
window.videosPost = function (o) {
  try { window.webkit.messageHandlers.videos.postMessage(JSON.stringify(o)); } catch (e) {}
};
""";
    }
}

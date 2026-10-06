using Singularity.MediaSources;

namespace Singularity.MediaPlugins {

    public class LibrespotProcess : Object {
        public const int MAX_RESTARTS = 5;
        public const int RESTART_WINDOW_S = 120;

        private Subprocess? _proc = null;
        private bool _wanted = false;
        private int64[] _restarts = {};
        private uint _restart_source = 0;
        private Cancellable? _cancel = null;
        private string _pending_url = "";
        private uint _pending_source = 0;
        private string _shown_url = "";

        public string binary { get; set; default = ""; }
        public string device_name { get; set; default = "Singularity Music"; }
        public string cache_dir { get; set; default = ""; }
        public string pcm_path { get; set; default = ""; }
        public uint restart_delay_ms { get; set; default = 2000; }
        public bool running { get; private set; default = false; }
        public bool signed_in { get; private set; default = false; }
        public string last_error { get; private set; default = ""; }
        public int starts { get; private set; default = 0; }

        public signal void changed ();
        public signal void auth_url (string url);

        public static string? find_binary () {
            string? env = Environment.get_variable ("SINGULARITY_LIBRESPOT");
            if (env != null && env != "" && FileUtils.test (env, FileTest.IS_EXECUTABLE)) return env;
            string bundled = Path.build_filename (LibrespotConfig.LIBEXECDIR, "librespot");
            if (FileUtils.test (bundled, FileTest.IS_EXECUTABLE)) return bundled;
            return Environment.find_program_in_path ("librespot");
        }

        public string[] arguments () {
            string[] argv = { binary, "--name", device_name, "--backend", "pipe", "--device", pcm_path,
                "--format", "S16", "--bitrate", "320", "--initial-volume", "100", "--volume-ctrl", "fixed",
                "--device-type", "computer" };
            if (cache_dir != "") {
                argv += "--cache";
                argv += cache_dir;
                argv += "--disable-audio-cache";
            }
            if (!has_credentials ()) argv += "--enable-oauth";
            return argv;
        }

        public bool has_credentials () {
            return cache_dir != "" && FileUtils.test (Path.build_filename (cache_dir, "credentials.json"), FileTest.EXISTS);
        }

        public bool ensure_fifo () {
            if (FileUtils.test (pcm_path, FileTest.EXISTS)) {
                Posix.Stat st;
                if (Posix.stat (pcm_path, out st) == 0 && Posix.S_ISFIFO (st.st_mode)) return true;
                FileUtils.unlink (pcm_path);
            }
            DirUtils.create_with_parents (Path.get_dirname (pcm_path), 0700);
            return Posix.mkfifo (pcm_path, 0600) == 0;
        }

        public void start () {
            _wanted = true;
            if (_proc != null) return;
            if (binary == "") {
                last_error = _("The librespot program is not installed");
                changed ();
                return;
            }
            if (!ensure_fifo ()) {
                last_error = _("Could not create the audio pipe %s").printf (pcm_path);
                changed ();
                return;
            }
            if (cache_dir != "") DirUtils.create_with_parents (cache_dir, 0700);
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
                launcher.set_child_setup (() => {
                    die_with_parent (1, Posix.Signal.TERM);
                });
                _proc = launcher.spawnv (arguments ());
            } catch (Error e) {
                last_error = e.message;
                _proc = null;
                changed ();
                schedule_restart ();
                return;
            }
            starts++;
            running = true;
            last_error = "";
            changed ();
            _cancel = new Cancellable ();
            read_output.begin (_proc, _cancel);
            var proc = _proc;
            proc.wait_async.begin (null, (o, r) => {
                try {
                    proc.wait_async.end (r);
                } catch (Error e) {
                }
                if (proc != _proc) return;
                _proc = null;
                running = false;
                if (_wanted && proc.get_if_exited () && proc.get_exit_status () != 0 && last_error == "")
                    last_error = _("librespot stopped (exit code %d)").printf (proc.get_exit_status ());
                changed ();
                if (_wanted) schedule_restart ();
            });
        }

        private void schedule_restart () {
            int64 now = get_monotonic_time ();
            int64[] recent = {};
            foreach (var t in _restarts) if (now - t < (int64) RESTART_WINDOW_S * 1000000) recent += t;
            _restarts = recent;
            if (_restarts.length >= MAX_RESTARTS) {
                last_error = _("librespot keeps stopping: %s").printf (last_error != "" ? last_error : _("no reason given"));
                changed ();
                return;
            }
            _restarts += now;
            if (_restart_source != 0) return;
            _restart_source = Timeout.add (restart_delay_ms, () => {
                _restart_source = 0;
                if (_wanted) start ();
                return Source.REMOVE;
            });
        }

        public void handle_line (string raw) {
            string line = raw.strip ();
            if (line == "") return;
            int at = line.index_of ("https://accounts.spotify.com/");
            if (at >= 0) {
                _pending_url = line.substring (at).split (" ")[0];
                if (_pending_source != 0) Source.remove (_pending_source);
                _pending_source = Timeout.add (1500, () => {
                    _pending_source = 0;
                    if (_pending_url != "" && _proc != null && _pending_url != _shown_url) {
                        _shown_url = _pending_url;
                        auth_url (_pending_url);
                    }
                    _pending_url = "";
                    return Source.REMOVE;
                });
                return;
            }
            string low = line.down ();
            if (low.contains ("failed to bind") || low.contains ("address already in use")) {
                _pending_url = "";
                last_error = _("Another Spotify player is already signing in on this computer. Close it and try again.");
                changed ();
                return;
            }
            if (low.contains ("authenticated as") || low.contains ("connected to") || low.contains ("logged in")) {
                signed_in = true;
                last_error = "";
                changed ();
            } else if (low.contains ("bad credentials") || low.contains ("authentication failed")) {
                signed_in = false;
                last_error = _("Spotify did not accept the sign-in. Sign in again.");
                if (cache_dir != "") FileUtils.unlink (Path.build_filename (cache_dir, "credentials.json"));
                changed ();
            } else if (low.contains ("premium")) {
                last_error = _("Playing in Music needs Spotify Premium.");
                changed ();
            } else if (low.contains ("error") && last_error == "") {
                last_error = line;
            }
        }

        private async void read_output (Subprocess proc, Cancellable cancel) {
            var input = new DataInputStream (proc.get_stdout_pipe ());
            try {
                string? line;
                while ((line = yield input.read_line_async (Priority.DEFAULT, cancel)) != null) handle_line (line);
            } catch (Error e) {
            }
        }

        public void stop () {
            _wanted = false;
            if (_restart_source != 0) {
                Source.remove (_restart_source);
                _restart_source = 0;
            }
            if (_cancel != null) _cancel.cancel ();
            if (_proc != null) {
                _proc.send_signal (Posix.Signal.TERM);
                _proc = null;
            }
            running = false;
            signed_in = false;
            changed ();
        }
    }

    [CCode (cname = "prctl", cheader_filename = "sys/prctl.h")]
    private extern int die_with_parent (int option, int signal);

    public class LibrespotSource : Object, MediaSource, LocalReceiver {
        public const string ID = "librespot";
        private MediaHost? _host = null;
        private LibrespotProcess _proc = new LibrespotProcess ();

        public string id { owned get { return ID; } }
        public string title { owned get { return _("Spotify in Music"); } }
        public string icon_name { owned get { return "singularity-account-music-service"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO; } }
        public SourceFeatures features { get { return SourceFeatures.ISOLATED; } }
        public string? account_capability { owned get { return null; } }

        public bool installed { get { return _proc.binary != ""; } }
        public bool running { get { return _proc.running; } }
        public bool signed_in { get { return _proc.signed_in || _proc.has_credentials (); } }
        public string device_name { owned get { return _proc.device_name; } }
        public string pcm_path { owned get { return _proc.pcm_path; } }
        public int sample_rate { get { return 44100; } }
        public int channels { get { return 2; } }
        public LibrespotProcess process { get { return _proc; } }

        public string status_text {
            owned get {
                if (!installed) return _("Install librespot to play Spotify in Music: your distribution's librespot package, or cargo install librespot.");
                if (_proc.last_error != "") return _proc.last_error;
                if (!running) return _("The Singularity Music player is stopped.");
                if (!signed_in) return _("Sign in to Spotify to play in Music.");
                return _("Spotify plays in Music through librespot, an unofficial player that uses your Premium account.");
            }
        }

        construct {
            _proc.binary = LibrespotProcess.find_binary () ?? "";
            _proc.changed.connect (() => receiver_changed ());
            _proc.auth_url.connect ((url) => sign_in_needed (url));
        }

        public void activate (MediaHost host) {
            _host = host;
            string? name = Environment.get_variable ("SINGULARITY_LIBRESPOT_NAME");
            _proc.device_name = name != null && name != "" ? name : "Singularity Music";
            _proc.cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-music", "librespot");
            string run = Environment.get_user_runtime_dir ();
            _proc.pcm_path = Path.build_filename (run, "singularity-music", "librespot.pcm");
            start ();
        }

        public void deactivate () {
            stop ();
            _host = null;
        }

        public void start () {
            _proc.start ();
        }

        public void stop () {
            _proc.stop ();
        }
    }
}

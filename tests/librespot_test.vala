using Singularity.MediaPlugins;

string write_fake (string dir) {
    string path = Path.build_filename (dir, "fake-librespot");
    string script = """#!/bin/sh
echo "$@" >> "%s/args.log"
N=$(wc -l < "%s/args.log")
DEV=""
while [ $# -gt 0 ]; do [ "$1" = "--device" ] && DEV=$2; shift; done
echo "[INFO  librespot] Browse to: https://accounts.spotify.com/authorize?client_id=x&response_type=code"
echo "[INFO  librespot_core::session] Authenticated as 'alice' !"
printf 'PCMDATA' > "$DEV"
if [ "$N" -eq 1 ]; then echo "[ERROR librespot] connection lost"; exit 1; fi
sleep 30
""".printf (dir, dir);
    try {
        FileUtils.set_contents (path, script);
    } catch (Error e) {
        error ("%s", e.message);
    }
    FileUtils.chmod (path, 0755);
    return path;
}

void test_librespot_process () {
    string dir = "";
    try {
        dir = DirUtils.make_tmp ("librespot-test-XXXXXX");
    } catch (Error e) {
        error ("%s", e.message);
    }
    var p = new LibrespotProcess ();
    p.binary = write_fake (dir);
    p.cache_dir = Path.build_filename (dir, "cache");
    p.pcm_path = Path.build_filename (dir, "run", "librespot.pcm");
    p.device_name = "Singularity Music";
    p.restart_delay_ms = 100;
    var argv = p.arguments ();
    assert ("--enable-oauth" in argv && "--backend" in argv && "pipe" in argv && "Singularity Music" in argv);
    string url = "";
    p.auth_url.connect ((u) => url = u);
    var got = new StringBuilder ();
    var mutex = Mutex ();
    new Thread<void> ("reader", () => {
        for (int i = 0; i < 2; i++) {
            while (!FileUtils.test (p.pcm_path, FileTest.EXISTS)) Thread.usleep (10000);
            var f = FileStream.open (p.pcm_path, "r");
            if (f == null) continue;
            uint8[] buf = new uint8[16];
            size_t n = f.read (buf);
            mutex.lock ();
            got.append_len ((string) buf, (ssize_t) n);
            got.append ("|");
            mutex.unlock ();
        }
    });
    p.start ();
    assert (p.running);
    var ctx = MainContext.default ();
    int64 end = get_monotonic_time () + 8000000;
    while (p.starts < 2 && get_monotonic_time () < end) ctx.iteration (false);
    assert (p.starts == 2);
    end = get_monotonic_time () + 3000000;
    while (get_monotonic_time () < end) {
        ctx.iteration (false);
        mutex.lock ();
        bool done = got.str == "PCMDATA|PCMDATA|";
        mutex.unlock ();
        if (done && p.signed_in && p.running && url != "") break;
    }
    assert (url.has_prefix ("https://accounts.spotify.com/authorize"));
    assert (p.signed_in && p.running);
    mutex.lock ();
    assert (got.str == "PCMDATA|PCMDATA|");
    mutex.unlock ();
    Posix.Stat st;
    assert (Posix.stat (p.pcm_path, out st) == 0 && Posix.S_ISFIFO (st.st_mode));
    p.stop ();
    assert (!p.running);
    try {
        FileUtils.set_contents (Path.build_filename (dir, "cache", "credentials.json"), "{}");
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert (!("--enable-oauth" in p.arguments ()));
    p.handle_line ("[ERROR librespot] Failed to get Spotify access token: Failed to bind server to 127.0.0.1:5588 (Address already in use (os error 98))");
    assert (p.last_error.contains ("Another Spotify player"));
    p.handle_line ("[ERROR librespot_core] Bad credentials");
    assert (!p.signed_in && !p.has_credentials () && p.last_error != "");
}

void test_librespot_giveup () {
    string dir = "";
    try {
        dir = DirUtils.make_tmp ("librespot-test-XXXXXX");
    } catch (Error e) {
        error ("%s", e.message);
    }
    var p = new LibrespotProcess ();
    p.binary = "/bin/false";
    p.cache_dir = Path.build_filename (dir, "cache");
    p.pcm_path = Path.build_filename (dir, "librespot.pcm");
    p.restart_delay_ms = 20;
    p.start ();
    var ctx = MainContext.default ();
    int64 end = get_monotonic_time () + 5000000;
    while (!p.last_error.has_prefix ("librespot keeps stopping") && get_monotonic_time () < end) ctx.iteration (false);
    assert (p.starts == LibrespotProcess.MAX_RESTARTS + 1);
    assert (p.last_error.has_prefix ("librespot keeps stopping"));
    p.stop ();
}

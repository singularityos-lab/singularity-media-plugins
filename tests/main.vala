int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/media-plugins/jellyfin", test_jellyfin);
    Test.add_func ("/media-plugins/subsonic", test_subsonic);
    Test.add_func ("/media-plugins/listenbrainz", test_listenbrainz);
    Test.add_func ("/media-plugins/lrclib", test_lrclib);
    Test.add_func ("/media-plugins/musicbrainz", test_musicbrainz);
    Test.add_func ("/media-plugins/spotify", test_spotify);
    Test.add_func ("/media-plugins/nextcloud", test_nextcloud);
    Test.add_func ("/media-plugins/dlna", test_dlna);
    Test.add_func ("/media-plugins/librespot-process", test_librespot_process);
    Test.add_func ("/media-plugins/librespot-giveup", test_librespot_giveup);
    return Test.run ();
}

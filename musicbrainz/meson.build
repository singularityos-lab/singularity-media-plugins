shared_module('media-musicbrainz', files('musicbrainz_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'music' / 'musicbrainz')
configure_file(input: 'musicbrainz.plugin', output: 'musicbrainz.plugin', copy: true)
install_data('musicbrainz.plugin', install_dir: app_plugins_dir / 'music' / 'musicbrainz')

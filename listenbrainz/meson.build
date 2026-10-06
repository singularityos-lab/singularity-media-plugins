shared_module('media-listenbrainz', files('listenbrainz_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'music' / 'listenbrainz')
configure_file(input: 'listenbrainz.plugin', output: 'listenbrainz.plugin', copy: true)
install_data('listenbrainz.plugin', install_dir: app_plugins_dir / 'music' / 'listenbrainz')

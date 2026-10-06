shared_module('media-spotify', files('spotify_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'music' / 'spotify')
configure_file(input: 'spotify.plugin', output: 'spotify.plugin', copy: true)
install_data('spotify.plugin', install_dir: app_plugins_dir / 'music' / 'spotify')

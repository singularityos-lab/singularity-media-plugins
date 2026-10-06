shared_module('media-lrclib', files('lrclib_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'music' / 'lrclib')
configure_file(input: 'lrclib.plugin', output: 'lrclib.plugin', copy: true)
install_data('lrclib.plugin', install_dir: app_plugins_dir / 'music' / 'lrclib')

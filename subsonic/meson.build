shared_module('media-subsonic', files('subsonic_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'music' / 'subsonic')
configure_file(input: 'subsonic.plugin', output: 'subsonic.plugin', copy: true)
install_data('subsonic.plugin', install_dir: app_plugins_dir / 'music' / 'subsonic')
